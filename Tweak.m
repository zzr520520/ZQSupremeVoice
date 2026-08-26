#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

// 全局控制参数
static UIView *g_panelView = nil;
static BOOL g_forceMicOpen = NO;
static float g_audioGain = 3.5f;
static float g_noiseGateThreshold = 150.0f;

// 核心 DSP：软压限（Tanh）+ 噪声门
static inline int16_t apply_soft_limiter(int16_t sample, float gain, float gate) {
    if (abs(sample) < (int)gate) {
        return 0;
    }
    float normalized = ((float)sample / 32768.0f) * gain;
    float saturated = tanhf(normalized);
    return (int16_t)(saturated * 32400.0f);
}

// 内存安全的 PCM 批处理
static void process_raw_pcm(void *bytes, NSUInteger length) {
    if (g_audioGain <= 1.0f && g_noiseGateThreshold <= 0.0f) return;
    if (!bytes || length == 0) return;

    int16_t *samples = (int16_t *)bytes;
    NSUInteger count = length / sizeof(int16_t);

    for (NSUInteger i = 0; i < count; i++) {
        samples[i] = apply_soft_limiter(samples[i], g_audioGain, g_noiseGateThreshold);
    }
}

// UI 控制面板
@interface ZQVoicePanel : NSObject
+ (void)setupGesture;
+ (void)togglePanel;
@end

@implementation ZQVoicePanel

+ (void)setupGesture {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *targetWindow = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { targetWindow = w; break; }
                }
            }
        }
        if (!targetWindow) targetWindow = [UIApplication sharedApplication].keyWindow;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
        tap.numberOfTouchesRequired = 2;
        tap.numberOfTapsRequired = 2;
        [targetWindow addGestureRecognizer:tap];
    });
}

+ (void)togglePanel {
    if (g_panelView) {
        g_panelView.hidden = !g_panelView.hidden;
        return;
    }

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    g_panelView = [[UIView alloc] initWithFrame:CGRectMake(30, 80, 310, 260)];
    g_panelView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    g_panelView.layer.cornerRadius = 14;
    g_panelView.clipsToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, 310, 25)];
    title.text = @"音频上行与麦位控制器";
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:15];
    [g_panelView addSubview:title];

    UILabel *swLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 45, 180, 30)];
    swLabel.text = @"强制维持开麦 (防闭麦)";
    swLabel.textColor = [UIColor whiteColor];
    swLabel.font = [UIFont systemFontOfSize:13];
    [g_panelView addSubview:swLabel];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(240, 45, 50, 30)];
    [sw addTarget:self action:@selector(onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [g_panelView addSubview:sw];

    UILabel *gainLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 85, 280, 20)];
    gainLabel.text = [NSString stringWithFormat:@"上行增益: %.1fx (软压限已挂载)", g_audioGain];
    gainLabel.textColor = [UIColor whiteColor];
    gainLabel.font = [UIFont systemFontOfSize:12];
    gainLabel.tag = 101;
    [g_panelView addSubview:gainLabel];

    UISlider *gainSlider = [[UISlider alloc] initWithFrame:CGRectMake(15, 110, 280, 30)];
    gainSlider.minimumValue = 1.0f;
    gainSlider.maximumValue = 8.0f;
    gainSlider.value = g_audioGain;
    [gainSlider addTarget:self action:@selector(onGainSlider:) forControlEvents:UIControlEventValueChanged];
    [g_panelView addSubview:gainSlider];

    UILabel *gateLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 150, 280, 20)];
    gateLabel.text = [NSString stringWithFormat:@"噪声门限: %.0f", g_noiseGateThreshold];
    gateLabel.textColor = [UIColor whiteColor];
    gateLabel.font = [UIFont systemFontOfSize:12];
    gateLabel.tag = 102;
    [g_panelView addSubview:gateLabel];

    UISlider *gateSlider = [[UISlider alloc] initWithFrame:CGRectMake(15, 175, 280, 30)];
    gateSlider.minimumValue = 0.0f;
    gateSlider.maximumValue = 500.0f;
    gateSlider.value = g_noiseGateThreshold;
    [gateSlider addTarget:self action:@selector(onGateSlider:) forControlEvents:UIControlEventValueChanged];
    [g_panelView addSubview:gateSlider];

    [window addSubview:g_panelView];
}

+ (void)onSwitchChanged:(UISwitch *)sender {
    g_forceMicOpen = sender.isOn;
    if (g_forceMicOpen) {
        Class micEngineClass = NSClassFromString(@"SKPMicEngine");
        SEL sel = NSSelectorFromString(@"openMicro");
        if (micEngineClass && [micEngineClass respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [micEngineClass performSelector:sel];
#pragma clang diagnostic pop
        }
    }
}

+ (void)onGainSlider:(UISlider *)sender {
    g_audioGain = sender.value;
    UILabel *l = [g_panelView viewWithTag:101];
    l.text = [NSString stringWithFormat:@"上行增益: %.1fx (软压限已挂载)", g_audioGain];
}

+ (void)onGateSlider:(UISlider *)sender {
    g_noiseGateThreshold = sender.value;
    UILabel *l = [g_panelView viewWithTag:102];
    l.text = [NSString stringWithFormat:@"噪声门限: %.0f", g_noiseGateThreshold];
}

@end

// ========== Hook 逻辑实现 ==========

static void (*orig_closeMicro)(id self, SEL _cmd);
static void hook_closeMicro(id self, SEL _cmd) {
    if (g_forceMicOpen) return;
    orig_closeMicro(self, _cmd);
}

static void (*orig_pauseAudio)(id self, SEL _cmd);
static void hook_pauseAudio(id self, SEL _cmd) {
    if (g_forceMicOpen) return;
    orig_pauseAudio(self, _cmd);
}

static int (*orig_encodedKbps)(id self, SEL _cmd);
static int hook_encodedKbps(id self, SEL _cmd) { return 192; }

static int (*orig_audioMaxPeak)(id self, SEL _cmd);
static int hook_audioMaxPeak(id self, SEL _cmd) { return 100; }

static void (*orig_setAgc)(id self, SEL _cmd, BOOL enable);
static void hook_setAgc(id self, SEL _cmd, BOOL enable) {
    orig_setAgc(self, _cmd, NO);
}

static void (*orig_setAudioProcessingCallback)(id self, SEL _cmd, id callback);

static void hook_setAudioProcessingCallback(id self, SEL _cmd, id callback) {
    if (!callback) {
        orig_setAudioProcessingCallback(self, _cmd, nil);
        return;
    }

    id wrappedCallback = ^(id pcmData, id extraInfo) {
        if ([pcmData isKindOfClass:[NSMutableData class]]) {
            NSMutableData *data = (NSMutableData *)pcmData;
            process_raw_pcm([data mutableBytes], data.length);
        } else if ([pcmData isKindOfClass:[NSData class]]) {
            NSData *data = (NSData *)pcmData;
            void *buf = (void *)[data bytes];
            process_raw_pcm(buf, data.length);
        }

        ((void(^)(id, id))callback)(pcmData, extraInfo);
    };

    orig_setAudioProcessingCallback(self, _cmd, wrappedCallback);
}

// ========== 构造初始化 ==========
__attribute__((constructor))
static void initialize_tweak() {
    [ZQVoicePanel setupGesture];

    Class micEngine = NSClassFromString(@"SKPMicEngine");
    if (micEngine) {
        Method mClose = class_getInstanceMethod(micEngine, NSSelectorFromString(@"closeMicro"));
        if (mClose) {
            orig_closeMicro = (void *)method_getImplementation(mClose);
            method_setImplementation(mClose, (IMP)hook_closeMicro);
        }
    }

    Class mediaEngine = NSClassFromString(@"SKMediaEngine");
    if (mediaEngine) {
        Method mKbps = class_getInstanceMethod(mediaEngine, NSSelectorFromString(@"audioEncodedKbps"));
        if (mKbps) {
            orig_encodedKbps = (void *)method_getImplementation(mKbps);
            method_setImplementation(mKbps, (IMP)hook_encodedKbps);
        }

        Method mPeak = class_getInstanceMethod(mediaEngine, NSSelectorFromString(@"audioMaxPeak"));
        if (mPeak) {
            orig_audioMaxPeak = (void *)method_getImplementation(mPeak);
            method_setImplementation(mPeak, (IMP)hook_audioMaxPeak);
        }

        Method mPause = class_getInstanceMethod(mediaEngine, NSSelectorFromString(@"pauseAudio"));
        if (mPause) {
            orig_pauseAudio = (void *)method_getImplementation(mPause);
            method_setImplementation(mPause, (IMP)hook_pauseAudio);
        }

        Method mCallback = class_getInstanceMethod(mediaEngine, NSSelectorFromString(@"setAudioProcessingCallback:"));
        if (mCallback) {
            orig_setAudioProcessingCallback = (void *)method_getImplementation(mCallback);
            method_setImplementation(mCallback, (IMP)hook_setAudioProcessingCallback);
        }

        Method mAgc = class_getInstanceMethod(mediaEngine, NSSelectorFromString(@"setAgcEnabled:"));
        if (mAgc) {
            orig_setAgc = (void *)method_getImplementation(mAgc);
            method_setImplementation(mAgc, (IMP)hook_setAgc);
        }
    }
}
