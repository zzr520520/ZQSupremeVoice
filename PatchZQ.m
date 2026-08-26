#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdio.h>
#import <errno.h>
#import <string.h>
#import "fishhook.h"

// ========== 配置区 ==========
static NSString *const kOriginalBundleID = @"com.zhenqu.music";

// ========== 全局原始函数指针 ==========
static NSString *(*orig_bundleIdentifier)(id, SEL);
static NSDictionary *(*orig_infoDictionary)(id, SEL);

static int (*orig_ptrace)(int request, pid_t pid, caddr_t addr, int data);
static FILE *(*orig_fopen)(const char *, const char *);
static int (*orig_open)(const char *, int, ...);

// ========== 1. 伪装 Bundle Identifier ==========
static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return kOriginalBundleID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

// ========== 2. 伪装 infoDictionary ==========
static NSDictionary *hook_infoDictionary(id self, SEL _cmd) {
    NSDictionary *orig = orig_infoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle]) {
        NSMutableDictionary *mutable = [orig mutableCopy];
        mutable[@"CFBundleIdentifier"] = kOriginalBundleID;
        return [mutable copy];
    }
    return orig;
}

// ========== 3. 拦截 ptrace (反调试) ==========
static int my_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == 31) { // PT_DENY_ATTACH
        return 0;
    }
    if (orig_ptrace) {
        return orig_ptrace(request, pid, addr, data);
    }
    return 0;
}

// ========== 4. 拦截 sysctl (反调试检测) ==========
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);

static int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    // KERN_PROC_PID 检测被调试时，清除 P_TRACED 标志
    if (namelen >= 3 && name[0] == CTL_KERN && name[1] == KERN_PROC && oldp != NULL) {
        struct kinfo_proc *proc = (struct kinfo_proc *)oldp;
        proc->kp_proc.p_flag &= ~P_TRACED;
    }
    return ret;
}

// ========== 5. 拦截 fopen (阻止读取签名相关文件) ==========
static FILE *my_fopen(const char *path, const char *mode) {
    if (path) {
        const char *lower_path = path;
        if (strstr(lower_path, "embedded.mobileprovision") ||
            strstr(lower_path, "SC_Info") ||
            strstr(lower_path, "_CodeSignature") ||
            strstr(lower_path, "CodeResources")) {
            errno = ENOENT;
            return NULL;
        }
    }
    return orig_fopen(path, mode);
}

// ========== 6. 拦截 open ==========
static int my_open(const char *path, int flags, ...) {
    if (path) {
        if (strstr(path, "embedded.mobileprovision") ||
            strstr(path, "SC_Info") ||
            strstr(path, "_CodeSignature") ||
            strstr(path, "CodeResources")) {
            errno = ENOENT;
            return -1;
        }
    }
    // 处理可变参数
    va_list args;
    va_start(args, flags);
    mode_t mode = va_arg(args, int);
    va_end(args);
    return orig_open(path, flags, mode);
}

// ========== 构造函数 ==========
__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        // --- Hook NSBundle.bundleIdentifier ---
        Method mBundleID = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
        if (mBundleID) {
            orig_bundleIdentifier = (NSString *(*)(id, SEL))method_getImplementation(mBundleID);
            method_setImplementation(mBundleID, (IMP)hook_bundleIdentifier);
        }

        // --- Hook NSBundle.infoDictionary ---
        Method mInfoDict = class_getInstanceMethod([NSBundle class], @selector(infoDictionary));
        if (mInfoDict) {
            orig_infoDictionary = (NSDictionary *(*)(id, SEL))method_getImplementation(mInfoDict);
            method_setImplementation(mInfoDict, (IMP)hook_infoDictionary);
        }

        // --- fishhook 替换 C 函数符号 ---
        struct rebinding rebindings[] = {
            {"ptrace", (void *)my_ptrace, (void **)&orig_ptrace},
            {"fopen", (void *)my_fopen, (void **)&orig_fopen},
            {"open", (void *)my_open, (void **)&orig_open},
        };

        // 注意：ptrace 在 libsystem_kernel 中，fopen/open 在 libsystem_c 中
        // fishhook 会自动处理懒加载符号
        rebind_symbols(rebindings, 3);

        NSLog(@"[PatchZQ] 签名绕过补丁已加载 - BundleID: %@", kOriginalBundleID);
    }
}
