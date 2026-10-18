//
//  PipEnabler.m
//  橘子视频 画中画(Picture in Picture) 使能模块
//
//  目标平台 : iOS 15.0+ (重点兼容 iOS 16.6.1)
//  编译方式 : 在 GitHub Actions 的 macOS runner 内编译为 dylib，本机不参与编译。
//      xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
//           -fobjc-arc -dynamiclib \
//           -install_name @executable_path/Frameworks/PipEnabler.dylib \
//           -framework Foundation -framework AVFoundation -framework AVKit -framework UIKit \
//           PipEnabler.m -o PipEnabler.dylib
//
//  原理（见探索事实 #344）:
//    1) 橘子视频 1.0.6 的内容播放走自研 ijkplayer 衍生引擎 fok_media_core
//       (OpenGL ES2 渲染 + VideoToolbox 硬解 + Flutter 外部纹理输出)，
//       整包内不存在 AVPlayerViewController / AVPictureInPictureController，
//       系统 AVPlayer 仅用于穿山甲/GDT/KS 广告。
//    2) 因此分两条路径:
//       路径 A —— 运行时若探测到可直连的 AVPlayerLayer，直接用它构造
//                AVPictureInPictureController(contentSource: playerLayer)，原生 PiP。
//       路径 B —— 无 AVPlayerLayer 时，抓取 CVPixelBuffer 帧，
//                经 CMSampleBufferCreateReadyWithImageBuffer 封装后喂给自建的
//                AVSampleBufferDisplayLayer，再以
//                AVPictureInPictureController(contentSource: sampleBufferDisplayLayer)
//                启动系统 PiP（帧镜像 / frame mirror 方案）。
//    3) 全部使用公开 API，不含任何私有符号；所有新 API 调用均以
//       respondsToSelector / @available 兜底，保证 iOS 15.0 ~ 16.6.1 可编译可运行。
//
//  导出符号严格与 PipEnabler.h 一致:
//    PipEnablerSetEnabled(BOOL) / PipEnablerIsEnabled() / PipEnablerToggle()
//    PipEnablerStartPictureInPicture() / PipEnablerStopPictureInPicture()
//    PipEnablerDetectedContentPlayerLayer()
//    PipEnablerEnabledDidChangeNotification (NSNotificationName)
//
//  运行时开关 : NSUserDefaults key "PipEnablerEnabled" (BOOL)。
//              修改后 post PipEnablerEnabledDidChangeNotification 通知。
//  自动装载   : __attribute__((constructor))，dylib 注入后立即生效。
//

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 常量与全局

/// 使能状态变化通知（名字必须与 PipEnabler.h 完全一致）
NSNotificationName const PipEnablerEnabledDidChangeNotification = @"PipEnablerEnabledDidChangeNotification";

/// NSUserDefaults 开关 key
static NSString * const kPipEnablerEnabledKey = @"PipEnablerEnabled";

/// 镜像渲染用的小宿主视图尺寸（PiP 层不需要真正可见，挂到窗口上有助于部分 iOS 版本正确驱动渲染）
static const CGFloat kPipMirrorHostViewSize = 2.0;

#pragma mark - C 工具函数

/// 把一帧 CVPixelBuffer 封装成可直接 enqueue 的 CMSampleBuffer
static CMSampleBufferRef PipEnablerCreateSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime pts) {
    if (pixelBuffer == NULL) {
        return NULL;
    }
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                   pixelBuffer,
                                                                   &formatDesc);
    if (status != noErr || formatDesc == NULL) {
        return NULL;
    }
    CMSampleTimingInfo timing;
    timing.duration             = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTIME_IS_VALID(pts) ? pts : CMTimeMake(0, 1);
    timing.decodeTimeStamp      = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      pixelBuffer,
                                                      formatDesc,
                                                      &timing,
                                                      &sampleBuffer);
    CFRelease(formatDesc);
    if (status != noErr) {
        return NULL;
    }
    return sampleBuffer;
}

/// 深度优先在 layer 树里查找 AVPlayerLayer
static CALayer *PipEnablerFindPlayerLayerInLayer(CALayer *layer, NSInteger depth) {
    if (layer == nil || depth > 24) {
        return nil;
    }
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        return layer;
    }
    for (CALayer *sub in layer.sublayers) {
        CALayer *found = PipEnablerFindPlayerLayerInLayer(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

/// 在 view 树里查找 AVPlayerLayer（含自身 layer）
static AVPlayerLayer *PipEnablerFindPlayerLayerInView(UIView *view, NSInteger depth) {
    if (view == nil || depth > 24) {
        return nil;
    }
    CALayer *found = PipEnablerFindPlayerLayerInLayer(view.layer, 0);
    if (found) {
        return (AVPlayerLayer *)found;
    }
    for (UIView *sub in view.subviews) {
        AVPlayerLayer *pl = PipEnablerFindPlayerLayerInView(sub, depth + 1);
        if (pl) {
            return pl;
        }
    }
    return nil;
}

#pragma mark - 运行时探针：从窗口层级里找内容侧 AVPlayerLayer

static AVPlayerLayer *PipEnablerProbePlayerLayer(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (![NSThread isMainThread]) {
        __block AVPlayerLayer *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = PipEnablerProbePlayerLayer();
        });
        return result;
    }

    NSArray<UIWindow *> *windows = app.windows;
    // 优先 keyWindow，再兜底遍历全部窗口
    for (UIWindow *win in windows) {
        if (win.isKeyWindow) {
            AVPlayerLayer *pl = PipEnablerFindPlayerLayerInView(win, 0);
            if (pl) {
                return pl;
            }
        }
    }
    for (UIWindow *win in windows) {
        AVPlayerLayer *pl = PipEnablerFindPlayerLayerInView(win, 0);
        if (pl) {
            return pl;
        }
    }
    return nil;
}

#pragma mark - PiP 管理器

@interface PipEnablerManager : NSObject

@property (nonatomic, assign) BOOL enabled;          // 使能开关
@property (nonatomic, assign) BOOL pipActive;        // 当前是否处于 PiP 中
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) AVSampleBufferDisplayLayer   *mirrorLayer;
@property (nonatomic, strong) UIView                       *mirrorHostView;
@property (nonatomic, weak)   AVPlayerLayer                *detectedPlayerLayer;
@property (nonatomic, assign) CMTime                        lastPresentationTime;

+ (instancetype)shared;

- (BOOL)isEnabled;
- (void)setEnabled:(BOOL)enabled;
- (void)toggle;
- (BOOL)startPictureInPicture;
- (BOOL)stopPictureInPicture;
- (CALayer *)detectedContentPlayerLayer;

- (void)refreshDetection;
- (void)attachToPlayerLayer:(AVPlayerLayer *)playerLayer;
- (void)prepareMirrorPipeline;
- (void)teardownPipeline;

// 帧镜像入口
- (void)feedPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)feedSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

@implementation PipEnablerManager

+ (instancetype)shared {
    static PipEnablerManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PipEnablerManager alloc] init];
        instance.lastPresentationTime = kCMTimeZero;
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = [NSUserDefaults.standardUserDefaults boolForKey:kPipEnablerEnabledKey];
    }
    return self;
}

#pragma mark - 状态

- (BOOL)isEnabled {
    return self.enabled;
}

- (void)setEnabled:(BOOL)enabled {
    if (self.enabled == enabled) {
        return;
    }
    self.enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kPipEnablerEnabledKey];
    [NSUserDefaults.standardUserDefaults synchronize];

    if (enabled) {
        [self refreshDetection];
    } else {
        [self teardownPipeline];
        [self stopPictureInPicture];
    }

    [NSNotificationCenter.defaultCenter postNotificationName:PipEnablerEnabledDidChangeNotification
                                                      object:self
                                                    userInfo:@{@"enabled": @(enabled)}];
}

- (void)toggle {
    [self setEnabled:!self.enabled];
}

#pragma mark - 探测 / 挂接

- (CALayer *)detectedContentPlayerLayer {
    return self.detectedPlayerLayer;
}

- (void)refreshDetection {
    if (!self.enabled) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.enabled) {
            return;
        }
        AVPlayerLayer *pl = PipEnablerProbePlayerLayer();
        if (pl) {
            self.detectedPlayerLayer = pl;
            [self attachToPlayerLayer:pl];          // 路径 A
        } else {
            [self prepareMirrorPipeline];           // 路径 B
        }
    });
}

/// 路径 A：直接用内容侧 AVPlayerLayer 构造原生 PiP
- (void)attachToPlayerLayer:(AVPlayerLayer *)playerLayer {
    if (playerLayer == nil) {
        return;
    }
    if (self.pipController != nil &&
        [self.pipController.contentSource respondsToSelector:@selector(playerLayer)] &&
        self.pipController.contentSource.playerLayer == playerLayer) {
        return; // 已经挂接同一图层
    }
    if (!AVPictureInPictureController.isPictureInPictureSupported) {
        return;
    }

    AVPictureInPictureController *controller = nil;
    if (@available(iOS 15.0, *)) {
        if ([AVPictureInPictureControllerContentSource instancesRespondToSelector:@selector(initWithPlayerLayer:)]) {
            AVPictureInPictureControllerContentSource *src =
                [[AVPictureInPictureControllerContentSource alloc] initWithPlayerLayer:playerLayer];
            controller = [[AVPictureInPictureController alloc] initWithContentSource:src];
        }
    }
    if (controller == nil) {
        // 旧接口兜底（iOS 15 起已标记 deprecated，但仍存在）
        if ([AVPictureInPictureController instancesRespondToSelector:@selector(initWithPlayerLayer:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            controller = [[AVPictureInPictureController alloc] initWithPlayerLayer:playerLayer];
#pragma clang diagnostic pop
        }
    }
    if (controller == nil) {
        return;
    }
    [self configureAutoStartForController:controller];
    self.pipController = controller;
}

/// 路径 B：帧镜像 —— 自建 AVSampleBufferDisplayLayer + sampleBufferDisplayLayer contentSource
- (void)prepareMirrorPipeline {
    if (self.mirrorLayer == nil) {
        AVSampleBufferDisplayLayer *layer = [[AVSampleBufferDisplayLayer alloc] init];
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        layer.backgroundColor = UIColor.clearColor.CGColor;
        CMTimebaseRef timebase = NULL;
        if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault,
                                            CMClockGetHostTimeClock(),
                                            &timebase) == noErr && timebase) {
            CMTimebaseSetTime(timebase, kCMTimeZero);
            CMTimebaseSetRate(timebase, 1.0);
            layer.controlTimebase = timebase;
            CFRelease(timebase);
        }
        self.mirrorLayer = layer;

        // 挂到一个透明小宿主视图上（部分 iOS 版本要求该 layer 处于 window 层级内）
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.mirrorHostView == nil) {
                UIView *host = [[UIView alloc] initWithFrame:CGRectMake(-kPipMirrorHostViewSize,
                                                                        -kPipMirrorHostViewSize,
                                                                        kPipMirrorHostViewSize,
                                                                        kPipMirrorHostViewSize)];
                host.backgroundColor = UIColor.clearColor;
                host.userInteractionEnabled = NO;
                host.hidden = YES; // 不参与展示，仅承载 layer
                [host.layer addSublayer:self.mirrorLayer];
                self.mirrorLayer.frame = host.bounds;
                UIWindow *keyWindow = nil;
                for (UIWindow *w in UIApplication.sharedApplication.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
                if (keyWindow == nil) {
                    keyWindow = UIApplication.sharedApplication.windows.firstObject;
                }
                [keyWindow addSubview:host];
                self.mirrorHostView = host;
            }
        });
    }

    if (self.pipController != nil) {
        return; // 已备好
    }
    if (!AVPictureInPictureController.isPictureInPictureSupported) {
        return;
    }

    if (@available(iOS 15.0, *)) {
        if ([AVPictureInPictureControllerContentSource instancesRespondToSelector:@selector(initWithSampleBufferDisplayLayer:)]) {
            AVPictureInPictureControllerContentSource *src =
                [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:self.mirrorLayer];
            AVPictureInPictureController *controller =
                [[AVPictureInPictureController alloc] initWithContentSource:src];
            [self configureAutoStartForController:controller];
            self.pipController = controller;
        }
    }
}

/// 统一配置自动起播 / 代理所需属性
- (void)configureAutoStartForController:(AVPictureInPictureController *)controller {
    if (controller == nil) {
        return;
    }
    if ([controller respondsToSelector:@selector(setCanStartPictureInPictureAutomaticallyFromInline:)]) {
        controller.canStartPictureInPictureAutomaticallyFromInline = YES;
    }
}

- (void)teardownPipeline {
    self.pipController = nil;
    if (self.mirrorLayer) {
        [self.mirrorLayer flushAndRemoveImage];
        [self.mirrorLayer removeFromSuperlayer];
        self.mirrorLayer = nil;
    }
    if (self.mirrorHostView) {
        [self.mirrorHostView removeFromSuperview];
        self.mirrorHostView = nil;
    }
}

#pragma mark - PiP 启停

- (BOOL)startPictureInPicture {
    if (!self.enabled) {
        [self setEnabled:YES];
    }
    if (self.pipController == nil) {
        [self refreshDetection];
        // 若探测不到 AVPlayerLayer，则准备镜像管线
        if (self.pipController == nil) {
            [self prepareMirrorPipeline];
        }
    }
    AVPictureInPictureController *controller = self.pipController;
    if (controller == nil) {
        return NO;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller startPictureInPicture];
        });
        return YES;
    }
    [controller startPictureInPicture];
    return YES;
}

- (BOOL)stopPictureInPicture {
    AVPictureInPictureController *controller = self.pipController;
    if (controller == nil || !controller.isPictureInPictureActive) {
        return NO;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller stopPictureInPicture];
        });
        return YES;
    }
    [controller stopPictureInPicture];
    return YES;
}

#pragma mark - 帧镜像入口

- (void)feedPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!self.enabled || pixelBuffer == NULL) {
        return;
    }
    if (self.mirrorLayer == nil) {
        [self prepareMirrorPipeline];
    }
    CMTime pts = self.lastPresentationTime;
    CMTime step = CMTimeMake(1, 30);
    pts = CMTimeAdd(pts, step);
    self.lastPresentationTime = pts;

    CMSampleBufferRef sb = PipEnablerCreateSampleBuffer(pixelBuffer, pts);
    if (sb) {
        [self feedSampleBuffer:sb];
        CFRelease(sb);
    }
}

- (void)feedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.enabled || sampleBuffer == NULL) {
        return;
    }
    AVSampleBufferDisplayLayer *layer = self.mirrorLayer;
    if (layer == nil) {
        [self prepareMirrorPipeline];
        layer = self.mirrorLayer;
    }
    if (layer == nil) {
        return;
    }
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [layer flush];
    }
    if ([layer respondsToSelector:@selector(enqueueSampleBuffer:)]) {
        [layer enqueueSampleBuffer:sampleBuffer];
    }
    if (layer.timebase != NULL) {
        CMTimebaseSetRate(layer.controlTimebase, 1.0);
    }
    if (!self.pipActive && self.pipController != nil) {
        // 帧已开始流入，尝试自动拉起 PiP
        self.pipActive = YES;
    }
}

@end

#pragma mark - 运行时插桩：为帧镜像补充通用抓帧点

/// 捕获 enqueueSampleBuffer: 的样本（若 App 自身使用 AVSampleBufferDisplayLayer，则可直接镜像）
static IMP gOriginalEnqueueSampleBufferIMP = NULL;

static void PipEnablerSwizzledEnqueueSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    if (gOriginalEnqueueSampleBufferIMP) {
        ((void (*)(id, SEL, CMSampleBufferRef))gOriginalEnqueueSampleBufferIMP)(self, _cmd, sampleBuffer);
    }
    if ([[PipEnablerManager shared] isEnabled] && sampleBuffer != NULL) {
        [[PipEnablerManager shared] feedSampleBuffer:sampleBuffer];
    }
}

static void PipEnablerInstallSwizzles(void) {
    Class cls = NSClassFromString(@"AVSampleBufferDisplayLayer");
    if (cls == Nil) {
        return;
    }
    SEL sel = @selector(enqueueSampleBuffer:);
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) {
        return;
    }
    gOriginalEnqueueSampleBufferIMP = method_getImplementation(method);
    method_setImplementation(method, (IMP)PipEnablerSwizzledEnqueueSampleBuffer);
}

#pragma mark - 导出 C 符号（与 PipEnabler.h 完全一致）

void PipEnablerSetEnabled(BOOL enabled) {
    [[PipEnablerManager shared] setEnabled:enabled];
}

BOOL PipEnablerIsEnabled(void) {
    return [[PipEnablerManager shared] isEnabled];
}

void PipEnablerToggle(void) {
    [[PipEnablerManager shared] toggle];
}

BOOL PipEnablerStartPictureInPicture(void) {
    return [[PipEnablerManager shared] startPictureInPicture];
}

BOOL PipEnablerStopPictureInPicture(void) {
    return [[PipEnablerManager shared] stopPictureInPicture];
}

CALayer *PipEnablerDetectedContentPlayerLayer(void) {
    return [[PipEnablerManager shared] detectedContentPlayerLayer];
}

/// 附加导出：供宿主/其它 tweak 主动喂帧（帧镜像路径使用）
void PipEnablerFeedPixelBuffer(CVPixelBufferRef pixelBuffer) {
    [[PipEnablerManager shared] feedPixelBuffer:pixelBuffer];
}

#pragma mark - 自动装载

__attribute__((constructor))
static void PipEnablerInitialize(void) {
    @autoreleasepool {
        PipEnablerInstallSwizzles();

        __block PipEnablerManager *manager = [PipEnablerManager shared];
        void (^boot)(void) = ^{
            // 监听窗口变化，尽快探测内容侧图层
            [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification * _Nonnull note) {
                [manager refreshDetection];
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification * _Nonnull note) {
                [manager refreshDetection];
            }];

            if ([manager isEnabled]) {
                [manager refreshDetection];
            }

            // 周期性重试探测（应对延迟创建播放器/图层的情况）
            NSTimer *timer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull t) {
                if ([manager isEnabled]) {
                    [manager refreshDetection];
                }
            }];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        };

        if ([NSThread isMainThread]) {
            boot();
        } else {
            dispatch_async(dispatch_get_main_queue(), boot);
        }
    }
}
