// PatchZQ.m - Keychain 权限拦截补丁
// 仅拦截 Security.framework 的 Keychain 接口，防止个人证书因缺少 keychain-access-groups 权限而崩溃
// 使用 dyld __interpose 机制确保拦截生效

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ==================== Keychain 拦截 ====================
// 个人证书没有原版 App 的 keychain-access-groups 授权
// SecItemCopyMatching 会被 securityd 拒绝，导致 App 崩溃

typedef OSStatus (*SecItemCopyMatching_t)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*SecItemAdd_t)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*SecItemUpdate_t)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*SecItemDelete_t)(CFDictionaryRef);

// 替换函数：直接返回空/成功，让 App 走降级逻辑
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

// dyld interpose 结构
struct interpose_s {
    void *replacement;
    void *original;
};

// __DATA,__interpose 段：dyld 会在加载时替换所有镜像对 original 的绑定
#define ZQ_INTERPOSE(_repl, _orig) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static struct interpose_s _interpose_##_orig = { (void *)_repl, (void *)_orig }

ZQ_INTERPOSE(my_SecItemCopyMatching, SecItemCopyMatching);
ZQ_INTERPOSE(my_SecItemAdd, SecItemAdd);
ZQ_INTERPOSE(my_SecItemUpdate, SecItemUpdate);
ZQ_INTERPOSE(my_SecItemDelete, SecItemDelete);

// ==================== 诊断日志 ====================

__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
        // 静默加载，不输出任何日志
    }
}
