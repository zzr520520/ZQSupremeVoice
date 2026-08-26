// PatchZQ.m - 终极防闪退补丁
// 三层防护：
//   1. 拦截 fopen/open — 阻止读取 embedded.mobileprovision / _CodeSignature
//   2. 拦截 Keychain — 阻止钥匙串权限拒绝崩溃
//   3. BundleID 伪装 — 保持原始包名返回
// 全部使用 dyld __interpose 机制确保拦截生效

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdio.h>
#import <fcntl.h>
#import <stdarg.h>
#import <string.h>
#import <errno.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ==================== dyld interpose 宏 ====================

struct interpose_s {
    void *replacement;
    void *original;
};

#define ZQ_INTERPOSE(_repl, _orig) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static struct interpose_s _interpose_##_orig = { (void *)_repl, (void *)_orig }

// ==================== 1. 底层文件访问拦截 ====================
// 阻止加固代码通过 fopen/open 读取个人证书的 mobileprovision

static int is_blocked_path(const char *path) {
    if (!path) return 0;
    // 只拦截签名相关的特定路径，不影响正常文件操作
    if (strstr(path, "embedded.mobileprovision")) return 1;
    if (strstr(path, "_CodeSignature/CodeResources")) return 1;
    if (strstr(path, "CodeSignature")) {
        // 只拦截 _CodeSignature 目录下的文件读取
        if (strstr(path, "_CodeSignature")) return 1;
    }
    return 0;
}

// --- fopen ---
static FILE *(*orig_fopen)(const char *, const char *);

FILE *my_fopen(const char *path, const char *mode) {
    if (is_blocked_path(path)) {
        return NULL;  // 假装文件不存在
    }
    return orig_fopen(path, mode);
}

// --- open ---
static int (*orig_open)(const char *, int, ...);

int my_open(const char *path, int oflag, ...) {
    if (is_blocked_path(path)) {
        errno = ENOENT;
        return -1;
    }
    
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    return orig_open(path, oflag, mode);
}

// --- open$NOCANCEL (iOS 上 open 的实际符号) ---
static int (*orig_open_nocancel)(const char *, int, ...);

int my_open_nocancel(const char *path, int oflag, ...) {
    if (is_blocked_path(path)) {
        errno = ENOENT;
        return -1;
    }
    
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    return orig_open_nocancel(path, oflag, mode);
}

// ==================== 2. Keychain 拦截 ====================

static OSStatus my_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (result) *result = NULL;
    return errSecItemNotFound;
}

static OSStatus my_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (result) *result = NULL;
    return errSecSuccess;
}

static OSStatus my_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    return errSecSuccess;
}

static OSStatus my_SecItemDelete(CFDictionaryRef query) {
    return errSecSuccess;
}

// ==================== 3. interpose 注册 ====================

ZQ_INTERPOSE(my_fopen, fopen);
ZQ_INTERPOSE(my_open, open);
ZQ_INTERPOSE(my_open_nocancel, open$NOCANCEL);
ZQ_INTERPOSE(my_SecItemCopyMatching, SecItemCopyMatching);
ZQ_INTERPOSE(my_SecItemAdd, SecItemAdd);
ZQ_INTERPOSE(my_SecItemUpdate, SecItemUpdate);
ZQ_INTERPOSE(my_SecItemDelete, SecItemDelete);

// ==================== 4. BundleID 伪装 ====================

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

static void swizzle(Class cls, SEL orig, IMP hook, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, orig);
    if (m) {
        *origOut = method_getImplementation(m);
        method_setImplementation(m, hook);
    }
}

// ==================== 5. 初始化 ====================

__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        // 初始化原始函数指针（从 RTLD_NEXT 获取）
        orig_fopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
        orig_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
        orig_open_nocancel = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open$NOCANCEL");
        
        // BundleID 伪装
        Class bCls = [NSBundle class];
        swizzle(bCls, @selector(bundleIdentifier),
                (IMP)hook_bundleIdentifier,
                (IMP *)&orig_bundleIdentifier);
        swizzle(bCls, @selector(objectForInfoDictionaryKey:),
                (IMP)hook_objectForInfoDictionaryKey,
                (IMP *)&orig_objectForInfoDictionaryKey);
    }
}
