#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <signal.h>
#import <string.h>
#import <dlfcn.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ========== 自毁地址特征 ==========
#define SELF_DESTRUCT_PAGE 0xb5a00000

// ========== 1. GCD 入口拦截（核心防护）==========
// 直接拦截 dispatch_async_f，在自毁任务进入线程池前物理丢弃
// 不依赖 sigaction（会被 RTC 引擎的 PosixSignalHandler 覆盖）

typedef void (*dispatch_async_f_t)(dispatch_queue_t, void *, void (*)(void *));

static dispatch_async_f_t real_dispatch_async_f = NULL;
static dispatch_async_f_t real_dispatch_async = NULL;
static dispatch_async_f_t real_dispatch_sync = NULL;
static dispatch_async_f_t real_dispatch_after_f = NULL;

static BOOL is_destruct_func(uintptr_t addr) {
    if (addr == 0) return YES;
    // 匹配 0xb5a00000 整页（1MB 范围）
    if ((addr & 0xFFF00000) == SELF_DESTRUCT_PAGE) return YES;
    return NO;
}

static void init_gcd_funcs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        real_dispatch_async_f = (dispatch_async_f_t)dlsym(RTLD_NEXT, "dispatch_async_f");
        real_dispatch_async = (dispatch_async_f_t)dlsym(RTLD_NEXT, "dispatch_async");
        real_dispatch_sync = (dispatch_async_f_t)dlsym(RTLD_NEXT, "dispatch_sync");
        real_dispatch_after_f = (dispatch_async_f_t)dlsym(RTLD_NEXT, "dispatch_after_f");
    });
}

// 拦截 dispatch_async_f
void dispatch_async_f(dispatch_queue_t queue, void *context, void (*work)(void *)) {
    init_gcd_funcs();
    if (is_destruct_func((uintptr_t)work)) {
        // 静默丢弃自毁任务
        return;
    }
    real_dispatch_async_f(queue, context, work);
}

// 拦截 dispatch_async（Block 版本）
void dispatch_async(dispatch_queue_t queue, void (^block)(void)) {
    init_gcd_funcs();
    // Block 的函数指针在 block->invoke
    uintptr_t *blockRaw = (uintptr_t *)block;
    if (blockRaw) {
        // Block 结构体：isa(8) flags(4) reserved(4) invoke(8) ...
        #if defined(__LP64__)
        uintptr_t invoke = blockRaw[2];
        #else
        uintptr_t invoke = blockRaw[2];
        #endif
        if (is_destruct_func(invoke)) {
            return; // 丢弃自毁 Block
        }
    }
    // 用 dispatch_async_f 的原始实现来执行
    real_dispatch_async_f(queue, block, _dispatch_call_block_and_release);
}

extern void _dispatch_call_block_and_release(void *);

// 拦截 dispatch_sync_f（同步派发也可能被利用）
void dispatch_sync_f(dispatch_queue_t queue, void *context, void (*work)(void *)) {
    init_gcd_funcs();
    if (is_destruct_func((uintptr_t)work)) {
        return;
    }
    real_dispatch_sync(queue, context, work);
}

// 拦截 dispatch_after_f（延迟派发）
void dispatch_after_f(dispatch_time_t when, dispatch_queue_t queue,
                      void *context, void (*work)(void *)) {
    init_gcd_funcs();
    if (is_destruct_func((uintptr_t)work)) {
        return; // 丢弃延迟自毁
    }
    real_dispatch_after_f(queue, context, work);
}

// ========== 2. 信号捕获（备用防线，低优先级）==========
// 虽然会被 RTC 引擎覆盖，但在覆盖前能拦截早期的自毁

static struct sigaction g_orig_sigsegv;
static struct sigaction g_orig_sigbus;
static struct sigaction g_orig_sigill;

static void backup_sig_handler(int sig, siginfo_t *info, void *context) {
    if (info) {
        uintptr_t addr = (uintptr_t)info->si_addr;
        if ((addr & 0xFFF00000) == SELF_DESTRUCT_PAGE || addr < 0x1000) {
            pthread_exit(NULL);
        }
    }
    struct sigaction *orig = NULL;
    if (sig == SIGSEGV) orig = &g_orig_sigsegv;
    else if (sig == SIGBUS) orig = &g_orig_sigbus;
    else if (sig == SIGILL) orig = &g_orig_sigill;
    if (orig && orig->sa_sigaction) {
        orig->sa_sigaction(sig, info, context);
    }
}

// 定期重新注册信号捕获（对抗 RTC 引擎覆盖）
// 使用 dispatch_source 定时器，每 5 秒重新注册一次
static void register_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = backup_sig_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;

    sigaction(SIGSEGV, NULL, &g_orig_sigsegv);
    sigaction(SIGBUS, NULL, &g_orig_sigbus);
    sigaction(SIGILL, NULL, &g_orig_sigill);

    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}

// ========== 3. Bundle 伪装与路径保护 ==========

static NSString *(*orig_bundleIdentifier)(id, SEL);
static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

// bundleWithPath: 空值安全保护
// 防止加固逻辑在 lstat 路径解析时放置断点陷阱
static NSBundle *(*orig_bundleWithPath)(id, SEL, NSString *);
static NSBundle *hook_bundleWithPath(id self, SEL _cmd, NSString *path) {
    if (!path || [path length] == 0) {
        return nil;
    }
    return orig_bundleWithPath(self, _cmd, path);
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
        // 预初始化 GCD 函数指针
        init_gcd_funcs();

        // 注册信号捕获（备用防线）
        register_signal_handlers();

        // 定时重新注册信号捕获，对抗 RTC PosixSignalHandler 覆盖
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                           dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            register_signal_handlers();
        });
        dispatch_resume(timer);

        // Bundle 伪装
        Class bundleCls = [NSBundle class];
        swizzleInstanceMethod(bundleCls,
                              @selector(bundleIdentifier),
                              (IMP)hook_bundleIdentifier,
                              (IMP *)&orig_bundleIdentifier);

        swizzleClassMethod(bundleCls,
                           @selector(bundleWithPath:),
                           (IMP)hook_bundleWithPath,
                           (IMP *)&orig_bundleWithPath);

        NSLog(@"[PatchZQ] GCD 拦截 + 信号备用 + Bundle 保护 已加载");
    }
}
