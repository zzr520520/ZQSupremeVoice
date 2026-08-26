#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>
#import <dlfcn.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ==================== 1. 核心：拦截 memmem（让签名自检永远通过） ====================
// 加固代码在 Thread 2 通过 memmem 扫描二进制中的 TeamID / 签名字符串特征。
// 扫描不匹配 → 触发自毁。
// 扫描匹配 → 判定为正版，一切正常。
//
// 使用 dyld __DATA,__interpose 段在绑定层面替换 memmem，
// 确保主二进制中所有对 memmem 的调用都会先经过我们的过滤。
//
// 本镜像内部对 memmem 的调用不会被替换（__interpose 语义），
// 因此可以安全地在 hook 函数内调用原始 memmem，不会递归。

typedef void *(*memmem_fn_t)(const void *, size_t, const void *, size_t);

static void *my_memmem(const void *haystack, size_t haystacklen,
                       const void *needle, size_t needlelen) {
    // 拦截对原版 TeamID 的搜索
    // 7QW5G8QMV9 是官方原版 Apple Developer Team ID
    if (needle && needlelen == 10 && haystack && haystacklen >= needlelen) {
        if (memcmp(needle, "7QW5G8QMV9", 10) == 0) {
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                NSLog(@"[PatchZQ] memmem: TeamID 7QW5G8QMV9 命中，伪装通过");
            });
            // 返回 haystack 起始地址作为"找到的位置"
            // 调用方只判断返回值是否为 NULL，因此起始地址安全
            return (void *)haystack;
        }
    }

    // 拦截对包名的搜索（加固可能同时扫描 CFBundleIdentifier）
    if (needle && needlelen == 16 && haystack && haystacklen >= needlelen) {
        if (memcmp(needle, "com.zhenqu.music", 16) == 0) {
            return (void *)haystack;
        }
    }

    return memmem(haystack, haystacklen, needle, needlelen);
}

// dyld interpose 注册表
__attribute__((used))
static struct {
    void *replacement;
    void *original;
} _zq_interpose_table[]
__attribute__((section("__DATA,__interpose"))) = {
    { (void *)my_memmem, (void *)memmem },
};

// ==================== 2. Bundle 伪装 ====================

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

// ==================== 构造函数 ====================

__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        Class bCls = [NSBundle class];
        swizzle(bCls, @selector(bundleIdentifier),
                (IMP)hook_bundleIdentifier, (IMP *)&orig_bundleIdentifier);
        swizzle(bCls, @selector(objectForInfoDictionaryKey:),
                (IMP)hook_objectForInfoDictionaryKey, (IMP *)&orig_objectForInfoDictionaryKey);
        NSLog(@"[PatchZQ] memmem interpose + Bundle 伪装 已加载");
    }
}
