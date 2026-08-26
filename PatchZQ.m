#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <signal.h>
#import <pthread.h>
#import <string.h>
#import <mach/mach.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ========== 自毁地址（加固特征）==========
// 安全检测不通过时，故意跳转到 0xb5a00000 触发段错误自毁
#define SELF_DESTRUCT_ADDR 0xb5a00000

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

// ========== 2. 信号捕获：拦截自毁段错误 ==========
// 当加固检测到签名不匹配时，会向 GCD 队列派发一个跳转到非法地址的 Block
// 执行时触发 SIGSEGV/SIGBUS 崩溃。我们捕获该信号，安全退出子线程而非崩溃整个 App

static struct sigaction g_orig_sigsegv;
static struct sigaction g_orig_sigbus;

static void handle_self_destruct_signal(int sig, siginfo_t *info, void *context) {
    // 检查是否为已知的自毁地址
    if (info && (uintptr_t)info->si_addr == (uintptr_t)SELF_DESTRUCT_ADDR) {
        // 安全退出当前线程，不影响主线程 UI
        pthread_exit(NULL);
    }

    // 其他地址的段错误，走原始信号处理
    if (sig == SIGSEGV && g_orig_sigsegv.sa_sigaction) {
        g_orig_sigsegv.sa_sigaction(sig, info, context);
    } else if (sig == SIGBUS && g_orig_sigbus.sa_sigaction) {
        g_orig_sigbus.sa_sigaction(sig, info, context);
    }
}

// ========== 3. C 层文件 API 拦截（保留作为辅助防线）==========
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdarg.h>
#import <errno.h>
#import <dlfcn.h>

typedef int (*open_func_t)(const char *, int, ...);
typedef int (*stat_func_t)(const char *, struct stat *);
typedef FILE *(*fopen_func_t)(const char *, const char *);

static open_func_t real_open = NULL;
static stat_func_t real_stat = NULL;
static fopen_func_t real_fopen = NULL;

static int should_block_path(const char *path) {
    if (!path) return 0;
    if (strstr(path, "embedded.mobileprovision") ||
        strstr(path, "SC_Info") ||
        strstr(path, "_CodeSignature") ||
        strstr(path, "CodeResources")) {
        return 1;
    }
    return 0;
}

static void init_real_funcs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        real_open = (open_func_t)dlsym(RTLD_NEXT, "open");
        real_stat = (stat_func_t)dlsym(RTLD_NEXT, "stat");
        real_fopen = (fopen_func_t)dlsym(RTLD_NEXT, "fopen");
    });
}

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

int stat(const char *restrict path, struct stat *restrict buf) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return -1;
    }
    return real_stat(path, buf);
}

FILE *fopen(const char *restrict path, const char *restrict mode) {
    init_real_funcs();
    if (should_block_path(path)) {
        errno = ENOENT;
        return NULL;
    }
    return real_fopen(path, mode);
}

// ========== 辅助函数 ==========

static void swizzleInstanceMethod(Class cls, SEL origSel, IMP newImp, IMP *origImpOut) {
    Method m = class_getInstanceMethod(cls, origSel);
    if (m) {
        *origImpOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
    }
}

// ========== 构造函数（最高优先级）==========
__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        // ---- 第一步：预初始化 C 层拦截 ----
        init_real_funcs();

        // ---- 第二步：注册信号捕获（最核心的自毁防护）----
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_flags = SA_SIGINFO;
        sa.sa_sigaction = handle_self_destruct_signal;

        // 保存原始处理函数
        sigaction(SIGSEGV, NULL, &g_orig_sigsegv);
        sigaction(SIGBUS, NULL, &g_orig_sigbus);

        // 注册我们的处理函数
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);

        // ---- 第三步：NSBundle 伪装 ----
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

        NSLog(@"[PatchZQ] 自毁防护补丁已加载 - 信号捕获已注册 - BundleID: %@", TARGET_BUNDLE_ID);
    }
}
