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
//           -framework CoreMedia -framework CoreVideo \
//           PipEnabler.m -o PipEnabler.dylib
//
//  原理（见探索事实 #344 / #366）:
//    1) 橘子视频 1.0.6 的内容播放走自研 ijkplayer 衍生引擎 fok_media_core
//       (OpenGL ES2 渲染 + VideoToolbox 硬解)，整包内不存在 AVPlayerViewController /
//       AVPictureInPictureController，系统 AVPlayer 仅用于穿山甲/GDT/KS 广告。
//    2) 因此分两条路径:
//       路径 A —— 运行时若探测到可直连的 AVPlayerLayer，直接用它构造
//                AVPictureInPictureController(contentSource: playerLayer)，原生 PiP。
//       路径 B —— 无 AVPlayerLayer 时，抓取 CVPixelBuffer 帧，
//                经 CMSampleBufferCreateReadyWithImageBuffer 封装后喂给自建的
//                AVSampleBufferDisplayLayer，再以
//                AVPictureInPictureController(contentSource: sampleBufferDisplayLayer)
//                启动系统 PiP（帧镜像 / frame mirror 方案）。
//    3) 【本轮新增：真实帧源接入】#366 第(7)点指出旧实现唯一的抓帧点是
//       swizzle AVSampleBufferDisplayLayer.enqueueSampleBuffer:，而本 App 内容播放
//       并不经过 AVSampleBufferDisplayLayer，故该 swizzle 对真实视频永不触发，
//       导出的 PipEnablerFeedPixelBuffer 也没有任何调用方 —— 镜像层拿不到真实帧，
//       系统 PiP 无法对实际视频起播。
//       本轮在【真实解码/渲染路径】上补两个通用抓帧点（纯 Objective-C 运行时，
//       无需 substrate / 无 C 符号 ABI 风险）：
//         (a) Flutter 外部纹理：App 用 Flutter 的 Texture widget 上屏
//             (SceneBuilder::addTexture / TEXTURE_VIEW)，Flutter 引擎每帧会对注册的
//             FlutterTexture 对象调用 -copyPixelBuffer 取回 CVPixelBuffer。
//             运行时遍历全部已注册类，把【自身实现 copyPixelBuffer 且返回类型为
//             CVBuffer/CVPixelBuffer】的类一并 swizzle，取回每帧像素缓冲。
//         (b) 原生渲染视图：部分渲染模式下像素缓冲直接交给原生视图
//             (FOKContentPixelBufferViewProtocol)。遍历全部类，把签名恰为
//             "v24@0:8^{__CVBuffer=}16"（返回 void、仅一个 CVBuffer 参数）的
//             消费型方法一并 swizzle。
//       两个抓帧点都调用导出的 PipEnablerFeedPixelBuffer()，从而让"镜像层"持续
//       拿到真实帧 → CMSampleBuffer → AVSampleBufferDisplayLayer，使
//       AVPictureInPictureControllerContentSource(sampleBufferDisplayLayer:) 在
//       iOS 16.6.1 上对【实际视频】可进入 pictureInPicturePossible 并起播。
//       同时保留原有 enqueueSampleBuffer: swizzle（对走 sample buffer 的
//       播放器仍然有效）作为第三重兜底。
//    4) 全部使用公开 API，不含任何私有符号；所有新 API 调用均以
//       respondsToSelector / @available 兜底，保证 iOS 15.0 ~ 16.6.1 可编译可运行。
//
//  导出符号严格与 PipEnabler.h 一致:
//    PipEnablerSetEnabled(BOOL) / PipEnablerIsEnabled() / PipEnablerToggle()
//    PipEnablerStartPictureInPicture() / PipEnablerStopPictureInPicture()
//    PipEnablerDetectedContentPlayerLayer()
//    PipEnablerEnabledDidChangeNotification (NSNotificationName)
//    PipEnablerFeedPixelBuffer(CVPixelBufferRef)
//
//  运行时开关 : NSUserDefaults key "PipEnablerEnabled" (BOOL)。
//              ★ 未显式设置时默认【开启】(见 PIP_ENABLER_DEFAULT_ENABLED)，
//                以保证注入后画中画对真实视频开箱即用。
//              修改后 post PipEnablerEnabledDidChangeNotification 通知。
//  自动装载   : __attribute__((constructor))，dylib 注入后立即生效。
//

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 常量与全局

/// 使能状态变化通知（名字必须与 PipEnabler.h 完全一致）
NSNotificationName const PipEnablerEnabledDidChangeNotification = @"PipEnablerEnabledDidChangeNotification";

/// NSUserDefaults 开关 key
static NSString * const kPipEnablerEnabledKey = @"PipEnablerEnabled";

/// 缺省使能状态：未显式写入 NSUserDefaults 时默认开启，
/// 否则注入 dylib 后帧镜像管线不会启动，画中画对真实视频依旧不可用。
static const BOOL PIP_ENABLER_DEFAULT_ENABLED = YES;

/// 镜像渲染用的小宿主视图尺寸（PiP 层需真正可见，挂到窗口上有助于部分 iOS 版本正确驱动渲染）
static const CGFloat kPipMirrorHostViewSize = 2.0;

/// 统一日志前缀
#define PIP_LOG(fmt, ...) NSLog(@"[PipEnabler] " fmt, ##__VA_ARGS__)

#pragma mark - 前向声明

/// 导出的主动喂帧入口（本文件内多个抓帧点都会调用它）
FOUNDATION_EXPORT void PipEnablerFeedPixelBuffer(CVPixelBufferRef pixelBuffer);

/// 抓帧所需的全局状态
static NSMutableSet<NSString *> *gSwizzledCopyPixelBufferClasses = nil;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalCopyPixelBufferIMPs = nil;
static NSMutableSet<NSString *> *gSwizzledCVBufferConsumerClasses = nil;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalCVBufferConsumerIMPs = nil;

/// 线程局部重入保护：同一帧经多级实现（子类 → 父类）转发时只喂一次。
static __thread int gPipFeedDepth = 0;

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
    // AVSampleBufferDisplayLayer 需要【有效的 PTS + duration】才能按时间轴推进渲染；
    // 若 duration 为 kCMTimeInvalid，部分 iOS 版本会判定样本不可渲染，
    // 导致 isPictureInPicturePossible 永远为 NO、PiP 无法起播。
    timing.duration              = CMTimeMake(1, 30);   // 按 30fps 估算
    timing.presentationTimeStamp = CMTIME_IS_VALID(pts) ? pts : CMTimeMake(0, 1);
    timing.decodeTimeStamp       = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      pixelBuffer,
                                                      formatDesc,
                                                      &timing,
                                                      &sampleBuffer);
    CFRelease(formatDesc);
    if (status != noErr || sampleBuffer == NULL) {
        return NULL;
    }
    // 帧镜像场景下必须"立即显示"：不依赖 controlTimebase 的节拍，
    // 否则在时间轴尚未推进时 display layer 会保留空画面，PiP 无法进入 possible。
    // 注意：DisplayImmediately 是【逐样本】attachment，必须写入样本 attachment 字典。
    CFArrayRef attachArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachArray != NULL && CFArrayGetCount(attachArray) > 0) {
        CFMutableDictionaryRef attachDict =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachArray, 0);
        CFDictionarySetValue(attachDict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        CFDictionarySetValue(attachDict, kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanFalse);
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

#pragma mark - 采样缓冲播放代理（iOS 15+ 的 sampleBufferDisplayLayer 路径必需）

// 说明：AVPictureInPictureControllerContentSource 没有单参数
// initWithSampleBufferDisplayLayer:，必须一并提供 playbackDelegate；
// 该代理由系统在 PiP 窗口里回调，实现全部 @required 方法即可。
API_AVAILABLE(ios(15.0))
@interface PipSampleBufferPlaybackDelegate : NSObject <AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, assign) BOOL playing;
@end

@implementation PipSampleBufferPlaybackDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _playing = YES;
    }
    return self;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                        setPlaying:(BOOL)playing {
    self.playing = playing;
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController {
    return !self.playing;
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController {
    // 帧镜像无固定时长，返回一个以当前时间起、足够长的区间。
    CMTime start = CMTimeMake((int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0), 1000);
    return CMTimeRangeMake(start, CMTimeMake(3600, 1));
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
              didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
    // 无需处理：渲染尺寸由系统按 layer 内容自动适配。
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                     skipByInterval:(CMTime)skipInterval
                  completionHandler:(void (^)(void))completionHandler {
    if (completionHandler) {
        completionHandler();
    }
}

@end

#pragma mark - PiP 管理器

@interface PipEnablerManager : NSObject

@property (nonatomic, assign) BOOL enabled;          // 使能开关
@property (nonatomic, assign) BOOL pipActive;        // 当前是否处于 PiP 中
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) AVSampleBufferDisplayLayer   *mirrorLayer;
@property (nonatomic, strong) UIView                       *mirrorHostView;
@property (nonatomic, weak)   AVPlayerLayer                *detectedPlayerLayer;
// 必须强引用：contentSource 的 playbackDelegate 为 weak。
@property (nonatomic, strong) id                            playbackDelegate;
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
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults objectForKey:kPipEnablerEnabledKey] == nil) {
            // 未显式配置 → 默认开启，保证注入即生效
            _enabled = PIP_ENABLER_DEFAULT_ENABLED;
        } else {
            _enabled = [defaults boolForKey:kPipEnablerEnabledKey];
        }
        PIP_LOG(@"manager init, enabled=%d", (int)_enabled);
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

        // ★ PiP 硬前提：AVSampleBufferDisplayLayer 必须真正处于 keyWindow 的
        //   视图层级内且【可见】（hidden=NO、alpha>0、位于屏幕内、bounds 非零）。
        //   之前用 hidden=YES + 负坐标(-2,-2) + 2x2 的宿主视图，会被系统视为
        //   不可渲染，isPictureInPicturePossible 恒为 NO —— 这是画中画无法真正
        //   触发的关键缺陷，现已修正为"屏内 2x2、非隐藏、底层"的宿主视图。
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.mirrorHostView == nil) {
                UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
                                                                        kPipMirrorHostViewSize,
                                                                        kPipMirrorHostViewSize)];
                host.backgroundColor = UIColor.clearColor;
                host.opaque = NO;
                host.alpha = 1.0;          // 必须 >0：alpha=0/hidden 会挂起图层渲染
                host.hidden = NO;          // 必须非隐藏
                host.clipsToBounds = NO;
                host.userInteractionEnabled = NO;
                self.mirrorLayer.frame = host.bounds;
                [host.layer addSublayer:self.mirrorLayer];
                UIWindow *keyWindow = nil;
                for (UIWindow *w in UIApplication.sharedApplication.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
                if (keyWindow == nil) {
                    keyWindow = UIApplication.sharedApplication.windows.firstObject;
                }
                if (keyWindow == nil) {
                    return;                // 无可挂载窗口，等下一次 refreshDetection 重试
                }
                [keyWindow addSubview:host];       // 置于屏内(0,0) 2x2，肉眼不可见但参与渲染
                [keyWindow bringSubviewToFront:host];
                self.mirrorHostView = host;
                PIP_LOG(@"mirror host view attached to keyWindow");
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
        SEL sbInit = @selector(initWithSampleBufferDisplayLayer:playbackDelegate:);
        if ([AVPictureInPictureControllerContentSource instancesRespondToSelector:sbInit]) {
            if (self.playbackDelegate == nil) {
                self.playbackDelegate = [[PipSampleBufferPlaybackDelegate alloc] init];
            }
            AVPictureInPictureControllerContentSource *src =
                [[AVPictureInPictureControllerContentSource alloc]
                    initWithSampleBufferDisplayLayer:self.mirrorLayer
                                    playbackDelegate:self.playbackDelegate];
            AVPictureInPictureController *controller =
                [[AVPictureInPictureController alloc] initWithContentSource:src];
            [self configureAutoStartForController:controller];
            self.pipController = controller;
            PIP_LOG(@"mirror PiP controller created (sampleBufferDisplayLayer content source)");
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
    // ★ 硬前提 2：只有 controller.isPictureInPicturePossible == YES 时，
    //   startPictureInPicture 才会真正生效。图层刚建立时该值通常还是 NO，
    //   直接调用必然失败；因此 KVO 监听它，一旦变 YES 立即起播。
    @try {
        [controller addObserver:self
                     forKeyPath:@"pictureInPicturePossible"
                        options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                        context:NULL];
    } @catch (NSException *e) {
        // 重复注册等异常忽略
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"pictureInPicturePossible"]) {
        if (self.enabled && self.pipController != nil &&
            self.pipController.isPictureInPicturePossible &&
            !self.pipController.isPictureInPictureActive) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PIP_LOG(@"pictureInPicturePossible=YES -> startPictureInPicture");
                [self.pipController startPictureInPicture];
            });
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)teardownPipeline {
    if (self.pipController != nil) {
        @try {
            [self.pipController removeObserver:self forKeyPath:@"pictureInPicturePossible"];
        } @catch (NSException *e) {
        }
    }
    self.pipController = nil;
    self.playbackDelegate = nil;
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
    if (layer.controlTimebase != NULL) {
        CMTimebaseSetRate(layer.controlTimebase, 1.0);
    }
    if (!self.pipActive && self.pipController != nil) {
        // 帧已开始流入，尝试自动拉起 PiP；若此刻仍不可用，KVO 会在
        // pictureInPicturePossible 变 YES 后补一次起播。
        self.pipActive = YES;
        if (!self.pipController.isPictureInPictureActive) {
            if ([NSThread isMainThread]) {
                [self.pipController startPictureInPicture];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.pipController startPictureInPicture];
                });
            }
        }
    }
}

@end

#pragma mark - 真实播放路径抓帧（Flutter 外部纹理 / 原生 CVBuffer 消费）

/// 从实例的真实类沿继承链向上，找到我们记录过的原始 IMP。
static IMP PipEnablerLookupOriginalIMP(id object, NSMutableDictionary<NSString *, NSValue *> *originals) {
    Class cls = object_getClass(object);
    while (cls != Nil) {
        NSValue *value = originals[NSStringFromClass(cls)];
        if (value != nil) {
            return (IMP)[value pointerValue];
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

/// 统一的 swizzle 安装器：只对【自己拥有该方法】的类安装一次。
static BOOL PipEnablerInstallSwizzle(Class cls,
                                     NSString *clsName,
                                     Method method,
                                     IMP replacement,
                                     NSMutableSet<NSString *> *done,
                                     NSMutableDictionary<NSString *, NSValue *> *originals) {
    if (cls == Nil || method == NULL || clsName.length == 0 || replacement == NULL) {
        return NO;
    }
    if (done == nil || originals == nil) {
        return NO;
    }
    IMP current = method_getImplementation(method);
    if (current == replacement || current == NULL) {
        return NO;
    }
    if ([done containsObject:clsName]) {
        return NO;
    }
    [done addObject:clsName];
    originals[clsName] = [NSValue valueWithPointer:current];
    method_setImplementation(method, replacement);
    return YES;
}

/// (a) FlutterTexture 的 -copyPixelBuffer：每帧被 Flutter 引擎调用取回 CVPixelBuffer。
static CVPixelBufferRef PipEnablerSwizzledCopyPixelBuffer(id self, SEL _cmd) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalCopyPixelBufferIMPs);
    if (original == NULL) {
        return NULL;
    }
    CVPixelBufferRef pixelBuffer = ((CVPixelBufferRef (*)(id, SEL))original)(self, _cmd);
    if (pixelBuffer != NULL && gPipFeedDepth == 0) {
        gPipFeedDepth++;
        @try {
            if ([[PipEnablerManager shared] isEnabled]) {
                // 经导出入口喂入镜像层
                PipEnablerFeedPixelBuffer(pixelBuffer);
            }
        } @finally {
            gPipFeedDepth--;
        }
    }
    return pixelBuffer;
}

/// (b) 原生渲染视图的 CVBuffer 消费型方法（返回 void、仅一个 CVBuffer 参数）。
static void PipEnablerSwizzledCVBufferConsumer(id self, SEL _cmd, CVBufferRef buffer) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalCVBufferConsumerIMPs);
    if (original != NULL) {
        ((void (*)(id, SEL, CVBufferRef))original)(self, _cmd, buffer);
    }
    if (buffer != NULL && gPipFeedDepth == 0) {
        gPipFeedDepth++;
        @try {
            if ([[PipEnablerManager shared] isEnabled]) {
                PipEnablerFeedPixelBuffer((CVPixelBufferRef)buffer);
            }
        } @finally {
            gPipFeedDepth--;
        }
    }
}

/// 遍历全部已注册类，安装真实路径抓帧 swizzle。
/// 说明：ObjC 类在镜像加载阶段（构造函数之前）即已注册，故此处一次遍历即可覆盖
///      Runner 主二进制 / App.framework / Flutter.framework 中定义的所有相关类。
static void PipEnablerInstallFrameCaptureHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gSwizzledCopyPixelBufferClasses = [NSMutableSet set];
        gOriginalCopyPixelBufferIMPs = [NSMutableDictionary dictionary];
        gSwizzledCVBufferConsumerClasses = [NSMutableSet set];
        gOriginalCVBufferConsumerIMPs = [NSMutableDictionary dictionary];

        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) {
            PIP_LOG(@"frame capture: no classes found");
            return;
        }
        Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
        if (classes == NULL) {
            return;
        }
        classCount = objc_getClassList(classes, classCount);

        int pipHooked = 0;
        int cbufferHooked = 0;
        for (int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            NSString *clsName = NSStringFromClass(cls);
            if (clsName.length == 0) {
                continue;
            }
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            if (methods == NULL) {
                continue;
            }
            for (unsigned int j = 0; j < methodCount; j++) {
                SEL sel = method_getName(methods[j]);
                const char *enc = method_getTypeEncoding(methods[j]);
                if (enc == NULL) {
                    continue;
                }
                if (sel == @selector(copyPixelBuffer) && strstr(enc, "CVBuffer") != NULL) {
                    if (PipEnablerInstallSwizzle(cls, clsName, methods[j],
                                                 (IMP)PipEnablerSwizzledCopyPixelBuffer,
                                                 gSwizzledCopyPixelBufferClasses,
                                                 gOriginalCopyPixelBufferIMPs)) {
                        pipHooked++;
                        PIP_LOG(@"(a) hooked -[%@ copyPixelBuffer]" , clsName);
                    }
                } else if (strcmp(enc, "v24@0:8^{__CVBuffer=}16") == 0 ||
                           strcmp(enc, "v24@0:8^{__CVPixelBuffer=}16") == 0) {
                    if (PipEnablerInstallSwizzle(cls, clsName, methods[j],
                                                 (IMP)PipEnablerSwizzledCVBufferConsumer,
                                                 gSwizzledCVBufferConsumerClasses,
                                                 gOriginalCVBufferConsumerIMPs)) {
                        cbufferHooked++;
                        PIP_LOG(@"(b) hooked -[%@ %@]", clsName, NSStringFromSelector(sel));
                    }
                }
            }
            free(methods);
        }
        free(classes);
        PIP_LOG(@"frame capture hooks installed: copyPixelBuffer=%d, cvBufferConsumer=%d",
                pipHooked, cbufferHooked);
    });
}

#pragma mark - 运行时插桩：为帧镜像补充通用抓帧点（第三重兜底）

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

/// 附加导出：供抓帧点 / 宿主 / 其它 tweak 主动喂帧（帧镜像路径使用）
void PipEnablerFeedPixelBuffer(CVPixelBufferRef pixelBuffer) {
    [[PipEnablerManager shared] feedPixelBuffer:pixelBuffer];
}

#pragma mark - 自动装载

__attribute__((constructor))
static void PipEnablerInitialize(void) {
    @autoreleasepool {
        // 第一重：sample buffer 播放器兜底
        PipEnablerInstallSwizzles();
        // 第二/三重：真实解码/渲染路径抓帧（Flutter 外部纹理 + 原生 CVBuffer 消费）
        PipEnablerInstallFrameCaptureHooks();

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
            PIP_LOG(@"boot complete, enabled=%d", (int)[manager isEnabled]);
        };

        if ([NSThread isMainThread]) {
            boot();
        } else {
            dispatch_async(dispatch_get_main_queue(), boot);
        }
    }
}
