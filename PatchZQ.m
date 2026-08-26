#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <signal.h>
#import <pthread.h>
#import <string.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ========== 自毁地址特征 ==========
// 安全引擎检测失败时，故意跳转到 0xb5a00000 附近触发段错误
#define SELF_DESTRUCT_BASE 0xb5a00000

// ========== 信号捕获：拦截自毁 ==========
// 仅做一件事：捕获指向自毁地址的段错误，安全退出当前子线程
// 不 Hook 任何文件 API，确保 Assets.car / CoreUI 正常加载

static struct sigaction g_orig_sigsegv;
static struct sigaction g_orig_sigbus;
static struct sigaction g_orig_sigill;

static BOOL is_self_destruct_addr(uintptr_t addr) {
    // 匹配 0xb5a00000 整个 1MB 页内的地址
    if ((addr & 0xFFF00000) == SELF_DESTRUCT_BASE) {
        return YES;
    }
    // 空指针解引用也可能是自毁的一种形式
    if (addr == 0x0 || addr < 0x1000) {
        return YES;
    }
    return NO;
}

static void custom_sig_handler(int sig, siginfo_t *info, void *context) {
    if (info && is_self_destruct_addr((uintptr_t)info->si_addr)) {
        // 自毁触发 → 仅退出当前子线程，保全主进程
        pthread_exit(NULL);
    }

    // 非自毁信号，转交原始处理
    struct sigaction *orig = NULL;
    if (sig == SIGSEGV) orig = &g_orig_sigsegv;
    else if (sig == SIGBUS) orig = &g_orig_sigbus;
    else if (sig == SIGILL) orig = &g_orig_sigill;

    if (orig && orig->sa_sigaction) {
        orig->sa_sigaction(sig, info, context);
    }
}

// ========== Bundle 伪装 ==========
// 仅 Hook bundleIdentifier，不碰 infoDictionary / NSData / NSFileManager
// 最大限度减少对系统正常流程的干扰

static NSString *(*orig_bundleIdentifier)(id, SEL);
static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

// ========== 构造函数 ==========
__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        // ---- 注册信号捕获 ----
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = custom_sig_handler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;

        // 保存原始处理
        sigaction(SIGSEGV, NULL, &g_orig_sigsegv);
        sigaction(SIGBUS, NULL, &g_orig_sigbus);
        sigaction(SIGILL, NULL, &g_orig_sigill);

        // 注册我们的处理
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGILL, &sa, NULL);

        // ---- Bundle 伪装 ----
        Class bundleCls = [NSBundle class];
        Method m = class_getInstanceMethod(bundleCls, @selector(bundleIdentifier));
        if (m) {
            orig_bundleIdentifier = (NSString *(*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_bundleIdentifier);
        }

        NSLog(@"[PatchZQ] 自毁防护补丁已加载 - 极简模式");
    }
}
