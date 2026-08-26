#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define TARGET_BUNDLE_ID @"com.zhenqu.music"

// ========== 原始函数指针 ==========
static NSString *(*orig_bundleIdentifier)(id, SEL);
static NSDictionary *(*orig_infoDictionary)(id, SEL);
static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *);
static NSDictionary *(*orig_localizedInfoDictionary)(id, SEL);

// ========== 1. Hook bundleIdentifier ==========
static NSString *hook_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

// ========== 2. Hook infoDictionary ==========
static NSDictionary *hook_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = orig_infoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBundleIdentifier"] = TARGET_BUNDLE_ID;
        return mDict;
    }
    return dict;
}

// ========== 3. Hook objectForInfoDictionaryKey: ==========
static id hook_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleIdentifier"]) {
        return TARGET_BUNDLE_ID;
    }
    return orig_objectForInfoDictionaryKey(self, _cmd, key);
}

// ========== 4. Hook localizedInfoDictionary ==========
static NSDictionary *hook_localizedInfoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = orig_localizedInfoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBundleIdentifier"] = TARGET_BUNDLE_ID;
        return mDict;
    }
    return dict;
}

// ========== 5. Hook NSFileManager 拦截签名文件读取 ==========
static BOOL (*orig_fileExistsAtPath)(id, SEL, NSString *);
static BOOL hook_fileExistsAtPath(id self, SEL _cmd, NSString *path) {
    if (path && ([path containsString:@"embedded.mobileprovision"] ||
                 [path containsString:@"_CodeSignature"] ||
                 [path containsString:@"SC_Info"] ||
                 [path containsString:@"CodeResources"])) {
        return NO;
    }
    return orig_fileExistsAtPath(self, _cmd, path);
}

static NSData *(*orig_contentsAtPath)(id, SEL, NSString *);
static NSData *hook_contentsAtPath(id self, SEL _cmd, NSString *path) {
    if (path && ([path containsString:@"embedded.mobileprovision"] ||
                 [path containsString:@"SC_Info"] ||
                 [path containsString:@"CodeResources"])) {
        return nil;
    }
    return orig_contentsAtPath(self, _cmd, path);
}

// ========== 辅助函数：方法交换 ==========
static void swizzleInstanceMethod(Class cls, SEL origSel, IMP newImp, IMP *origImpOut) {
    Method m = class_getInstanceMethod(cls, origSel);
    if (m) {
        *origImpOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
    }
}

// ========== 构造函数 ==========
__attribute__((constructor))
static void entry(void) {
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

        // NSFileManager 拦截签名相关文件
        Class fmCls = [NSFileManager defaultManager].class;
        swizzleInstanceMethod(fmCls,
                              @selector(fileExistsAtPath:),
                              (IMP)hook_fileExistsAtPath,
                              (IMP *)&orig_fileExistsAtPath);

        swizzleInstanceMethod(fmCls,
                              @selector(contentsAtPath:),
                              (IMP)hook_contentsAtPath,
                              (IMP *)&orig_contentsAtPath);

        NSLog(@"[PatchZQ] 签名绕过补丁已加载 - BundleID: %@", TARGET_BUNDLE_ID);
    }
}
