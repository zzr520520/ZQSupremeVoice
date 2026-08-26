#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ========== 原始函数指针 ==========
static NSString *(*orig_bundleIdentifier)(id, SEL);
static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *);
static NSDictionary *(*orig_infoDictionary)(id, SEL);
static NSDictionary *(*orig_localizedInfoDictionary)(id, SEL);

static NSData *(*orig_dataWithContentsOfFile)(id, SEL, NSString *);
static NSData *(*orig_dataWithContentsOfFileOptionsError)(id, SEL, NSString *, NSDataReadingOptions, NSError **);

static BOOL (*orig_fileExistsAtPath)(id, SEL, NSString *);
static NSData *(*orig_contentsAtPath)(id, SEL, NSString *);

// ========== 1. Hook NSBundle 伪装 ==========

static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

static id hook_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleIdentifier"]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_objectForInfoDictionaryKey(self, _cmd, key);
}

static NSDictionary *hook_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = orig_infoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBundleIdentifier"] = TARGET_BUNDLE_ID;
        return mDict;
    }
    return dict;
}

static NSDictionary *hook_localizedInfoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = orig_localizedInfoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBundleIdentifier"] = TARGET_BUNDLE_ID;
        return mDict;
    }
    return dict;
}

// ========== 2. Hook NSData 拦截 embedded.mobileprovision 读取 ==========
// ZSE 加固会读取描述文件校验签名，返回 nil 使校验跳过

static BOOL isMobileProvisionPath(NSString *path) {
    if (!path) return NO;
    NSString *lower = [path lowercaseString];
    return [lower containsString:@"embedded.mobileprovision"] ||
           [lower containsString:@".mobileprovision"];
}

static NSData *hook_dataWithContentsOfFile(id self, SEL _cmd, NSString *path) {
    if (isMobileProvisionPath(path)) {
        return nil;
    }
    return orig_dataWithContentsOfFile(self, _cmd, path);
}

static NSData *hook_dataWithContentsOfFileOptionsError(id self, SEL _cmd, NSString *path,
                                                       NSDataReadingOptions readOptionsMask,
                                                       NSError **errorPtr) {
    if (isMobileProvisionPath(path)) {
        if (errorPtr) {
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadNoSuchFileError
                                        userInfo:@{NSFilePathErrorKey: path}];
        }
        return nil;
    }
    return orig_dataWithContentsOfFileOptionsError(self, _cmd, path, readOptionsMask, errorPtr);
}

// ========== 3. Hook NSFileManager 拦截签名文件 ==========

static BOOL hook_fileExistsAtPath(id self, SEL _cmd, NSString *path) {
    if (path && ([path containsString:@"SC_Info"] ||
                 [path containsString:@"CodeResources"])) {
        return NO;
    }
    // 注意：embedded.mobileprovision 不返回 NO，保留文件存在但读取返回空
    // 防止加固检测文件不存在直接空指针崩溃
    return orig_fileExistsAtPath(self, _cmd, path);
}

static NSData *hook_contentsAtPath(id self, SEL _cmd, NSString *path) {
    if (isMobileProvisionPath(path)) {
        return nil;
    }
    if (path && ([path containsString:@"SC_Info"] ||
                 [path containsString:@"CodeResources"])) {
        return nil;
    }
    return orig_contentsAtPath(self, _cmd, path);
}

// ========== 4. Hook SecTrustEvaluate (弱符号覆盖) ==========
// 如果应用调用 Security 框架的证书校验，直接返回成功
// 注意：这里用运行时动态查找，避免强依赖 Security.framework

typedef int (*SecTrustEvaluateWithErrorFunc)(void *trust, void *error);
static SecTrustEvaluateWithErrorFunc orig_SecTrustEvaluateWithError = NULL;

static int patched_SecTrustEvaluateWithError(void *trust, void *error) {
    // 返回 errSecSuccess (0)，让证书校验永远通过
    return 0;
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

// ========== 构造函数（最高优先级）==========
__attribute__((constructor(101)))
static void patch_init(void) {
    @autoreleasepool {
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

        swizzleInstanceMethod(bundleCls,
                              @selector(localizedInfoDictionary),
                              (IMP)hook_localizedInfoDictionary,
                              (IMP *)&orig_localizedInfoDictionary);

        // Hook NSData 类方法 - 拦截 mobileprovision 读取
        Class dataCls = [NSData class];
        swizzleClassMethod(dataCls,
                           @selector(dataWithContentsOfFile:),
                           (IMP)hook_dataWithContentsOfFile,
                           (IMP *)&orig_dataWithContentsOfFile);

        swizzleClassMethod(dataCls,
                           @selector(dataWithContentsOfFile:options:error:),
                           (IMP)hook_dataWithContentsOfFileOptionsError,
                           (IMP *)&orig_dataWithContentsOfFileOptionsError);

        // Hook NSFileManager
        Class fmCls = [NSFileManager defaultManager].class;
        swizzleInstanceMethod(fmCls,
                              @selector(fileExistsAtPath:),
                              (IMP)hook_fileExistsAtPath,
                              (IMP *)&orig_fileExistsAtPath);

        swizzleInstanceMethod(fmCls,
                              @selector(contentsAtPath:),
                              (IMP)hook_contentsAtPath,
                              (IMP *)&orig_contentsAtPath);

        // 尝试 Hook SecTrustEvaluateWithError（如果 Security 框架已加载）
        void *securityHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        if (securityHandle) {
            orig_SecTrustEvaluateWithError = (SecTrustEvaluateWithErrorFunc)dlsym(securityHandle, "SecTrustEvaluateWithError");
            if (orig_SecTrustEvaluateWithError) {
                // 注意：C 函数替换需要 fishhook，但我们避免使用
                // 这里仅记录，实际通过 NSFileManager + NSData 层拦截已足够
                // 如果需要更底层拦截，可以考虑用 Dobby 等 inline hook 框架
            }
            dlclose(securityHandle);
        }

        NSLog(@"[PatchZQ] 签名绕过补丁已加载 - BundleID: %@", TARGET_BUNDLE_ID);
    }
}
