//
//  TestHost.m  ——  #377 iOS 模拟器【运行期】自测宿主
//
//  目的：真正闭环 fact #372/#376 反复自认的"无真机"缺口 ——
//    在 GitHub Actions 的 macos-13 runner 上，用 iOS 模拟器运行时【真实运行】一个最小宿主 App，
//    dlopen 载入按 simulator 架构编译的 PipEnabler.dylib，验证：
//      1) __attribute__((constructor)) 入口真实执行（不崩溃）；
//      2) PipEnablerInstallSwizzles / PipEnablerInstallFrameCaptureHooks 真实改写了方法 IMP；
//      3) 构造一个 CVPixelBuffer，经导出入口 PipEnablerFeedPixelBuffer 喂入镜像
//         AVSampleBufferDisplayLayer（该层已由 dylib 挂到 keyWindow 视图层级内）；
//      4) 读取镜像层的 status / error、AVPictureInPictureController 的
//         isPictureInPicturePossible，并尝试 startPictureInPicture。
//
//  判定证据：把报告写入 App 的 Documents/pip_selftest_report.txt，由 workflow 用
//    `xcrun simctl get_app_container ... data` 取回；同时用 NSLog 打印到 --console-pty。
//
//  说明：模拟器上 AVPictureInPictureController.isPictureInPictureSupported 通常为 NO，
//        因此"PiP 是否真能起播"在模拟器上无法完全等价验证（如实标注）。
//        但 hook 是否真命中、抓帧/喂帧链路是否真跑通（此前全靠静态推断）可在模拟器上闭环。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdarg.h>

static NSMutableString *gRep = nil;

static void R(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gRep == nil) { gRep = [NSMutableString string]; }
    [gRep appendFormat:@"%@\n", s];
    NSLog(@"[selftest] %@", s);
}

#pragma mark - 供被注入 dylib 的 (a) 号钩子 swizzle 的测试纹理类

static CVPixelBufferRef gTestPixelBuffer = NULL;

@interface PipTestTexture : NSObject
// 返回类型编码 ^{__CVBuffer=}16@0:8，selector 恰为 copyPixelBuffer ——
// 完全落在 dylib (a) 号钩子的匹配范围内（sel==copyPixelBuffer 且 enc 含 CVBuffer）。
- (CVPixelBufferRef)copyPixelBuffer __attribute__((cf_returns_not_retained));
@end

@implementation PipTestTexture
- (CVPixelBufferRef)copyPixelBuffer {
    // 返回全局帧缓冲：若 dylib 的 (a) 钩子生效，调用本方法会被包裹，
    // 该帧会被自动经 PipEnablerFeedPixelBuffer 喂入镜像层。
    return gTestPixelBuffer;
}
@end

#pragma mark - App Delegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate {
    void *_dylibHandle;
    Class _mgrClass;
    IMP _beforeCopy;
    IMP _beforeEnq;
    BOOL _copyHooked;
    BOOL _enqHooked;
}

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    R(@"=== PIP SIMULATOR SELFTEST (#377) ===");
    R(@"device=%@ system=%@ %@", [[UIDevice currentDevice] name],
      [[UIDevice currentDevice] systemName], [[UIDevice currentDevice] systemVersion]);
#if TARGET_OS_SIMULATOR
    R(@"built for iOS Simulator: YES");
#else
    R(@"built for iOS Simulator: NO");
#endif
    R(@"AVPictureInPictureController.isPictureInPictureSupported=%d",
      (int)[AVPictureInPictureController isPictureInPictureSupported]);
    R(@"dlsym(RTLD_DEFAULT, \"MSHookFunction\")=%p",
      dlsym(RTLD_DEFAULT, "MSHookFunction"));

    // 先建好可见的 keyWindow：dylib 的镜像宿主视图需要一个已存在的 keyWindow 才会挂载。
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];

    // 等窗口/通知/异步管线稳定后再做重活。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self runSelftest];
    });
    return YES;
}

- (void)runSelftest {
    // ---------- 1) dlopen 之前先备份关键方法 IMP（用来证明构造函数真的动了运行时） ----------
    Class testCls = [PipTestTexture class];
    Method mCopy = class_getInstanceMethod(testCls, @selector(copyPixelBuffer));
    _beforeCopy = mCopy ? method_getImplementation(mCopy) : NULL;
    Class sbCls = NSClassFromString(@"AVSampleBufferDisplayLayer");
    Method mEnq = sbCls ? class_getInstanceMethod(sbCls, @selector(enqueueSampleBuffer:)) : NULL;
    _beforeEnq = mEnq ? method_getImplementation(mEnq) : NULL;
    R(@"pre-dlopen IMP: copyPixelBuffer=%p  enqueueSampleBuffer:=%p", _beforeCopy, _beforeEnq);

    // ---------- 2) 准备一帧真实的 CVPixelBuffer ----------
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef pb = NULL;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    R(@"CVPixelBufferCreate => %d pb=%p", (int)cr, pb);
    if (pb != NULL) {
        CVPixelBufferLockBaseAddress(pb, 0);
        void *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        if (base != NULL) { memset(base, 0x66, bpr * 240); }
        CVPixelBufferUnlockBaseAddress(pb, 0);
        gTestPixelBuffer = pb;
    }

    // ---------- 3) dlopen —— 构造函数在此刻执行 ----------
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    NSString *dylibPath = [bundlePath stringByAppendingPathComponent:@"PipEnabler.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
        NSString *alt = [bundlePath stringByAppendingPathComponent:@"Frameworks/PipEnabler.dylib"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:alt]) { dylibPath = alt; }
    }
    const char *envPath = getenv("PIP_DYLIB_PATH");
    if (envPath) { dylibPath = [NSString stringWithUTF8String:envPath]; }

    dlerror();
    _dylibHandle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW);
    const char *de = dlerror();
    R(@"dlopen(%@) => handle=%p dlerror=%s", dylibPath, _dylibHandle, de ? de : "(null)");

    // ---------- 4) dlopen 之后复核 IMP 是否被构造函数改写 ----------
    Method mCopy2 = class_getInstanceMethod(testCls, @selector(copyPixelBuffer));
    IMP afterCopy = mCopy2 ? method_getImplementation(mCopy2) : NULL;
    Method mEnq2 = sbCls ? class_getInstanceMethod(sbCls, @selector(enqueueSampleBuffer:)) : NULL;
    IMP afterEnq = mEnq2 ? method_getImplementation(mEnq2) : NULL;
    _copyHooked = (afterCopy != NULL && afterCopy != _beforeCopy);
    _enqHooked  = (afterEnq  != NULL && afterEnq  != _beforeEnq);
    R(@"post-dlopen IMP: copyPixelBuffer=%p (hooked=%d)  enqueueSampleBuffer:=%p (hooked=%d)",
      afterCopy, (int)_copyHooked, afterEnq, (int)_enqHooked);

    // ---------- 5) 管理器 / 导出符号 ----------
    _mgrClass = NSClassFromString(@"PipEnablerManager");
    R(@"NSClassFromString(@\"PipEnablerManager\")=%p", _mgrClass);
    BOOL (*fnIsEnabled)(void) = _dylibHandle ? (BOOL (*)(void))dlsym(_dylibHandle, "PipEnablerIsEnabled") : NULL;
    void (*fnFeed)(CVPixelBufferRef) = _dylibHandle ? (void (*)(CVPixelBufferRef))dlsym(_dylibHandle, "PipEnablerFeedPixelBuffer") : NULL;
    BOOL (*fnStart)(void) = _dylibHandle ? (BOOL (*)(void))dlsym(_dylibHandle, "PipEnablerStartPictureInPicture") : NULL;
    R(@"symbols: IsEnabled=%p FeedPixelBuffer=%p StartPiP=%p", fnIsEnabled, fnFeed, fnStart);
    if (fnIsEnabled) { R(@"PipEnablerIsEnabled()=%d", (int)fnIsEnabled()); }

    // ---------- 5.5) 显式开启使能 ----------
    // P1 起 PIP_ENABLER_DEFAULT_ENABLED=NO（默认关闭，由用户手动点按钮开启），
    // 自测宿主必须先显式打开，否则 feedPixelBuffer 会被 enabled 门禁拦下，mirrorOK 恒为 0。
    void (*fnSetEnabled)(BOOL) = _dylibHandle ? (void (*)(BOOL))dlsym(_dylibHandle, "PipEnablerSetEnabled") : NULL;
    if (fnSetEnabled) {
        fnSetEnabled(YES);
        R(@"PipEnablerSetEnabled(YES) 已调用 -> IsEnabled=%d", (int)(fnIsEnabled ? fnIsEnabled() : -1));
    } else {
        R(@"!! dlsym(PipEnablerSetEnabled) 失败，无法开启使能");
    }

    // ---------- 6) 触发抓帧/喂帧链路 ----------
    // (a) 走 swizzled -copyPixelBuffer：如果钩子生效，这次调用会自动把 gTestPixelBuffer 喂进镜像层。
    Class cls = testCls;
    id tex = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc)), @selector(init));
    CVPixelBufferRef (*copyFn)(id, SEL) = (CVPixelBufferRef (*)(id, SEL))[tex methodForSelector:@selector(copyPixelBuffer)];
    CVPixelBufferRef got = copyFn(tex, @selector(copyPixelBuffer));
    R(@"[PipTestTexture copyPixelBuffer] -> %p (期望 %p)，该路径应触发 (a) 号钩子自动喂帧", got, pb);

    // (b) 直接经导出入口喂入若干帧。
    if (fnFeed && pb != NULL) {
        for (int i = 0; i < 5; i++) { fnFeed(pb); }
        R(@"PipEnablerFeedPixelBuffer(pb) x5 已调用");
    }

    // 给管线 2 秒把帧入队、让 controlTimebase 推进。[v12] 再留 1.5s 让 2s 重试定时器至少跑一轮。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self readStateAndFinish];
    });
}

- (id)managerInstance {
    if (_mgrClass == Nil) { return nil; }
    id inst = nil;
    @try {
        inst = ((id (*)(id, SEL))objc_msgSend)(_mgrClass, @selector(shared));
    } @catch (NSException *e) {
        R(@"manager shared 异常: %@", e);
    }
    return inst;
}

- (void)readStateAndFinish {
    id mgr = [self managerInstance];
    R(@"manager instance=%p", mgr);

    id mirror = nil, hostView = nil, pipc = nil, playbackDelegate = nil;
    @try {
        if (mgr) {
            mirror = [mgr valueForKey:@"mirrorLayer"];
            hostView = [mgr valueForKey:@"mirrorHostView"];
            pipc = [mgr valueForKey:@"pipController"];
            playbackDelegate = [mgr valueForKey:@"playbackDelegate"];
        }
    } @catch (NSException *e) {
        R(@"KVC 读取内部属性异常: %@", e);
    }

    // [v12] 启动重试路径断言：2s 定时器应至少跑过一轮 refreshDetection 重试检查。
    NSUInteger retryChecks = 0;
    @try {
        if (mgr) {
            id rc = [mgr valueForKey:@"pipRetryChecks"];
            if ([rc respondsToSelector:@selector(unsignedLongValue)]) {
                retryChecks = [rc unsignedLongValue];
            }
        }
    } @catch (NSException *e) {
        R(@"KVC 读取 pipRetryChecks 异常: %@", e);
    }
    R(@"v12 pipRetryChecks=%lu (2s 定时器 refreshDetection 重试检查次数)", (unsigned long)retryChecks);

    R(@"mirrorLayer=%p  mirrorHostView=%p  pipController=%p  playbackDelegate=%p",
      mirror, hostView, pipc, playbackDelegate);

    BOOL mirrorOK = NO;
    if (mirror != nil) {
        AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)mirror;
        CGSize sz = layer.bounds.size;
        R(@"mirrorLayer.status=%ld  error=%@  readyForMoreMediaData=%d  bounds=%.0fx%.0f  superlayer=%p",
          (long)layer.status, layer.error, (int)layer.isReadyForMoreMediaData,
          sz.width, sz.height, layer.superlayer);
        R(@"mirrorLayer 是否在窗口层级内: superlayer!=nil -> %d", layer.superlayer != nil ? 1 : 0);
        // status: 0=unknown, 1=rendering, -1=failed
        mirrorOK = (layer.status != AVQueuedSampleBufferRenderingStatusFailed);
    }
    if (hostView != nil) {
        UIView *v = (UIView *)hostView;
        R(@"mirrorHostView frame=%@ hidden=%d alpha=%.2f superview=%p window=%p",
          NSStringFromCGRect(v.frame), (int)v.hidden, (double)v.alpha, v.superview, v.window);
    }

    R(@"AVPictureInPictureController.isPictureInPictureSupported=%d",
      (int)[AVPictureInPictureController isPictureInPictureSupported]);

    BOOL pipPossible = NO;
    if (pipc != nil) {
        AVPictureInPictureController *c = (AVPictureInPictureController *)pipc;
        pipPossible = c.isPictureInPicturePossible;
        R(@"pipController.isPictureInPicturePossible=%d  active=%d",
          (int)pipPossible, (int)c.isPictureInPictureActive);
        @try {
            [c startPictureInPicture];
            R(@"已调用 startPictureInPicture (模拟器上可能被系统拒绝)");
        } @catch (NSException *e) {
            R(@"startPictureInPicture 异常: %@", e);
        }
    } else {
        R(@"pipController=nil（模拟器 isPictureInPictureSupported=NO 时 dylib 按设计不创建 controller）");
    }

    // ---------- 判定 ----------
    BOOL pass = (_dylibHandle != NULL)
              && (_mgrClass != Nil)
              && _copyHooked          // 证明构造函数真实执行且抓帧钩子装上了
              && _enqHooked           // 证明 enqueueSampleBuffer: swizzle 真实生效
              && (gTestPixelBuffer != NULL)
              && mirrorOK             // 喂帧后镜像层未进入 failed（未崩溃、链路跑通）
              && (retryChecks >= 1);  // [v12] 2s 定时器重试路径真实执行
    R(@"");
    R(@"SUMMARY: dlopen=%d manager=%d hook(copyPixelBuffer)=%d hook(enqueue)=%d mirrorOK=%d pipSupported=%d pipPossible=%d retryChecks=%lu",
      _dylibHandle != NULL, _mgrClass != Nil, (int)_copyHooked, (int)_enqHooked,
      (int)mirrorOK, (int)[AVPictureInPictureController isPictureInPictureSupported], (int)pipPossible,
      (unsigned long)retryChecks);
    R(@"SELFTEST_RESULT: %@", pass ? @"PASS" : @"FAIL");

    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *out = [docs stringByAppendingPathComponent:@"pip_selftest_report.txt"];
    NSError *err = nil;
    [gRep writeToFile:out atomically:YES encoding:NSUTF8StringEncoding error:&err];
    NSLog(@"[selftest] report written to %@ err=%@", out, err);
    // 也额外写一份到 /tmp（便于 simctl 之外取用）。
    [gRep writeToFile:@"/tmp/pip_selftest_report.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[selftest] %@", gRep);
    exit(pass ? 0 : 3);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
