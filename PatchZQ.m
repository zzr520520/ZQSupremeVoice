#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/mman.h>
#import <string.h>
#import <stdarg.h>
#import <errno.h>
#import <dlfcn.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ========== 底层 C 文件 API 拦截 ==========
// 使用符号导出覆盖（interposition），dylib 导出同名函数
// dyld 会优先使用我们的版本，再通过 dlsym(RTLD_NEXT, ...) 调用系统原始实现

typedef int (*open_func_t)(const char *, int, ...);
typedef int (*openat_func_t)(int, const char *, int, ...);
typedef int (*stat_func_t)(const char *, struct stat *);
typedef int (*lstat_func_t)(const char *, struct stat *);
typedef FILE *(*fopen_func_t)(const char *, const char *);
typedef void *(*mmap_func_t)(void *, size_t, int, int, int, off_t);

static open_func_t real_open = NULL;
static openat_func_t real_openat = NULL;
static stat_func_t real_stat = NULL;
static stat_func_t real_lstat = NULL;
static fopen_func_t real_fopen = NULL;
static mmap_func_t real_mmap = NULL;

static int should_block_path(const char *path) {
    if (!path) return 0;
    // 大小写不敏感匹配
    const char *p = path;
    if (strstr(p, "embedded.mobileprovision") ||
        strstr(p, "SC_Info") ||
        strstr(p, "_CodeSignature") ||
        strstr(p, "CodeResources")) {
        return 1;
    }
    // 小写路径也检查
    char lower[1024];
    size_t len = strlen(p);
    if (len < sizeof(lower)) {
        for (size_t i = 0; i < len; i++) {
            lower[i] = (p[i] >= 'A' && p[i] <= 'Z') ? p[i] + 32 : p[i];
        }
        lower[len] = '\0';
        if (strstr(lower, "mobileprovision") ||
            strstr(lower, "sc_info") ||
            strstr(lower, "codesignature")) {
            return 1;
        }
    }
    return 0;
}

static void init_real_funcs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        real_open = (open_func_t)dlsym(RTLD_NEXT, "open");
        real_openat = (openat_func_t)dlsym(RTLD_NEXT, "openat");
        real_stat = (stat_func_t)dlsym(RTLD_NEXT, "stat");
        real_lstat = (stat_func_t)dlsym(RTLD_NEXT, "lstat");
        real_fopen = (fopen_func_t)dlsym(RTLD_NEXT, "fopen");
        real_mmap = (mmap_func_t)dlsym(RTLD_NEXT, "mmap");
    });
}

// ---- open ----
int open(const char *path, int oflag, ...) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return -1;
    }
    va_list args;
    va_start(args, oflag);
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        mode = (mode_t)va_arg(args, int);
    }
    va_end(args);
    return real_open(path, oflag, mode);
}

// ---- openat ----
int openat(int fd, const char *path, int oflag, ...) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return -1;
    }
    va_list args;
    va_start(args, oflag);
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        mode = (mode_t)va_arg(args, int);
    }
    va_end(args);
    return real_openat(fd, path, oflag, mode);
}

// ---- stat ----
int stat(const char *restrict path, struct stat *restrict buf) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return -1;
    }
    return real_stat(path, buf);
}

// ---- lstat ----
int lstat(const char *restrict path, struct stat *restrict buf) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return -1;
    }
    return real_lstat(path, buf);
}

// ---- fopen ----
FILE *fopen(const char *restrict path, const char *restrict mode) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return NULL;
    }
    return real_fopen(path, mode);
}

// ========== 1. NSBundle 伪装 ==========

static NSString *(*orig_bundleIdentifier)(id, SEL);
static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *);
static id hook_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleIdentifier"]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_objectForInfoDictionaryKey(self, _cmd, key);
}

static NSDictionary *(*orig_infoDictionary)(id, SEL);
static NSDictionary *hook_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = orig_infoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBundleIdentifier"] = TARGET_BUNDLE_ID;
        return mDict;
    }
    return dict;
}

static NSDictionary *(*orig_localizedInfoDictionary)(id, SEL);
static NSDictionary *hook_localizedInfoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = orig_localizedInfoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBundleIdentifier"] = TARGET_BUNDLE_ID;
        return mDict;
    }
    return dict;
}

// ========== 2. NSData 拦截 ==========

static BOOL isMobileProvisionPath(NSString *path) {
    if (!path) return NO;
    NSString *lower = [path lowercaseString];
    return [lower containsString:@"embedded.mobileprovision"] ||
           [lower containsString:@".mobileprovision"] ||
           [lower containsString:@"sc_info"] ||
           [lower containsString:@"_codesignature"];
}

static NSData *(*orig_dataWithContentsOfFile)(id, SEL, NSString *);
static NSData *hook_dataWithContentsOfFile(id self, SEL _cmd, NSString *path) {
    if (isMobileProvisionPath(path)) {
        return nil;
    }
    return orig_dataWithContentsOfFile(self, _cmd, path);
}

static NSData *(*orig_dataWithContentsOfFileOptionsError)(id, SEL, NSString *, NSDataReadingOptions, NSError **);
static NSData *hook_dataWithContentsOfFileOptionsError(id self, SEL _cmd, NSString *path,
                                                       NSDataReadingOptions readOptionsMask,
                                                       NSError **errorPtr) {
    if (isMobileProvisionPath(path)) {
        if (errorPtr) {
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadNoSuchFileError
                                        userInfo:@{NSFilePathErrorKey: path}];
        }
        return nil;
    }
    return orig_dataWithContentsOfFileOptionsError(self, _cmd, path, readOptionsMask, errorPtr);
}

// ========== 3. NSFileManager 拦截 ==========

static BOOL (*orig_fileExistsAtPath)(id, SEL, NSString *);
static BOOL hook_fileExistsAtPath(id self, SEL _cmd, NSString *path) {
    if (path && ([path containsString:@"SC_Info"] ||
                 [path containsString:@"CodeResources"] ||
                 [path containsString:@"_CodeSignature"])) {
        return NO;
    }
    // 注意：mobileprovision 保持文件存在，由 C 层拦截 open/stat
    return orig_fileExistsAtPath(self, _cmd, path);
}

static NSData *(*orig_contentsAtPath)(id, SEL, NSString *);
static NSData *hook_contentsAtPath(id self, SEL _cmd, NSString *path) {
    if (isMobileProvisionPath(path)) {
        return nil;
    }
    if (path && ([path containsString:@"SC_Info"] ||
                 [path containsString:@"CodeResources"])) {
        return nil;
    }
    return orig_contentsAtPath(self, _cmd, path);
}

// ========== 辅助函数 ==========

static void swizzleInstanceMethod(Class cls, SEL origSel, IMP newImp, IMP *origImpOut) {
    Method m = class_getInstanceMethod(cls, origSel);
    if (m) {
        *origImpOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
    }
}

static void swizzleClassMethod(Class cls, SEL origSel, IMP newImp, IMP *origImpOut) {
    Method m = class_getClassMethod(cls, origSel);
    if (m) {
        *origImpOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
    }
}

// ========== 构造函数 ==========
__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        // 预初始化 C 层函数指针（确保在任何调用前就绪）
        init_real_funcs();

        // NSBundle 伪装
        Class bundleCls = [NSBundle class];
        swizzleInstanceMethod(bundleCls,
                              @selector(bundleIdentifier),
                              (IMP)hook_bundleIdentifier,
                              (IMP *)&orig_bundleIdentifier);

        swizzleInstanceMethod(bundleCls,
                              @selector(infoDictionary),
                              (IMP)hook_infoDictionary,
                              (IMP *)&orig_infoDictionary);

        swizzleInstanceMethod(bundleCls,
                              @selector(objectForInfoDictionaryKey:),
                              (IMP)hook_objectForInfoDictionaryKey,
                              (IMP *)&orig_objectForInfoDictionaryKey);

        swizzleInstanceMethod(bundleCls,
                              @selector(localizedInfoDictionary),
                              (IMP)hook_localizedInfoDictionary,
                              (IMP *)&orig_localizedInfoDictionary);

        // NSData 类方法拦截
        Class dataCls = [NSData class];
        swizzleClassMethod(dataCls,
                           @selector(dataWithContentsOfFile:),
                           (IMP)hook_dataWithContentsOfFile,
                           (IMP *)&orig_dataWithContentsOfFile);

        swizzleClassMethod(dataCls,
                           @selector(dataWithContentsOfFile:options:error:),
                           (IMP)hook_dataWithContentsOfFileOptionsError,
                           (IMP *)&orig_dataWithContentsOfFileOptionsError);

        // NSFileManager 拦截
        Class fmCls = [NSFileManager defaultManager].class;
        swizzleInstanceMethod(fmCls,
                              @selector(fileExistsAtPath:),
                              (IMP)hook_fileExistsAtPath,
                              (IMP *)&orig_fileExistsAtPath);

        swizzleInstanceMethod(fmCls,
                              @selector(contentsAtPath:),
                              (IMP)hook_contentsAtPath,
                              (IMP *)&orig_contentsAtPath);

        NSLog(@"[PatchZQ] 签名绕过补丁已加载 - BundleID: %@", TARGET_BUNDLE_ID);
    }
}
