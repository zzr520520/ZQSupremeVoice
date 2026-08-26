#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

#pragma mark - Block 结构体定义

struct Block_layout {
    void *isa;
    volatile int32_t flags;
    int32_t reserved;
    void (*invoke)(void *, ...);
    void *descriptor;
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
static void my_dispatch_async_f(dispatch_queue_t queue,
                                void *context,
                                dispatch_function_t work) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[PatchZQ] dispatch_async_f interpose ACTIVE");
    });
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
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[PatchZQ] dispatch_async interpose ACTIVE");
    });
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

// dyld interpose 注册表（仅含导出符号，_dispatch_call_block_and_release 未导出）
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
        // 诊断：检查 _dispatch_call_block_and_release 是否可通过 dlsym 找到
        // 该函数是 libdispatch 内部 Block 执行入口，未在 iOS SDK 中导出
        void *call_block = dlsym(RTLD_DEFAULT, "_dispatch_call_block_and_release");
        NSLog(@"[PatchZQ] _dispatch_call_block_and_release = %p", call_block);

        Class bundleCls = [NSBundle class];
        swizzle(bundleCls, @selector(bundleIdentifier),
                (IMP)hook_bundleIdentifier, (IMP *)&orig_bundleIdentifier);
        swizzle(bundleCls, @selector(objectForInfoDictionaryKey:),
                (IMP)hook_objectForInfoDictionaryKey, (IMP *)&orig_objectForInfoDictionaryKey);
        swizzleClass(bundleCls, @selector(bundleWithPath:),
                     (IMP)hook_bundleWithPath, (IMP *)&orig_bundleWithPath);
        NSLog(@"[PatchZQ] interpose GCD (async_f/after_f/async) + Bundle 保护 已加载");
    }
}
