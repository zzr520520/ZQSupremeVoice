#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"
#define SELF_DESTRUCT_PAGE 0xb5a00000

#pragma mark - 1. GCD 入口拦截（dyld __interpose 机制）
// 不依赖 sigaction（会被 RTC 引擎的 PosixSignalHandler 覆盖）
// 使用 __DATA,__interpose 段在 dyld 绑定层面替换 GCD 函数
// dyld 会将其他镜像中对 original 的引用替换为 replacement
// 但在本镜像内部对 original 的调用不会被替换，因此不会形成递归

static BOOL is_destruct_func(uintptr_t addr) {
    if (addr == 0) return YES;
    // 匹配 0xb5a00000 整页（1MB 范围）
    if ((addr & 0xFFF00000) == SELF_DESTRUCT_PAGE) return YES;
    return NO;
}

// 替换 dispatch_async_f（C 函数指针版本）
static void my_dispatch_async_f(dispatch_queue_t queue,
                                void *context,
                                dispatch_function_t work) {
    if (is_destruct_func((uintptr_t)work)) {
        return;  // 静默丢弃自毁任务
    }
    dispatch_async_f(queue, context, work);  // 调用原始实现
}

// 替换 dispatch_after_f（延迟派发版本）
static void my_dispatch_after_f(dispatch_time_t when,
                                dispatch_queue_t queue,
                                void *context,
                                dispatch_function_t work) {
    if (is_destruct_func((uintptr_t)work)) {
        return;  // 丢弃延迟自毁
    }
    dispatch_after_f(when, queue, context, work);
}

// 替换 dispatch_async（Block 版本）
// 检查 Block 内部的 invoke 函数指针是否指向自毁页
static void my_dispatch_async(dispatch_queue_t queue,
                              dispatch_block_t block) {
    if (block) {
        // Block 结构体: isa(8) flags(4) reserved(4) invoke(8) ...
        // 在 64 位系统上 invoke 位于偏移 16，即 uintptr_t 数组索引 2
        void *raw = (__bridge void *)block;
        uintptr_t *fields = (uintptr_t *)raw;
        uintptr_t invoke = fields[2];
        if (is_destruct_func(invoke)) {
            return;  // 丢弃自毁 Block
        }
    }
    dispatch_async(queue, block);  // 调用原始实现
}

// dyld interpose 注册表
// dyld 扫描此段，将所有其他镜像中对 original 的引用替换为 replacement
__attribute__((used))
static struct {
    void *replacement;
    void *original;
} _zq_interpose_table[]
__attribute__((section("__DATA,__interpose"))) = {
    { (void *)my_dispatch_async_f, (void *)dispatch_async_f },
    { (void *)my_dispatch_after_f,  (void *)dispatch_after_f  },
    { (void *)my_dispatch_async,    (void *)dispatch_async    },
};

#pragma mark - 2. Bundle 标识与路径规范
// bundleIdentifier 返回固定目标 ID，绕过签名校验
// bundleWithPath: 空值安全保护，使 _NSResolveSymlinksInPathUsingCache
// 可以平稳穿透 lstat 路径检查

static NSString *(*orig_bundleIdentifier)(id, SEL);
static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

static NSBundle *(*orig_bundleWithPath)(id, SEL, NSString *);
static NSBundle *hook_bundleWithPath(id self, SEL _cmd, NSString *path) {
    if (!path || [path length] == 0) {
        return nil;
    }
    return orig_bundleWithPath(self, _cmd, path);
}

static void swizzle(Class cls, SEL orig, IMP hook, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, orig);
    if (m) {
        *origOut = method_getImplementation(m);
        method_setImplementation(m, hook);
    }
}

static void swizzleClass(Class cls, SEL orig, IMP hook, IMP *origOut) {
    Method m = class_getClassMethod(cls, orig);
    if (m) {
        *origOut = method_getImplementation(m);
        method_setImplementation(m, hook);
    }
}

#pragma mark - 构造函数

__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        Class bundleCls = [NSBundle class];
        swizzle(bundleCls, @selector(bundleIdentifier),
                (IMP)hook_bundleIdentifier, (IMP *)&orig_bundleIdentifier);
        swizzleClass(bundleCls, @selector(bundleWithPath:),
                     (IMP)hook_bundleWithPath, (IMP *)&orig_bundleWithPath);
        NSLog(@"[PatchZQ] dyld interpose GCD + Bundle 保护 已加载");
    }
}
