#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

#pragma mark - Block 结构体定义

struct Block_descriptor {
    unsigned long int reserved;
    unsigned long int size;
};

struct Block_layout {
    void *isa;
    volatile int32_t flags;
    int32_t reserved;
    void (*invoke)(void *, ...);
    struct Block_descriptor *descriptor;
};

#pragma mark - 自毁地址检测
// iOS arm64 上所有合法代码（系统库、App 二进制、动态库）均映射在
// 0x100000000 (4GB) 以上。0xb5a00000 远低于此阈值，
// 任何低于 0x100000000 的函数指针都是非法自毁地址。

static BOOL is_destruct_func(uintptr_t addr) {
    if (addr == 0) return YES;
    if (addr < 0x100000000) return YES;
    return NO;
}

#pragma mark - GCD 拦截（dyld __interpose 机制）
// 使用 __DATA,__interpose 段在 dyld 绑定层面替换 GCD 函数
// dyld 将其他镜像中对 original 的引用替换为 replacement
// 本镜像内部对 original 的调用不被替换，因此不会递归

// Layer 1: 拦截 dispatch_async_f（C 函数指针版本）
// 主二进制通过 dispatch_async_f(queue, ctx, 0xb5a00000) 派发自毁时拦截
static void my_dispatch_async_f(dispatch_queue_t queue,
                                void *context,
                                dispatch_function_t work) {
    if (is_destruct_func((uintptr_t)work)) {
        NSLog(@"[PatchZQ] BLOCKED dispatch_async_f self-destruct: work=%p", work);
        return;
    }
    dispatch_async_f(queue, context, work);
}

// Layer 1: 拦截 dispatch_after_f（延迟派发）
static void my_dispatch_after_f(dispatch_time_t when,
                                dispatch_queue_t queue,
                                void *context,
                                dispatch_function_t work) {
    if (is_destruct_func((uintptr_t)work)) {
        NSLog(@"[PatchZQ] BLOCKED dispatch_after_f self-destruct: work=%p", work);
        return;
    }
    dispatch_after_f(when, queue, context, work);
}

// Layer 1: 拦截 dispatch_async（Block 版本）
// 检查 Block 内部的 invoke 函数指针
static void my_dispatch_async(dispatch_queue_t queue,
                              dispatch_block_t block) {
    if (block) {
        struct Block_layout *layout = (struct Block_layout *)(__bridge void *)block;
        uintptr_t invoke = (uintptr_t)layout->invoke;
        if (is_destruct_func(invoke)) {
            NSLog(@"[PatchZQ] BLOCKED dispatch_async block self-destruct: invoke=%p",
                  (void *)invoke);
            return;
        }
    }
    dispatch_async(queue, block);
}

// Layer 2: 拦截 _dispatch_call_block_and_release（Block 执行入口）
// 这是 dispatch 系统在 worker 线程中实际调用 Block 的函数
// 即使主二进制绕过公开 API 直接将 Block 推入队列，
// 执行时也必然经过此函数
extern void _dispatch_call_block_and_release(void *block);
static void my_dispatch_call_block_and_release(void *block) {
    if (block) {
        struct Block_layout *layout = (struct Block_layout *)block;
        uintptr_t invoke = (uintptr_t)layout->invoke;
        if (is_destruct_func(invoke)) {
            NSLog(@"[PatchZQ] BLOCKED _dispatch_call_block_and_release self-destruct: invoke=%p",
                  (void *)invoke);
            // 释放 Block 避免内存泄漏
            extern void _Block_release(const void *);
            _Block_release(block);
            return;
        }
    }
    _dispatch_call_block_and_release(block);
}

// dyld interpose 注册表
__attribute__((used))
static struct {
    void *replacement;
    void *original;
} _zq_interpose_table[]
__attribute__((section("__DATA,__interpose"))) = {
    { (void *)my_dispatch_async_f,                (void *)dispatch_async_f },
    { (void *)my_dispatch_after_f,                 (void *)dispatch_after_f  },
    { (void *)my_dispatch_async,                   (void *)dispatch_async    },
    { (void *)my_dispatch_call_block_and_release,   (void *)_dispatch_call_block_and_release },
};

#pragma mark - Bundle 伪装

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
        swizzle(bundleCls, @selector(objectForInfoDictionaryKey:),
                (IMP)hook_objectForInfoDictionaryKey, (IMP *)&orig_objectForInfoDictionaryKey);
        swizzleClass(bundleCls, @selector(bundleWithPath:),
                     (IMP)hook_bundleWithPath, (IMP *)&orig_bundleWithPath);
        NSLog(@"[PatchZQ] interpose GCD (async_f/after_f/async/call_block) + Bundle 保护 已加载");
    }
}
