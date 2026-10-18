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
//    3b) 【#373 新增：机理不同的兜底抓帧路径】#370 自认的残余风险是"两个钩子都是纯 ObjC
//       运行时 swizzle"。本轮再补一条【C 函数级 inline hook】（用 App 包内自带
//       libsubstrate.dylib 的 MSHookFunction），目标 CoreVideo 的
//       CVOpenGLESTextureCacheCreateTextureFromImage —— FFmpeg(VideoToolbox 硬解) 把解码出的
//       CVPixelBuffer 上传成 GL 纹理时必经此处，其 sourceImage 参数即真实帧。
//       同时新增三类 ObjC 读点：(c) 返回 CVPixelBuffer 的 getter（^{__CVBuffer=}16@0:8，
//       典型 -[FOKContentNativeController latestPixelBuffer]）；(d) 返回对象、入参一个
//       CVPixelBuffer 的工厂方法（@24@0:8^{__CVBuffer=}16）；(e) 输入输出均为 CVPixelBuffer
//       的变换方法（^{__CVBuffer=}24@0:8^{__CVBuffer=}16）。这些 selector / 返回类型均不在
//       #370 两个钩子的覆盖范围内。
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
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>
#import <objc/runtime.h>
#import <objc/message.h>
// 仅用于运行时 dlopen/dlsym 取得包内自带 libsubstrate.dylib 的 MSHookFunction
// （C 函数级 inline hook 需要它；本 dylib 不静态链接 substrate，避免额外依赖）。
#import <dlfcn.h>

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

/// 【本轮新增 #373】(c) FOKContentNativeController / FOKContentPixelBufferViewProtocol
/// 这类"读出点"：返回 CVPixelBuffer 的 getter，类型编码 ^{__CVBuffer=}16@0:8。
/// 它不在现有 -copyPixelBuffer 钩子的覆盖范围内（selector/返回类型都不同）。
static NSMutableSet<NSString *> *gSwizzledCVBufferGetterClasses = nil;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalCVBufferGetterIMPs = nil;

/// 【本轮新增 #373】(d) 返回对象、入参恰为一个 CVPixelBuffer 的工厂/初始化方法
/// （^@24@0:8^{__CVBuffer=}16），入参即解码后的帧。
static NSMutableSet<NSString *> *gSwizzledCVBufferFactoryClasses = nil;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalCVBufferFactoryIMPs = nil;

/// 【本轮新增 #373】(e) 返回 CVPixelBuffer、入参恰为一个 CVPixelBuffer 的变换方法
/// （^{__CVBuffer=}24@0:8^{__CVBuffer=}16）。
static NSMutableSet<NSString *> *gSwizzledCVBufferTransformClasses = nil;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalCVBufferTransformIMPs = nil;

/// 【本轮新增 #378】(f) ijkplayer 衍生引擎 fok_media_core 的 FOKOverlay 消费方法，
/// 类型编码 v24@0:8^{FOKOverlay=iiIi^S^*ii^{__CVBuffer}}16。FOKOverlay 是 ijkplayer
/// SDL_VoutOverlay 的 fok 变体，其结构体内【内嵌 VideoToolbox 硬解出的真实 CVPixelBuffer】。
static NSMutableSet<NSString *> *gSwizzledFOKOverlayClasses = nil;
static NSMutableDictionary<NSString *, NSValue *> *gOriginalFOKOverlayIMPs = nil;

/// 线程局部重入保护：同一帧经多级实现（子类 → 父类）转发时只喂一次。
static __thread int gPipFeedDepth = 0;

/// ★【#377 运行期缺陷修复】feedSampleBuffer: 的线程局部重入保护。
/// 原因：feedSampleBuffer: 内部会对 mirrorLayer 调用 -enqueueSampleBuffer:，
/// 而本模块的【第三重兜底】恰恰 swizzle 了 AVSampleBufferDisplayLayer 的
/// -enqueueSampleBuffer:（见 PipEnablerInstallSwizzles），该 swizzle 命中后又会
/// 回调 feedSampleBuffer: —— 若不加保护即形成
///   feedSampleBuffer: → -enqueueSampleBuffer: → feedSampleBuffer: → ...
/// 的【无限递归】，运行期在栈上自噬，首帧喂入即 SIGSEGV 崩溃（纯静态
/// nm/otool/strings 分析无法发现，仅运行期复现，见 #377 模拟器自测）。
static __thread int gPipFeedSampleDepth = 0;

/// 把一帧 CVPixelBuffer 交给镜像管线（带线程局部重入保护，防止多级转发重复喂帧）。
#define PIP_ENABLER_FEED_PIXELBUFFER(pb)                                          \
    do {                                                                          \
        CVPixelBufferRef _pipPB = (CVPixelBufferRef)(pb);                         \
        if (_pipPB != NULL && gPipFeedDepth == 0) {                               \
            gPipFeedDepth++;                                                      \
            @try {                                                                \
                if ([[PipEnablerManager shared] isEnabled]) {                     \
                    PipEnablerFeedPixelBuffer(_pipPB);                            \
                }                                                                 \
            } @finally {                                                          \
                gPipFeedDepth--;                                                  \
            }                                                                     \
        }                                                                         \
    } while (0)

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
    // ★【#377 运行期缺陷修复：打断 enqueueSampleBuffer: swizzle 造成的无限递归】
    //   本方法的正常调用方是 feedPixelBuffer:（帧镜像入口）。但第三重兜底
    //   swizzle 了 AVSampleBufferDisplayLayer 的 -enqueueSampleBuffer:，因此本方法
    //   内部对 mirrorLayer 的那次 enqueue 会被 swizzle 命中并【再回调本方法】，
    //   形成无限递归（首帧即 SIGSEGV）。这里用线程局部标志打断递归：
    //   递归层（depth>0）直接返回，最外层（depth==0）执行真正的入队与起播逻辑。
    if (gPipFeedSampleDepth > 0) {
        return;
    }
    gPipFeedSampleDepth++;
    @try {
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
    } @finally {
        gPipFeedSampleDepth--;
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

/// (c) 返回 CVPixelBuffer 的 getter（^{__CVBuffer=}16@0:8）。
/// 典型：FOKContentNativeController 的 -latestPixelBuffer（"读出点"，与 -copyPixelBuffer
/// 的 selector / 返回类型都不同，故原有两个钩子均未覆盖）。
static CVPixelBufferRef PipEnablerSwizzledCVBufferGetter(id self, SEL _cmd) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalCVBufferGetterIMPs);
    if (original == NULL) {
        return NULL;
    }
    CVPixelBufferRef pb = ((CVPixelBufferRef (*)(id, SEL))original)(self, _cmd);
    PIP_ENABLER_FEED_PIXELBUFFER(pb);
    return pb;
}

/// (d) 返回对象、入参恰为一个 CVPixelBuffer 的工厂/初始化方法（@24@0:8^{__CVBuffer=}16）。
/// 入参即解码后的帧；先喂帧再调用原实现。
static id PipEnablerSwizzledCVBufferFactory(id self, SEL _cmd, CVPixelBufferRef buffer) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalCVBufferFactoryIMPs);
    PIP_ENABLER_FEED_PIXELBUFFER(buffer);
    if (original != NULL) {
        return ((id (*)(id, SEL, CVPixelBufferRef))original)(self, _cmd, buffer);
    }
    return nil;
}

/// (e) 返回 CVPixelBuffer、入参恰为一个 CVPixelBuffer 的变换方法
/// （^{__CVBuffer=}24@0:8^{__CVBuffer=}16）；入参与返回值都可能是真实帧。
static CVPixelBufferRef PipEnablerSwizzledCVBufferTransform(id self, SEL _cmd, CVPixelBufferRef buffer) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalCVBufferTransformIMPs);
    PIP_ENABLER_FEED_PIXELBUFFER(buffer);
    if (original != NULL) {
        CVPixelBufferRef out = ((CVPixelBufferRef (*)(id, SEL, CVPixelBufferRef))original)(self, _cmd, buffer);
        PIP_ENABLER_FEED_PIXELBUFFER(out);
        return out;
    }
    return buffer;
}

/// (f) 【#378 新增】fok_media_core 的 FOKOverlay 消费方法
/// 类型编码 v24@0:8^{FOKOverlay=iiIi^S^*ii^{__CVBuffer}}16。
/// FOKOverlay 是 ijkplayer SDL_VoutOverlay 的 fok 变体。按 arm64 ABI 依类型编码
/// `i i I i ^S ^* i i ^{__CVBuffer}` 依次还原其【字段偏移】：
///   +0  int             w
///   +4  int             h
///   +8  Uint32          format
///   +12 int             planes
///   +16 Uint16 *        pitches       （指针 8 字节对齐）
///   +24 void *          pixels / 载荷
///   +32 int             is_private
///   +36 int             sar_num
///   +40 CVPixelBufferRef pixelBuffer ←【内嵌的真实解码帧】VideoToolbox 硬解输出
/// 结构体总大小 = 48 字节；CVPixelBuffer 指针位于偏移 +40。
/// 该方法是"消费点"（返回 void、仅一个 FOKOverlay* 入参）——生产侧把解码帧塞进
/// overlay 后交给渲染/上屏，此处读 +40 即拿到真实帧再喂镜像层。
static void PipEnablerSwizzledFOKOverlayConsumer(id self, SEL _cmd, const void *overlayPtr) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalFOKOverlayIMPs);
    // 先于原实现读取内嵌 CVPixelBuffer（原实现可能修改/释放 overlay 内容）。
    if (overlayPtr != NULL && gPipFeedDepth == 0) {
        CVPixelBufferRef pb = NULL;
        // 对齐读（offset 40 为 8 字节对齐），避免非对齐访问。
        memcpy(&pb, (const uint8_t *)overlayPtr + 40, sizeof(pb));
        // 校验确实是 CVPixelBuffer，防止结构体该位尚未填充/为脏数据时崩溃。
        if (pb != NULL && CFGetTypeID(pb) == CVPixelBufferGetTypeID()) {
            PIP_ENABLER_FEED_PIXELBUFFER(pb);
        }
    }
    if (original != NULL) {
        ((void (*)(id, SEL, const void *))original)(self, _cmd, overlayPtr);
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
        gSwizzledCVBufferGetterClasses = [NSMutableSet set];
        gOriginalCVBufferGetterIMPs = [NSMutableDictionary dictionary];
        gSwizzledCVBufferFactoryClasses = [NSMutableSet set];
        gOriginalCVBufferFactoryIMPs = [NSMutableDictionary dictionary];
        gSwizzledCVBufferTransformClasses = [NSMutableSet set];
        gOriginalCVBufferTransformIMPs = [NSMutableDictionary dictionary];
        gSwizzledFOKOverlayClasses = [NSMutableSet set];
        gOriginalFOKOverlayIMPs = [NSMutableDictionary dictionary];

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
        int getterHooked = 0;
        int factoryHooked = 0;
        int transformHooked = 0;
        int fokOverlayHooked = 0;
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
                } else if (strcmp(enc, "^{__CVBuffer=}16@0:8") == 0 ||
                           strcmp(enc, "^{__CVPixelBuffer=}16@0:8") == 0) {
                    // (c) 返回 CVPixelBuffer 的 getter 读点（如 -latestPixelBuffer）
                    if (PipEnablerInstallSwizzle(cls, clsName, methods[j],
                                                 (IMP)PipEnablerSwizzledCVBufferGetter,
                                                 gSwizzledCVBufferGetterClasses,
                                                 gOriginalCVBufferGetterIMPs)) {
                        getterHooked++;
                        PIP_LOG(@"(c) hooked getter -[%@ %@] type=^{__CVBuffer=}16@0:8",
                                clsName, NSStringFromSelector(sel));
                    }
                } else if (strcmp(enc, "@24@0:8^{__CVBuffer=}16") == 0 ||
                           strcmp(enc, "@24@0:8^{__CVPixelBuffer=}16") == 0) {
                    // (d) 返回对象、入参一个 CVPixelBuffer 的工厂方法
                    if (PipEnablerInstallSwizzle(cls, clsName, methods[j],
                                                 (IMP)PipEnablerSwizzledCVBufferFactory,
                                                 gSwizzledCVBufferFactoryClasses,
                                                 gOriginalCVBufferFactoryIMPs)) {
                        factoryHooked++;
                        PIP_LOG(@"(d) hooked factory -[%@ %@] type=@24@0:8^{__CVBuffer=}16",
                                clsName, NSStringFromSelector(sel));
                    }
                } else if (strcmp(enc, "^{__CVBuffer=}24@0:8^{__CVBuffer=}16") == 0 ||
                           strcmp(enc, "^{__CVPixelBuffer=}24@0:8^{__CVPixelBuffer=}16") == 0) {
                    // (e) 返回 CVPixelBuffer、入参一个 CVPixelBuffer 的变换方法
                    if (PipEnablerInstallSwizzle(cls, clsName, methods[j],
                                                 (IMP)PipEnablerSwizzledCVBufferTransform,
                                                 gSwizzledCVBufferTransformClasses,
                                                 gOriginalCVBufferTransformIMPs)) {
                        transformHooked++;
                        PIP_LOG(@"(e) hooked transform -[%@ %@] type=^{__CVBuffer=}24@0:8^{__CVBuffer=}16",
                                clsName, NSStringFromSelector(sel));
                    }
                } else if (strcmp(enc, "v24@0:8^{FOKOverlay=iiIi^S^*ii^{__CVBuffer}}16") == 0) {
                    // (f) 【#378】fok_media_core 的 FOKOverlay 消费方法：overlay 内嵌 CVPixelBuffer
                    //     （结构体偏移 +40，见 PipEnablerSwizzledFOKOverlayConsumer 处注释）
                    if (PipEnablerInstallSwizzle(cls, clsName, methods[j],
                                                 (IMP)PipEnablerSwizzledFOKOverlayConsumer,
                                                 gSwizzledFOKOverlayClasses,
                                                 gOriginalFOKOverlayIMPs)) {
                        fokOverlayHooked++;
                        PIP_LOG(@"(f) hooked FOKOverlay consumer -[%@ %@] type=v24@0:8^{FOKOverlay=...}16",
                                clsName, NSStringFromSelector(sel));
                    }
                }
            }
            free(methods);
        }
        free(classes);
        PIP_LOG(@"frame capture hooks installed: copyPixelBuffer=%d, cvBufferConsumer=%d, getter=%d, factory=%d, transform=%d, fokOverlay=%d",
                pipHooked, cbufferHooked, getterHooked, factoryHooked, transformHooked, fokOverlayHooked);
    });
}

#pragma mark - C 函数级抓帧（#373：机理不同于上述 ObjC swizzle 的兜底路径）

// 说明：
//   上述 (a)~(e) 都是 Objective-C 运行时 swizzle。本段补一条【机理不同】的抓帧路径 ——
//   直接用 libsubstrate 的 MSHookFunction 对 C 函数做 inline hook。
//
//   抓帧点选择：FFmpeg(VideoToolbox 硬解) 解码出的 CVPixelBuffer，在 fok_media_core 里
//   经 OpenGL ES2 上传为纹理时，会调用 CoreVideo 的
//       CVReturn CVOpenGLESTextureCacheCreateTextureFromImage(
//           CFAllocatorRef allocator, CVOpenGLESTextureCacheRef textureCache,
//           CVImageBufferRef sourceImage, CFDictionaryRef textureAttributes,
//           GLenum target, GLint internalFormat, GLsizei width, GLsizei height,
//           GLenum format, GLenum type, size_t planeIndex,
//           GLfloat planeWidth, GLfloat planeHeight, CVOpenGLESTextureRef *textureOut);
//   其第 3 个参数 sourceImage 就是【解码后的真实 CVPixelBuffer】—— 这正是
//   "CVOpenGLESTextureCache 回读" 抓帧点（见二进制内 _CVOpenGLESTextureCacheCreateTextureFromImage
//   的导入与 "Error at CVOpenGLESTextureCacheCreate %d" / "[GLES2] after %s() glError" 等痕迹）。
//   planeIndex==0 时抓一次即可（NV12 的第 1 个 plane 调用即完整帧）。

/// MSHookFunction 原型（现代 libsubstrate/CydiaSubstrate：void MSHookFunction(void *symbol, void *hook, void **old)）
typedef void (*PipMSHookFunctionFn)(void *symbol, void *hook, void **old);
static PipMSHookFunctionFn gPipMSHookFunction = NULL;

/// CVOpenGLESTextureCacheCreateTextureFromImage 的函数指针（原实现 / 钩子）
typedef CVReturn (*PipCVTextureFromImageFn)(CFAllocatorRef allocator, CFTypeRef textureCache,
                                            CVImageBufferRef sourceImage, CFDictionaryRef textureAttributes,
                                            uint32_t target, int32_t internalFormat, int32_t width, int32_t height,
                                            uint32_t format, uint32_t type, size_t planeIndex,
                                            float planeWidth, float planeHeight, CFTypeRef *textureOut);
static PipCVTextureFromImageFn gPipOrigCVTextureFromImage = NULL;

static CVReturn PipEnablerHookedCVTextureFromImage(CFAllocatorRef allocator, CFTypeRef textureCache,
                                                   CVImageBufferRef sourceImage, CFDictionaryRef textureAttributes,
                                                   uint32_t target, int32_t internalFormat, int32_t width, int32_t height,
                                                   uint32_t format, uint32_t type, size_t planeIndex,
                                                   float planeWidth, float planeHeight, CFTypeRef *textureOut) {
    if (planeIndex == 0 && sourceImage != NULL) {
        // 该 C 函数不是 Objective-C 方法，不能用 gPipFeedDepth 的 @try/@finally 语义，
        // 但重入保护同样有效（喂帧过程内部若再次调用本函数会因 depth>0 直接跳过）。
        PIP_ENABLER_FEED_PIXELBUFFER((CVPixelBufferRef)sourceImage);
    }
    if (gPipOrigCVTextureFromImage != NULL) {
        return gPipOrigCVTextureFromImage(allocator, textureCache, sourceImage, textureAttributes,
                                          target, internalFormat, width, height, format, type, planeIndex,
                                          planeWidth, planeHeight, textureOut);
    }
    return -6661; // kCVReturnError(≈-6660) 邻域；仅当钩子安装后原指针异常时才走到这里
}

/// 运行时载入包内 libsubstrate.dylib 并取得 MSHookFunction，然后对目标 C 函数安装 inline hook。
/// 若 substrate 或目标符号不可用，则安全跳过（不影响 ObjC 抓帧路径），并打日志说明。
static void PipEnablerInstallCVTextureHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1) 取 MSHookFunction：优先复用 App 已加载的 substrate（KAlert.dylib 使用 MSHookMessageEx，
        //    Runner 的 LC_LOAD_DYLIB 也含 @executable_path/Frameworks/libsubstrate.dylib）。
        void *handle = dlopen("libsubstrate.dylib", RTLD_NOW | RTLD_NOLOAD);
        if (handle == NULL) {
            handle = dlopen("libsubstrate.dylib", RTLD_NOW);
        }
        if (handle == NULL) {
            NSString *bundlePath = [NSBundle mainBundle].bundlePath;
            if (bundlePath.length > 0) {
                NSString *p = [bundlePath stringByAppendingPathComponent:@"Frameworks/libsubstrate.dylib"];
                handle = dlopen(p.fileSystemRepresentation, RTLD_NOW);
            }
        }
        if (handle != NULL) {
            gPipMSHookFunction = (PipMSHookFunctionFn)dlsym(handle, "MSHookFunction");
        }
        if (gPipMSHookFunction == NULL) {
            gPipMSHookFunction = (PipMSHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
        }
        if (gPipMSHookFunction == NULL) {
            PIP_LOG(@"[cv-hook] MSHookFunction unavailable -> skip C-function hook (CVOpenGLESTextureCacheCreateTextureFromImage)");
            return;
        }

        // 2) 定位 CoreVideo 的 CVOpenGLESTextureCacheCreateTextureFromImage
        void *sym = dlsym(RTLD_DEFAULT, "CVOpenGLESTextureCacheCreateTextureFromImage");
        if (sym == NULL) {
            sym = dlsym(RTLD_DEFAULT, "_CVOpenGLESTextureCacheCreateTextureFromImage");
        }
        if (sym == NULL) {
            PIP_LOG(@"[cv-hook] CVOpenGLESTextureCacheCreateTextureFromImage not found -> skip");
            return;
        }

        // 3) 安装 inline hook（原实现经 trampoline 保存到 gPipOrigCVTextureFromImage）
        gPipMSHookFunction(sym, (void *)PipEnablerHookedCVTextureFromImage, (void **)&gPipOrigCVTextureFromImage);
        PIP_LOG(@"[cv-hook] C-function hook installed: CVOpenGLESTextureCacheCreateTextureFromImage=%p orig=%p",
                sym, gPipOrigCVTextureFromImage);
    });
}

#pragma mark - C 函数级补充抓帧 #378：CVPixelBuffer 系（GetBaseAddressOfPlane / LockBaseAddress / PoolCreatePixelBuffer）

// 说明：与 #373 的 CVOpenGLESTextureCacheCreateTextureFromImage 并列，再补三条
//   主二进制【导入】的 CoreVideo 函数作为 C 级抓帧点（经 libsubstrate MSHookFunction）：
//     · CVPixelBufferGetBaseAddressOfPlane(pb, planeIndex)  —— 取平面基址前，pb 即真实帧
//     · CVPixelBufferLockBaseAddress(pb, flags)             —— CPU 访问前，pb 即真实帧
//     · CVPixelBufferPoolCreatePixelBuffer(alloc, pool, out) —— 输出参数 *out 为新帧
//   统一经 PIP_ENABLER_FEED_PIXELBUFFER() 喂入镜像层。
//   ⚠ 这些函数可能被高频调用，这里加一个 ~8ms 的轻量节流（≈125fps 上限，远高于视频帧率，
//     不会丢真实帧），避免向 AVSampleBufferDisplayLayer 灌入重复样本。

typedef void *(*PipCVPBGetBaseAddressOfPlaneFn)(CVPixelBufferRef pixelBuffer, size_t planeIndex);
typedef CVReturn (*PipCVPBLockBaseAddressFn)(CVPixelBufferRef pixelBuffer, CVPixelBufferLockFlags flags);
typedef CVReturn (*PipCVPBPoolCreatePixelBufferFn)(CFAllocatorRef allocator,
                                                   CVPixelBufferPoolRef pixelBufferPool,
                                                   CVPixelBufferRef *pixelBufferOut);

static PipCVPBGetBaseAddressOfPlaneFn gPipOrigCVPBGetBaseAddressOfPlane = NULL;
static PipCVPBLockBaseAddressFn       gPipOrigCVPBLockBaseAddress = NULL;
static PipCVPBPoolCreatePixelBufferFn gPipOrigCVPBPoolCreatePixelBuffer = NULL;

/// 轻量节流：两次喂帧间隔 <8ms 时跳过（多线程下的 benign 竞争可接受）。
static CFTimeInterval gPipCBFeedLastTime = 0;

static BOOL PipEnablerCBFeedAllowed(void) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gPipCBFeedLastTime < 0.008) {
        return NO;
    }
    gPipCBFeedLastTime = now;
    return YES;
}

static void *PipEnablerHookedCVPBGetBaseAddressOfPlane(CVPixelBufferRef pixelBuffer, size_t planeIndex) {
    if (pixelBuffer != NULL && planeIndex == 0 && PipEnablerCBFeedAllowed()) {
        PIP_ENABLER_FEED_PIXELBUFFER(pixelBuffer);
    }
    if (gPipOrigCVPBGetBaseAddressOfPlane != NULL) {
        return gPipOrigCVPBGetBaseAddressOfPlane(pixelBuffer, planeIndex);
    }
    return NULL;
}

static CVReturn PipEnablerHookedCVPBLockBaseAddress(CVPixelBufferRef pixelBuffer, CVPixelBufferLockFlags flags) {
    CVReturn ret = kCVReturnSuccess;
    if (gPipOrigCVPBLockBaseAddress != NULL) {
        ret = gPipOrigCVPBLockBaseAddress(pixelBuffer, flags);
    }
    if (pixelBuffer != NULL && PipEnablerCBFeedAllowed()) {
        PIP_ENABLER_FEED_PIXELBUFFER(pixelBuffer);
    }
    return ret;
}

static CVReturn PipEnablerHookedCVPBPoolCreatePixelBuffer(CFAllocatorRef allocator,
                                                          CVPixelBufferPoolRef pixelBufferPool,
                                                          CVPixelBufferRef *pixelBufferOut) {
    CVReturn ret = kCVReturnError;
    if (gPipOrigCVPBPoolCreatePixelBuffer != NULL) {
        ret = gPipOrigCVPBPoolCreatePixelBuffer(allocator, pixelBufferPool, pixelBufferOut);
    }
    if (ret == kCVReturnSuccess && pixelBufferOut != NULL && *pixelBufferOut != NULL) {
        CVPixelBufferRef pb = *pixelBufferOut;
        // 仅当该 buffer 已有有效尺寸时才喂（池刚建出的空 buffer 尺寸已定，但尚无像素；
        // 这里只做类型/非空校验，真实像素由后续 LockBaseAddress/GetBaseAddressOfPlane 覆盖）。
        if (CFGetTypeID(pb) == CVPixelBufferGetTypeID() && PipEnablerCBFeedAllowed()) {
            PIP_ENABLER_FEED_PIXELBUFFER(pb);
        }
    }
    return ret;
}

/// 载入包内 libsubstrate.dylib 并取得 MSHookFunction（若 #373 已装 CVTexture hook 则复用其句柄）。
static PipMSHookFunctionFn PipEnablerResolveMSHookFunction(void) {
    if (gPipMSHookFunction != NULL) {
        return gPipMSHookFunction;
    }
    void *handle = dlopen("libsubstrate.dylib", RTLD_NOW | RTLD_NOLOAD);
    if (handle == NULL) {
        handle = dlopen("libsubstrate.dylib", RTLD_NOW);
    }
    if (handle == NULL) {
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        if (bundlePath.length > 0) {
            NSString *p = [bundlePath stringByAppendingPathComponent:@"Frameworks/libsubstrate.dylib"];
            handle = dlopen(p.fileSystemRepresentation, RTLD_NOW);
        }
    }
    PipMSHookFunctionFn fn = NULL;
    if (handle != NULL) {
        fn = (PipMSHookFunctionFn)dlsym(handle, "MSHookFunction");
    }
    if (fn == NULL) {
        fn = (PipMSHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    }
    gPipMSHookFunction = fn;
    return fn;
}

/// 对三条 CVPixelBuffer 系 C 函数安装 inline hook；substrate/符号不可用时安全跳过。
static void PipEnablerInstallCVPixelBufferHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PipMSHookFunctionFn hookFn = PipEnablerResolveMSHookFunction();
        if (hookFn == NULL) {
            PIP_LOG(@"[cvpb-hook] MSHookFunction unavailable -> skip CVPixelBuffer C-function hooks");
            return;
        }

        struct { const char *name; void *hook; void **orig; } targets[] = {
            { "CVPixelBufferGetBaseAddressOfPlane",
              (void *)PipEnablerHookedCVPBGetBaseAddressOfPlane,
              (void **)&gPipOrigCVPBGetBaseAddressOfPlane },
            { "CVPixelBufferLockBaseAddress",
              (void *)PipEnablerHookedCVPBLockBaseAddress,
              (void **)&gPipOrigCVPBLockBaseAddress },
            { "CVPixelBufferPoolCreatePixelBuffer",
              (void *)PipEnablerHookedCVPBPoolCreatePixelBuffer,
              (void **)&gPipOrigCVPBPoolCreatePixelBuffer },
        };

        for (size_t i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
            void *sym = dlsym(RTLD_DEFAULT, targets[i].name);
            if (sym == NULL) {
                PIP_LOG(@"[cvpb-hook] %s not found -> skip", targets[i].name);
                continue;
            }
            hookFn(sym, targets[i].hook, targets[i].orig);
            PIP_LOG(@"[cvpb-hook] installed %s=%p orig=%p", targets[i].name, sym, *targets[i].orig);
        }
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
        // 第二重：真实解码/渲染路径抓帧（ObjC swizzle：Flutter 外部纹理 + CVBuffer 消费/getter/工厂/变换）
        PipEnablerInstallFrameCaptureHooks();
        // 第三重（机理不同）：C 函数级 inline hook —— CVOpenGLESTextureCacheCreateTextureFromImage
        PipEnablerInstallCVTextureHook();
        // 第三重补充（#378）：CVPixelBuffer 系 C 函数级 inline hook
        PipEnablerInstallCVPixelBufferHooks();

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
