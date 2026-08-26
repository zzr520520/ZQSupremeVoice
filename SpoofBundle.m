// SpoofBundle.m - Bundle ID 伪装
// 纯 ObjC Method Swizzle，零 C 函数 Hook
// 用途：分身版改了包名后，让 App 内部读取 BundleID 时仍然返回原始值
// 安全性：constructor 在 dyld 装载完成后才执行，不会触发 PC=0 崩溃

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define ORIGINAL_BUNDLE_ID @"com.zhenqu.music"

// ========== Swizzle 辅助 ==========

static IMP swizzle_method(Class cls, SEL origSel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, origSel);
    if (!m) return NULL;
    IMP oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return oldImp;
}

// ========== NSBundle bundleIdentifier ==========

static NSString *(*orig_bundleIdentifier)(id, SEL);

static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    // 主bundle一律返回原始包名
    if (self == [NSBundle mainBundle]) {
        return ORIGINAL_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

// ========== NSBundle objectForInfoDictionaryKey ==========

static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *);

static id hook_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleIdentifier"]) {
        return ORIGINAL_BUNDLE_ID;
    }
    return orig_objectForInfoDictionaryKey(self, _cmd, key);
}

// ========== CFBundleGetIdentifier ==========
// 有些代码用 CoreFoundation 的 C API 读取

static CFStringRef (*orig_CFBundleGetIdentifier)(CFBundleRef);

static CFStringRef hook_CFBundleGetIdentifier(CFBundleRef bundle) {
    if (bundle == CFBundleGetMainBundle()) {
        return (__bridge CFStringRef)ORIGINAL_BUNDLE_ID;
    }
    return orig_CFBundleGetIdentifier(bundle);
}

// ========== 初始化 ==========

__attribute__((constructor(101)))
static void spoof_bundle_init(void) {
    @autoreleasepool {
        Class bCls = [NSBundle class];
        
        // Swizzle NSBundle 实例方法
        orig_bundleIdentifier = (NSString *(*)(id, SEL))
            swizzle_method(bCls, @selector(bundleIdentifier),
                           (IMP)hook_bundleIdentifier);
        
        orig_objectForInfoDictionaryKey = (id (*)(id, SEL, NSString *))
            swizzle_method(bCls, @selector(objectForInfoDictionaryKey:),
                           (IMP)hook_objectForInfoDictionaryKey);
        
        // 也拦截 CFBundleGetIdentifier（CoreFoundation 层）
        // 用 method swizzle 的方式替换 C 函数风险高，
        // 这里只做 ObjC 层就够了，大部分代码走 NSBundle
    }
}
