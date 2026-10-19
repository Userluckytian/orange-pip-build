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
// [P1] Default OFF: user asked for a manual on/off button, no auto-PiP.
static const BOOL PIP_ENABLER_DEFAULT_ENABLED = NO;

/// 镜像渲染用的小宿主视图尺寸（PiP 层需真正可见，挂到窗口上有助于部分 iOS 版本正确驱动渲染）
static const CGFloat kPipMirrorHostViewSize = 2.0;

/// 统一日志前缀
#define PIP_LOG(fmt, ...) NSLog(@"[PipEnabler] " fmt, ##__VA_ARGS__)

#pragma mark - 持久化诊断日志（真机无日志环境下的可观测性埋点）

/// 诊断日志落到 App 沙盒 Documents/PipEnabler.diag.log。
/// 目的：真机无法连机取 NSLog 时，仍可导出该文件定位「抓帧是否命中 /
/// PiP 是否 possible / 是否起播」等关键节点，避免黑屏只能靠猜。
/// 同一行经 NSNotification(PipEnablerDiagLogNotification) 广播，便于实时订阅。
static NSString * const kPipEnablerDiagLogNotification = @"PipEnablerDiagLogNotification";

static void PipEnablerDiagLog(NSString *format, ...) {
    static dispatch_once_t onceToken;
    static NSDateFormatter *fmt = nil;
    static NSString *logPath = nil;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSArray<NSString *> *dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.count > 0 ? dirs.firstObject : NSTemporaryDirectory();
        logPath = [docs stringByAppendingPathComponent:@"PipEnabler.diag.log"];
    });

    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ [PipEnabler.diag] %@\n",
                      [fmt stringFromDate:[NSDate date]], msg];
    NSLog(@"[PipEnabler.diag] %@", msg);

    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fh == nil) {
            [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        // 落盘失败不应影响主流程
    }

    @try {
        [NSNotificationCenter.defaultCenter postNotificationName:kPipEnablerDiagLogNotification
                                                          object:nil
                                                        userInfo:@{@"line": line}];
    } @catch (NSException *e) {
    }
}

#pragma mark - 音频会话（PiP 前置条件）

// Configure AVAudioSession as .playback + .moviePlayback.
// Community implementations (PiPBugDemo) mark this as "required to support Picture in Picture".
// The previous implementation never configured an audio session at all.
static void PipEnablerConfigureAudioSession(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // [P2] Do the work off the caller thread: audio setup must never be able to
        // abort/crash the enable path that calls this.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            AVAudioSession *session = AVAudioSession.sharedInstance;
            NSError *err = nil;
            if (![session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeMoviePlayback
                         options:0
                           error:&err]) {
                PipEnablerDiagLog(@"AVAudioSession setCategory failed: %@", err.localizedDescription);
            } else {
                [session setActive:YES error:NULL];
                PipEnablerDiagLog(@"AVAudioSession configured: playback/moviePlayback");
            }
        } @catch (NSException *e) {
            PipEnablerDiagLog(@"AVAudioSession config exception: %@", e.name);
        }
        });
    });
}

#pragma mark - 亮度探针（判断抓到的帧本身是否全黑）

/// 平均亮度 0..1：区分「抓到的帧本身就是黑的」与「帧有内容但 PiP 显示不出来」。
static double PipEnablerAverageLuma(CVPixelBufferRef pb) {
    if (pb == NULL) { return -1.0; }
    if (CVPixelBufferGetWidth(pb) == 0 || CVPixelBufferGetHeight(pb) == 0) { return -1.0; }
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return -1.0;
    }
    double sum = 0.0;
    NSUInteger n = 0;
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    if (base != NULL) {
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t pw = CVPixelBufferGetWidthOfPlane(pb, 0);
        size_t ph = CVPixelBufferGetHeightOfPlane(pb, 0);
        size_t stepY = (ph / 8 > 0) ? ph / 8 : 1;
        size_t stepX = (pw / 8 > 0) ? pw / 8 : 1;
        for (size_t y = 0; y < ph; y += stepY) {
            for (size_t x = 0; x < pw; x += stepX) {
                sum += (double)base[y * bpr + x];
                n++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (n == 0) { return -1.0; }
    return sum / (double)n / 255.0;
}

#pragma mark - 抓帧来源统计（v6：定位黑帧来源）

/// 当前喂帧来源标记，由各个 hook 在喂帧前设置
static const char *gPipFeedSourceTag = "other";

typedef struct {
    const char *name;
    CFTimeInterval lastFeed;
    NSUInteger total;
    NSUInteger black;
    double lastMaxY;
} PipFeedSourceStat;

static PipFeedSourceStat gPipFeedSourceStats[10];
static int gPipFeedSourceStatCount = 0;

static PipFeedSourceStat *PipEnablerFeedSourceStat(const char *name) {
    for (int i = 0; i < gPipFeedSourceStatCount; i++) {
        if (strcmp(gPipFeedSourceStats[i].name, name) == 0) {
            return &gPipFeedSourceStats[i];
        }
    }
    if (gPipFeedSourceStatCount < 10) {
        PipFeedSourceStat *s = &gPipFeedSourceStats[gPipFeedSourceStatCount++];
        s->name = name;
        s->lastFeed = 0;
        s->total = 0;
        s->black = 0;
        s->lastMaxY = -1;
        return s;
    }
    return NULL;
}

/// 逐来源的亮度统计：min / max / avg（Y 平面）。max 接近 16 即为纯黑帧。
static BOOL PipEnablerLumaStats(CVPixelBufferRef pb, double *outMin, double *outMax, double *outAvg) {
    if (pb == NULL) { return NO; }
    if (CVPixelBufferGetWidth(pb) == 0 || CVPixelBufferGetHeight(pb) == 0) { return NO; }
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NO;
    }
    double mn = 255.0, mx = 0.0, sum = 0.0;
    NSUInteger n = 0;
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    if (base != NULL) {
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t pw = CVPixelBufferGetWidthOfPlane(pb, 0);
        size_t ph = CVPixelBufferGetHeightOfPlane(pb, 0);
        size_t stepY = (ph / 12 > 0) ? ph / 12 : 1;
        size_t stepX = (pw / 12 > 0) ? pw / 12 : 1;
        for (size_t y = 0; y < ph; y += stepY) {
            for (size_t x = 0; x < pw; x += stepX) {
                double v = (double)base[y * bpr + x];
                if (v < mn) { mn = v; }
                if (v > mx) { mx = v; }
                sum += v;
                n++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (n == 0) { return NO; }
    if (outMin) { *outMin = mn; }
    if (outMax) { *outMax = mx; }
    if (outAvg) { *outAvg = sum / (double)n; }
    return YES;
}

/// 各来源统计摘要（给诊断浮层用）
static NSString *PipEnablerFeedSourceSummary(void) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < gPipFeedSourceStatCount; i++) {
        PipFeedSourceStat *st = &gPipFeedSourceStats[i];
        [s appendFormat:@"%s: fed=%lu black=%lu maxY=%.0f\n",
            st->name, (unsigned long)st->total, (unsigned long)st->black, st->lastMaxY];
    }
    if (gPipFeedSourceStatCount == 0) { [s appendString:@"\n(no capture source fired)\n"]; }
    return s;
}

/// 亮度统计（BGRA 缓冲）：用 G 通道近似亮度。
static BOOL PipEnablerLumaStatsBGRA(CVPixelBufferRef pb, double *outMin, double *outMax, double *outAvg) {
    if (pb == NULL) { return NO; }
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NO;
    }
    double mn = 255.0, mx = 0.0, sum = 0.0;
    NSUInteger n = 0;
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (base != NULL && w > 0 && h > 0) {
        size_t stepY = (h / 12 > 0) ? h / 12 : 1;
        size_t stepX = (w / 12 > 0) ? w / 12 : 1;
        for (size_t y = 0; y < h; y += stepY) {
            const uint8_t *row = base + y * bpr;
            for (size_t x = 0; x < w; x += stepX) {
                double v = (double)row[x * 4 + 1];   // G channel
                if (v < mn) { mn = v; }
                if (v > mx) { mx = v; }
                sum += v;
                n++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (n == 0) { return NO; }
    if (outMin) { *outMin = mn; }
    if (outMax) { *outMax = mx; }
    if (outAvg) { *outAvg = sum / (double)n; }
    return YES;
}

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
// [P4] Forward declaration + a small category so the delegate can resize the
// manager mirror layer (a bare @class cannot see the property).
@class PipEnablerManager;
// [P4] A plain C function: a category interface would require the full
// @interface of PipEnablerManager, which is declared further down this file.
FOUNDATION_EXPORT void PipEnablerResizeMirrorLayer(PipEnablerManager *mgr, int width, int height);
API_AVAILABLE(ios(15.0))

@interface PipSampleBufferPlaybackDelegate : NSObject <AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, assign) BOOL playing;
// [P4] weak back-reference so the delegate can reach the manager mirror layer
@property (nonatomic, weak) PipEnablerManager *manager;
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
    // [P1 fix F1: black screen root cause]
    // Old code used CFAbsoluteTimeGetCurrent() (seconds since boot, 1e5-1e6 scale) as start,
    // while the enqueued sample PTS starts near 0 -- a 5-6 order-of-magnitude mismatch.
    // AVKit places the playhead at TimeRange.start where no frame exists => black PiP window.
    // Frame-mirroring case: return the infinite range (StackOverflow 69799535).
    return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
              didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
    // [P4] The PiP window renders our sampleBufferDisplayLayer, so the layer must be
    // resized to the render size the system asks for. A 2x2 layer makes the PiP window
    // sample a 2x2 surface -> black / garbage.
    if (newRenderSize.width > 0 && newRenderSize.height > 0) {
        PipEnablerResizeMirrorLayer(self.manager, newRenderSize.width, newRenderSize.height);
        PipEnablerDiagLog(@"P4: didTransitionToRenderSize %dx%d -> mirror layer resized",
                          newRenderSize.width, newRenderSize.height);
    }
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

// [P1 fix C1] conform so controller.delegate = self type-checks cleanly
@interface PipEnablerManager : NSObject <AVPictureInPictureControllerDelegate>

@property (nonatomic, assign) BOOL enabled;          // 使能开关
@property (nonatomic, assign) BOOL pipActive;        // 当前是否处于 PiP 中
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) AVSampleBufferDisplayLayer   *mirrorLayer;
@property (nonatomic, strong) UIView                       *mirrorHostView;
@property (nonatomic, weak)   AVPlayerLayer                *detectedPlayerLayer;
// 必须强引用：contentSource 的 playbackDelegate 为 weak。
@property (nonatomic, strong) id                            playbackDelegate;
@property (nonatomic, assign) CMTime                        lastPresentationTime;

// ★ 新增：界面【可见】手动开关按钮（悬浮）与其宿主窗口
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, weak)   UIWindow *buttonHostWindow;
// ★ 新增：诊断计数（用于黑屏定位：喂帧/入队/失败重建 次数）
@property (nonatomic, assign) NSUInteger diagFedFrames;
@property (nonatomic, assign) NSUInteger diagEnqueuedFrames;
@property (nonatomic, assign) NSUInteger diagRecoverCount;
// ★ 新增：帧镜像 PTS 基准（用真实到达时间推进，替代固定 +1/30 漂移）
@property (nonatomic, assign) CFTimeInterval mirrorPTSBase;
// ★ 新增：抓帧是否已确认命中（任一抓帧点成功喂帧后置 YES）
@property (nonatomic, assign) BOOL frameCaptureConfirmed;
// [P1 fix C3] reentry guard for teardown/disable flow
@property (nonatomic, assign) BOOL teardownInProgress;
// [P4] diagnostics
@property (nonatomic, assign) NSUInteger diagLumaSamples;
@property (nonatomic, assign) double      diagLastLuma;
// [v8] on-screen pixel source (the picture the user actually sees)
@property (nonatomic, assign) double      hookLuma;
@property (nonatomic, assign) double      snapshotLuma;
@property (nonatomic, assign) BOOL        useSnapshot;
@property (nonatomic, strong) CADisplayLink *snapshotTicker;
@property (nonatomic, assign) NSUInteger  diagSnapshotSamples;

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
- (void)teardownPipelineUnsafe;
- (void)setEnabledTearDownSafely;
- (void)resizeMirrorLayerToWidth:(int)width height:(int)height;
- (void)enqueuePixelBufferToMirror:(CVPixelBufferRef)pixelBuffer;
- (UIView *)snapshotSourceView;
- (UIView *)findViewWithClassPrefix:(NSString *)prefix inView:(UIView *)root;
- (CVPixelBufferRef)captureViewToPixelBuffer:(UIView *)view;
- (void)onSnapshotTick:(CADisplayLink *)link;
- (NSString *)recentDiagText;
- (void)showDiagnosticsAlert;

// ★ 新增：界面【可见】手动开关按钮
- (void)installFloatingButton;
- (void)removeFloatingButton;
- (void)updateFloatingButtonAppearance;
- (UIWindow *)activeKeyWindowForButton;

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
    PipEnablerDiagLog(@"bc setEnabled: enter, target=%d", (int)enabled);
    // [P2 hotfix] `self.enabled = enabled` re-entered THIS method, because
    // -setEnabled: is the setter of the `enabled` property -> infinite recursion -> crash.
    // Assign the backing ivar directly instead.
    if (_enabled == enabled) {
        return;
    }
    _enabled = enabled;
    PipEnablerDiagLog(@"bc setEnabled: state updated, persisting");
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kPipEnablerEnabledKey];
    [NSUserDefaults.standardUserDefaults synchronize];

    if (enabled) {
        PipEnablerDiagLog(@"bc setEnabled: -> refreshDetection");
        [self refreshDetection];
        PipEnablerDiagLog(@"bc setEnabled: refreshDetection done");
    } else {
        // [P1 fix C1] The old order was teardownPipeline() then stopPictureInPicture().
        // teardownPipeline() nils pipController, so the subsequent stop became a no-op --
        // the PiP content source was destroyed while PiP was still rendering.
        // That matches "tap the button => crash". Now: stop first, tear down after it stops.
        [self setEnabledTearDownSafely];
    }

    [NSNotificationCenter.defaultCenter postNotificationName:PipEnablerEnabledDidChangeNotification
                                                      object:self
                                                    userInfo:@{@"enabled": @(enabled)}];
}

- (void)toggle {
    [self setEnabled:!self.enabled];
}

#pragma mark - 界面【可见】手动开关按钮

/// 取当前可用于挂载悬浮按钮的 keyWindow（兼容多场景）。
- (UIWindow *)activeKeyWindowForButton {
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) { continue; }
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win == nil && ws.windows.count > 0) { win = ws.windows.firstObject; }
            if (win != nil) { break; }
        }
    }
    if (win == nil) {
        win = UIApplication.sharedApplication.keyWindow;
    }
    return win;
}

/// 安装一个可拖拽的悬浮按钮：点按 = 手动开/关 PiP；长按 = 切换 PiP 起播/停止。
- (void)installFloatingButton {
    if (self.floatingButton != nil) {
        [self updateFloatingButtonAppearance];
        return;
    }
    void (^make)(void) = ^{
        UIWindow *win = [self activeKeyWindowForButton];
        if (win == nil) {
            PipEnablerDiagLog(@"floating button: no keyWindow yet, will retry");
            return;
        }
        self.buttonHostWindow = win;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 56, 56);
        btn.layer.cornerRadius = 28.0;
        btn.layer.masksToBounds = NO;
        btn.layer.shadowColor = UIColor.blackColor.CGColor;
        btn.layer.shadowOpacity = 0.35;
        btn.layer.shadowRadius = 6.0;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        btn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn.titleLabel.numberOfLines = 2;
        btn.titleLabel.textAlignment = NSTextAlignmentCenter;
        btn.accessibilityIdentifier = @"PipEnablerFloatingButton";
        [btn addTarget:self
                action:@selector(floatingButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        // 长按统一由 UILongPressGestureRecognizer 处理（见下），此处不再绑定 UIControl 事件
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.6;
        [btn addGestureRecognizer:lp];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];

        // 初始位置：右上角内侧，避让刘海/状态栏
        CGRect bounds = win.bounds;
        CGFloat inset = 12.0;
        CGFloat topSafe = win.safeAreaInsets.top;
        btn.center = CGPointMake(bounds.size.width - inset - 28.0,
                                 topSafe + inset + 28.0);

        [win addSubview:btn];
        self.floatingButton = btn;
        [self updateFloatingButtonAppearance];
        PipEnablerDiagLog(@"floating button installed on window=%@", NSStringFromClass(win.class));
    };

    if (NSThread.isMainThread) {
        make();
    } else {
        dispatch_async(dispatch_get_main_queue(), make);
    }
    // 兜底：keyWindow 尚未就绪时，稍后重试几次
    if (self.floatingButton == nil) {
        for (NSUInteger i = 1; i <= 5; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * i * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.floatingButton == nil) { make(); }
            });
        }
    }
}

- (void)removeFloatingButton {
    void (^rm)(void) = ^{
        [self.floatingButton removeFromSuperview];
        self.floatingButton = nil;
    };
    if (NSThread.isMainThread) { rm(); }
    else { dispatch_async(dispatch_get_main_queue(), rm); }
}

- (void)updateFloatingButtonAppearance {
    void (^up)(void) = ^{
        UIButton *btn = self.floatingButton;
        if (btn == nil) { return; }
        BOOL on = self.enabled;
        [btn setTitle:(on ? @"PiP 开" : @"PiP 关") forState:UIControlStateNormal];
        btn.backgroundColor = on
            ? [UIColor colorWithRed:0.10 green:0.55 blue:0.30 alpha:0.90]
            : [UIColor colorWithWhite:0.1 alpha:0.85];
    };
    if (NSThread.isMainThread) { up(); }
    else { dispatch_async(dispatch_get_main_queue(), up); }
}

- (void)floatingButtonTapped:(UIButton *)sender {
    PipEnablerDiagLog(@"floating button tapped -> toggle PiP enabler");
    [self toggle];
}


- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) { return; }
    // [P1] Long-press now shows diagnostics (screenshot-able), not start/stop.
    PipEnablerDiagLog(@"floating button long-press -> show diagnostics");
    [self showDiagnosticsAlert];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (v == nil) { return; }
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:v.superview];
}

#pragma mark - 探测 / 挂接

- (CALayer *)detectedContentPlayerLayer {
    return self.detectedPlayerLayer;
}

- (void)refreshDetection {
    PipEnablerDiagLog(@"bc refreshDetection: enter, mirrorLayer=%@ mirrorHostView=%@",
                      self.mirrorLayer ? @"yes" : @"no",
                      self.mirrorHostView ? @"yes" : @"no");
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
            [self attachToPlayerLayer:pl];
        }
        // [P4] The mirror pipeline is the PiP content source now, so it must ALWAYS run.
        // It used to be an else-branch, so any detected AVPlayerLayer blocked it.
        [self prepareMirrorPipeline];
    });
}

/// 路径 A：直接用内容侧 AVPlayerLayer 构造原生 PiP
- (void)attachToPlayerLayer:(AVPlayerLayer *)playerLayer {
    if (playerLayer == nil) {
        return;
    }
    // [P4] The main video is rendered by a self-made ijkplayer-derived engine
    // (OpenGL ES2 + VideoToolbox); the system AVPlayer in this app belongs to the ad
    // SDKs (CSJ/GDT/KS). A native PiP on such an AVPlayerLayer shows a BLACK window
    // while the real video keeps playing in place.
    // So: do NOT create a native controller here. The mirror pipeline (fed with the
    // real VideoToolbox frames) is the PiP content source instead.
    PipEnablerDiagLog(@"P4: AVPlayerLayer detected (likely an ad player) -> native PiP path disabled");
}

/// 路径 B：帧镜像 —— 自建 AVSampleBufferDisplayLayer + sampleBufferDisplayLayer contentSource
- (void)prepareMirrorPipeline {
    PipEnablerDiagLog(@"bc prepareMirrorPipeline: enter");
    // [P1 fix F3] PiP requires AVAudioSession playback/moviePlayback.
    // [P2] Scheduled asynchronously -- audio setup is not allowed to jeopardize this path.
    PipEnablerConfigureAudioSession();
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
                // [v7] The host view is sized to the mirror layer so the layer is not
                // clipped away. It is placed BEHIND the app content (index 0), so the
                // user never sees it, while the system can still render the layer.
                UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 640, 360)];
                host.backgroundColor = UIColor.clearColor;
                host.opaque = NO;
                host.alpha = 1.0;          // 必须 >0：alpha=0/hidden 会挂起图层渲染
                host.hidden = NO;          // 必须非隐藏
                host.clipsToBounds = YES;   // [P4] keep the bigger layer invisible on screen
                host.userInteractionEnabled = NO;
                // [P4] The PiP window samples this layer, so give it a real size.
                // The 2x2 host view clips it so nothing shows on screen.
                self.mirrorLayer.frame = host.bounds;
                // [v8] start the on-screen pixel source (~10 fps)
                if (self.snapshotTicker == nil) {
                    CADisplayLink *sl =
                        [CADisplayLink displayLinkWithTarget:self selector:@selector(onSnapshotTick:)];
                    sl.preferredFramesPerSecond = 10;
                    [sl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
                    self.snapshotTicker = sl;
                }
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
                [keyWindow insertSubview:host atIndex:0];   // [v7] behind the app content, invisible on screen
                self.mirrorHostView = host;
                PIP_LOG(@"mirror host view attached to keyWindow");
            PipEnablerDiagLog(@"mirror host view attached to keyWindow, hidden=%d alpha=%.2f frame=%@",
                              (int)host.hidden, host.alpha, NSStringFromCGRect(host.frame));
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
                PipSampleBufferPlaybackDelegate *delegate = [[PipSampleBufferPlaybackDelegate alloc] init];
        delegate.manager = self;   // [P4] give the delegate access to the mirror layer
        self.playbackDelegate = delegate;
            }
            AVPictureInPictureControllerContentSource *src =
                [[AVPictureInPictureControllerContentSource alloc]
                    initWithSampleBufferDisplayLayer:self.mirrorLayer
                                    playbackDelegate:self.playbackDelegate];
            AVPictureInPictureController *controller =
                [[AVPictureInPictureController alloc] initWithContentSource:src];
            [self configureAutoStartForController:controller];
            controller.delegate = self;   // [P1 fix C1] need didStop callback to finish teardown
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
        BOOL possible = (self.pipController != nil) && self.pipController.isPictureInPicturePossible;
        PipEnablerDiagLog(@"P4: pictureInPicturePossible=%d active=%d enabled=%d controller=%@",
                          (int)possible,
                          (int)((self.pipController != nil) && self.pipController.isPictureInPictureActive),
                          (int)self.enabled, self.pipController ? @"yes" : @"no");
        if (self.enabled && self.pipController != nil &&
            self.pipController.isPictureInPicturePossible &&
            !self.pipController.isPictureInPictureActive) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PIP_LOG(@"pictureInPicturePossible=YES -> startPictureInPicture");
                PipEnablerDiagLog(@"pictureInPicturePossible=YES -> startPictureInPicture; captureConfirmed=%d enqueued=%lu",
                                  (int)self.frameCaptureConfirmed, (unsigned long)self.diagEnqueuedFrames);
                [self.pipController startPictureInPicture];
            });
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// [P1 fix C2] teardownPipeline touches UIKit (removeFromSuperview / removeObserver) and is
// reachable from the frame-capture thread (Failed self-heal). Always marshal to main.
- (void)teardownPipeline {
    if (NSThread.isMainThread) {
        [self teardownPipelineUnsafe];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self teardownPipelineUnsafe];
        });
    }
}

- (void)teardownPipelineUnsafe {
    PipEnablerDiagLog(@"breadcrumb: teardownPipelineUnsafe enter");
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

// [P1 fix C1] Stop PiP first, then tear the pipeline down once PiP has actually stopped.
- (void)setEnabledTearDownSafely {
    if (self.teardownInProgress) {
        return;
    }
    self.teardownInProgress = YES;
    PipEnablerDiagLog(@"breadcrumb: setEnabledTearDownSafely enter, pipActive=%d ctrl=%@",
                      (int)self.pipActive, self.pipController ? @"yes" : @"no");

    AVPictureInPictureController *ctrl = self.pipController;
    if (self.pipActive && ctrl != nil) {
        [self stopPictureInPicture];
        PipEnablerDiagLog(@"C1 fix: stopPictureInPicture issued, teardown deferred until stopped");
        // Fallback in case didStop never arrives.
        __weak PipEnablerManager *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PipEnablerManager *s = weakSelf;
            if (s == nil) { return; }
            if (s.teardownInProgress) {
                s.teardownInProgress = NO;
                [s teardownPipeline];
            }
        });
        return;
    }

    self.teardownInProgress = NO;
    [self teardownPipeline];
}

// [P1 fix C1] PiP fully stopped -> safe to destroy the content source now.
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    PipEnablerDiagLog(@"didStopPictureInPicture -> teardown pipeline");
    self.teardownInProgress = NO;
    [self teardownPipeline];
}

// [P1] Read the tail of the persistent diagnostics log for on-device inspection.
// [P4] Resize the mirror layer to the PiP render size the system asks for.
- (void)resizeMirrorLayerToWidth:(int)width height:(int)height {
    if (width <= 0 || height <= 0) { return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.mirrorHostView != nil) {
            // [v7] keep the host and the layer the same size (no clipping)
            self.mirrorHostView.frame = CGRectMake(0, 0, width, height);
        }
        if (self.mirrorLayer != nil) {
            self.mirrorLayer.frame = CGRectMake(0, 0, width, height);
            [self.mirrorLayer setNeedsLayout];
        }
    });
}

// [P4] One-shot state summary so a single screenshot tells us everything.
- (NSString *)stateSummary {
    AVPictureInPictureController *c = self.pipController;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"enabled=%d controller=%@ possible=%d active=%d\n",
        (int)self.enabled, c ? @"yes" : @"no",
        (int)(c ? c.isPictureInPicturePossible : 0),
        (int)(c ? c.isPictureInPictureActive : 0)];
    [s appendFormat:@"mirrorLayer=%@ status=%ld lastLuma=%.4f fed=%lu enq=%lu\n",
        self.mirrorLayer ? @"yes" : @"no",
        (long)(self.mirrorLayer ? self.mirrorLayer.status : -1),
        self.diagLastLuma,
        (unsigned long)self.diagFedFrames, (unsigned long)self.diagEnqueuedFrames];
    [s appendFormat:@"hookLuma=%.4f snapshotLuma=%.4f useSnapshot=%d\n",
        self.hookLuma, self.snapshotLuma, (int)self.useSnapshot];
    [s appendString:@"--- capture sources ---\n"];
    [s appendString:PipEnablerFeedSourceSummary()];
    return s;
}

- (NSString *)recentDiagText {
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = dirs.count > 0 ? dirs.firstObject : NSTemporaryDirectory();
    NSString *p = [docs stringByAppendingPathComponent:@"PipEnabler.diag.log"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (d.length == 0) {
        return @"(no diagnostics yet)";
    }
    NSUInteger want = MIN(d.length, (NSUInteger)1800);
    NSString *s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(d.length - want, want)]
                                         encoding:NSUTF8StringEncoding];
    return s ?: @"(decode failed)";
}

// [P1] Long-press shows the diagnostics on screen so no tooling is needed on the device.
- (void)showDiagnosticsAlert {
    NSString *text = [[self stateSummary] stringByAppendingString:[self recentDiagText]];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"PipEnabler 诊断日志"
                                            message:text
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
    UIViewController *top = nil;
    UIWindow *win = [self activeKeyWindowForButton];
    if (win.rootViewController != nil) {
        top = win.rootViewController;
        while (top.presentedViewController != nil) {
            top = top.presentedViewController;
        }
    }
    if (top != nil) {
        [top presentViewController:alert animated:YES completion:nil];
    } else {
        PipEnablerDiagLog(@"diagnostics alert: no view controller to present");
    }
}

// [v8] Shared enqueue path: timestamp on the control timebase and push to the layer.
- (void)enqueuePixelBufferToMirror:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == NULL) { return; }
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (self.mirrorPTSBase <= 0) { self.mirrorPTSBase = now; }
    CMTime pts = kCMTimeInvalid;
    AVSampleBufferDisplayLayer *tbLayer = self.mirrorLayer;
    if (tbLayer != nil && tbLayer.controlTimebase != NULL) {
        pts = CMTimebaseGetTime(tbLayer.controlTimebase);
    }
    if (!CMTIME_IS_NUMERIC(pts)) {
        pts = CMTimeMakeWithSeconds(now - self.mirrorPTSBase, 600);
    }
    self.lastPresentationTime = pts;

    CMSampleBufferRef sb = PipEnablerCreateSampleBuffer(pixelBuffer, pts);
    if (sb) {
        [self feedSampleBuffer:sb];
        CFRelease(sb);
    }
    if (!self.frameCaptureConfirmed) {
        self.frameCaptureConfirmed = YES;
        PipEnablerDiagLog(@"frame capture CONFIRMED (first pixel buffer fed) -- H1 disproved");
    }
}

// [v8] ---- on-screen pixel source -------------------------------------------------
// The hooked frames turned out to be nearly black (avg luma ~6%), i.e. they are not the
// picture the user sees. This source grabs the pixels that are actually on screen and
// is used whenever it is measurably brighter than the hooked frames.

- (UIView *)findViewWithClassPrefix:(NSString *)prefix inView:(UIView *)root {
    if (root == nil) { return nil; }
    NSString *cls = NSStringFromClass(root.class);
    if ([cls hasPrefix:prefix] && root.bounds.size.width > 100 && root.bounds.size.height > 100) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *hit = [self findViewWithClassPrefix:prefix inView:sub];
        if (hit != nil) { return hit; }
    }
    return nil;
}

- (UIView *)snapshotSourceView {
    UIWindow *win = [self activeKeyWindowForButton];
    if (win == nil) { return nil; }
    UIView *root = win.rootViewController.view;
    if (root == nil) { return nil; }
    // Prefer the app native content view (FOKContent...) so the PiP shows the video
    // rather than the whole UI.
    UIView *fok = [self findViewWithClassPrefix:@"FOKContent" inView:root];
    if (fok != nil) { return fok; }
    return root;
}

- (CVPixelBufferRef)captureViewToPixelBuffer:(UIView *)view {
    if (view == nil) { return NULL; }
    CGSize size = view.bounds.size;
    if (size.width < 32 || size.height < 32) { return NULL; }
    @try {
        UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx == NULL) { UIGraphicsEndImageContext(); return NULL; }
        [view.layer renderInContext:ctx];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (img == nil) { return NULL; }
        CGImageRef cg = img.CGImage;
        if (cg == NULL) { return NULL; }
        size_t w = CGImageGetWidth(cg);
        size_t h = CGImageGetHeight(cg);
        if (w == 0 || h == 0) { return NULL; }

        CVPixelBufferRef pb = NULL;
        NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                 (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
            return NULL;
        }
        if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) {
            CFRelease(pb);
            return NULL;
        }
        void *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                  kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (bctx != NULL) {
            CGContextDrawImage(bctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
            CGContextRelease(bctx);
        }
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        return pb;
    } @catch (NSException *e) {
        return NULL;
    }
}

- (void)onSnapshotTick:(CADisplayLink *)link {
    if (!self.enabled) { return; }
    if (self.mirrorLayer == nil) { return; }
    UIView *view = [self snapshotSourceView];
    if (view == nil) { return; }
    CVPixelBufferRef pb = [self captureViewToPixelBuffer:view];
    if (pb == NULL) { return; }
    double mn = 0, mx = 0, avg = 0;
    if (PipEnablerLumaStatsBGRA(pb, &mn, &mx, &avg)) {
        self.snapshotLuma = avg / 255.0;
        if (self.diagSnapshotSamples < 3) {
            self.diagSnapshotSamples += 1;
            PipEnablerDiagLog(@"v8: snapshot luma=%.4f max=%.4f view=%@ %zux%zu",
                              self.snapshotLuma, mx / 255.0,
                              NSStringFromClass(view.class),
                              (size_t)view.bounds.size.width, (size_t)view.bounds.size.height);
        }
        // [v8] Prefer the on-screen picture whenever it is measurably brighter.
        if (!self.useSnapshot && self.snapshotLuma > self.hookLuma + 0.05) {
            self.useSnapshot = YES;
            PipEnablerDiagLog(@"v8: use SCREENSHOT source (snap=%.3f hook=%.3f)",
                              self.snapshotLuma, self.hookLuma);
        } else if (self.useSnapshot && self.snapshotLuma < self.hookLuma - 0.05) {
            self.useSnapshot = NO;
            PipEnablerDiagLog(@"v8: back to HOOK source (snap=%.3f hook=%.3f)",
                              self.snapshotLuma, self.hookLuma);
        }
    }
    if (self.useSnapshot) {
        [self enqueuePixelBufferToMirror:pb];
    }
    CFRelease(pb);
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

    // [v8] Black-frame filter BEFORE the enqueue. The layer always shows the LAST
    // enqueued sample, so a black frame must never reach it at all. (In v6/v7 this
    // check ran after the enqueue, so black frames were still delivered.)
    double mn = 0, mx = 0, avg = 0;
    if (PipEnablerLumaStats(pixelBuffer, &mn, &mx, &avg)) {
        self.hookLuma = avg / 255.0;
        self.diagLastLuma = self.hookLuma;
        PipFeedSourceStat *st = PipEnablerFeedSourceStat(gPipFeedSourceTag);
        if (mx < 24.0) {
            if (st != NULL) {
                st->black += 1;
                st->lastMaxY = mx;
            }
            if (self.diagLumaSamples < 3 || (st != NULL && (st->black % 50) == 0)) {
                self.diagLumaSamples += 1;
                PipEnablerDiagLog(@"v8: skip black frame src=%s maxY=%.0f avgY=%.0f (black=%lu)",
                                  gPipFeedSourceTag, mx, avg,
                                  (unsigned long)(st ? st->black : 0));
            }
            return;
        }
        if (st != NULL) {
            st->total += 1;
            st->lastMaxY = mx;
        }
        if (self.diagLumaSamples < 8) {
            self.diagLumaSamples += 1;
            OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
            PipEnablerDiagLog(@"v8: hook GOOD frame src=%s minY=%.0f maxY=%.0f avgY=%.0f size=%zux%zu fmt=%c%c%c%c",
                              gPipFeedSourceTag, mn, mx, avg,
                              CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                              (char)((fmt >> 24) & 0xFF), (char)((fmt >> 16) & 0xFF),
                              (char)((fmt >> 8) & 0xFF), (char)(fmt & 0xFF));
        }
    }

    // [v8] When the on-screen source is measurably brighter it is the real picture,
    // so let it feed the mirror instead of the hooked frames.
    if (self.useSnapshot) {
        return;
    }
    [self enqueuePixelBufferToMirror:pixelBuffer];
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
        // ★【黑屏修复】失败不再只是 flush：重建整条镜像管线，避免长期黑屏。
        if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            PipEnablerDiagLog(@"mirrorLayer.status=Failed -> rebuild mirror pipeline (recover #%lu)",
                              (unsigned long)(self.diagRecoverCount + 1));
            self.diagRecoverCount += 1;
            [layer flush];
            [self teardownPipeline];
            [self prepareMirrorPipeline];
            layer = self.mirrorLayer;
            if (layer == nil) { return; }
        }
        // ★【黑屏修复】入队前做背压：层未就绪时丢弃本帧而非硬塞，
        //   避免样本堆积被判不可渲染 / 时间轴错乱。
        if ([layer respondsToSelector:@selector(isReadyForMoreMediaData)] &&
            !layer.isReadyForMoreMediaData) {
            self.diagFedFrames += 1;
            return;
        }
        if ([layer respondsToSelector:@selector(enqueueSampleBuffer:)]) {
            [layer enqueueSampleBuffer:sampleBuffer];
            self.diagFedFrames += 1;
            self.diagEnqueuedFrames += 1;
            if (self.diagEnqueuedFrames == 1) {
                PipEnablerDiagLog(@"first sample buffer enqueued to mirrorLayer");
            }
        }
        // [v7] the timebase rate is set once when it is created; resetting it on
        // every frame causes scheduling hiccups on the layer.
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
    gPipFeedSourceTag = "getter";
    PIP_ENABLER_FEED_PIXELBUFFER(pb);
    return pb;
}

/// (d) 返回对象、入参恰为一个 CVPixelBuffer 的工厂/初始化方法（@24@0:8^{__CVBuffer=}16）。
/// 入参即解码后的帧；先喂帧再调用原实现。
static id PipEnablerSwizzledCVBufferFactory(id self, SEL _cmd, CVPixelBufferRef buffer) {
    IMP original = PipEnablerLookupOriginalIMP(self, gOriginalCVBufferFactoryIMPs);
    gPipFeedSourceTag = "factory";
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
    gPipFeedSourceTag = "transform";
    PIP_ENABLER_FEED_PIXELBUFFER(buffer);
    if (original != NULL) {
        CVPixelBufferRef out = ((CVPixelBufferRef (*)(id, SEL, CVPixelBufferRef))original)(self, _cmd, buffer);
        gPipFeedSourceTag = "transform2";
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
            gPipFeedSourceTag = "fok";
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
        gPipFeedSourceTag = "cvtex";
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
            PipEnablerDiagLog(@"CRITICAL: MSHookFunction unavailable -> C-function frame capture DISABLED (likely black PiP if no other capture point fires)");
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

// [v6] Rate limit PER SOURCE. The old global limiter let the pool-create path
// (which returns an empty buffer) win every 8ms window, so the mirror was fed
// black frames.
static BOOL PipEnablerCBFeedAllowed(void) {
    PipFeedSourceStat *st = PipEnablerFeedSourceStat(gPipFeedSourceTag);
    if (st == NULL) { return NO; }
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - st->lastFeed < 0.008) {
        return NO;
    }
    st->lastFeed = now;
    return YES;
}

static void *PipEnablerHookedCVPBGetBaseAddressOfPlane(CVPixelBufferRef pixelBuffer, size_t planeIndex) {
    if (pixelBuffer != NULL && planeIndex == 0 && PipEnablerCBFeedAllowed()) {
        gPipFeedSourceTag = "getbase";
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
        gPipFeedSourceTag = "lockbase";
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
            // [v6] pool-create path: the buffer was just allocated and is still empty (black) -> never feed it to the mirror pipeline
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

// [P4] Bridge helper: implemented here so the manager's interface is already visible.
void PipEnablerResizeMirrorLayer(PipEnablerManager *mgr, int width, int height) {
    if (mgr == nil) { return; }
    [mgr resizeMirrorLayerToWidth:width height:height];
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
            // ★ 界面【可见】手动开关按钮：随 App 启动即挂载
            [manager installFloatingButton];
            [NSNotificationCenter.defaultCenter addObserverForName:PipEnablerEnabledDidChangeNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification * _Nonnull note) {
                [manager updateFloatingButtonAppearance];
            }];
            PipEnablerDiagLog(@"boot: diag log at sandbox Documents/PipEnabler.diag.log");

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
