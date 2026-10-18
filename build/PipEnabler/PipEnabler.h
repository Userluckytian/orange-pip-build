//
//  PipEnabler.h
//  橘子视频 (com.aneur.haoen) 画中画(PiP)使能 dylib —— 公共接口
//
//  设计依据（见 fact #344 / i341_playback_stack.md）：
//    - 本 App 内容播放走自研 ijkplayer 衍生引擎 fok_media_core（编译进 Runner 主二进制，
//      OpenGL ES2 渲染 + VideoToolbox 硬解 + Flutter 外部纹理上屏）。
//    - 全包内【不存在】AVPlayerViewController / AVPictureInPictureController，
//      系统 AVPlayer 只用于穿山甲/GDT/KS 广告 SDK。
//    - 因此内容侧无可被 PiP 直接接管的 AVPlayerLayer；必须走“帧镜像”方案：
//      抓解码后的 CVPixelBuffer → 封装 CMSampleBuffer → 喂 AVSampleBufferDisplayLayer
//      → AVPictureInPictureController(contentSource: sampleBufferDisplayLayer) 启动系统 PiP。
//
//  本 dylib 只用公开 API（AVFoundation / AVKit / UIKit / Objective-C runtime），
//  通过 __attribute__((constructor)) 自动装载，iOS 15.0+（含 16.6.1）可用。
//

#ifndef PIP_ENABLER_H
#define PIP_ENABLER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 使能状态变化（被 setEnabled: 修改后）会在此通知上广播。
/// object 为 nil；userInfo 为空。
FOUNDATION_EXPORT NSNotificationName const PipEnablerEnabledDidChangeNotification;

/// 运行时开关：写 NSUserDefaults(PipEnablerEnabled) 并即时生效。
/// 关闭时停止 PiP 并拆除帧镜像层；打开时懒加载镜像层。
/// 必须在任意线程调用（内部会切到主线程）。
FOUNDATION_EXPORT void PipEnablerSetEnabled(BOOL enabled);

/// 当前使能状态（默认取自 NSUserDefaults，缺省为 PIP_ENABLER_DEFAULT_ENABLED）。
FOUNDATION_EXPORT BOOL PipEnablerIsEnabled(void);

/// 翻转使能状态（供 UI/快捷入口调用）。
FOUNDATION_EXPORT void PipEnablerToggle(void);

/// 手动强制启动 / 停止系统 PiP（不改变使能状态）。
FOUNDATION_EXPORT void PipEnablerStartPictureInPicture(void);
FOUNDATION_EXPORT void PipEnablerStopPictureInPicture(void);

/// 运行时探测结果：内容侧是否存在可直接接管的 AVPlayerLayer。
/// 无则为 nil（本 App 内容侧为 nil，需走帧镜像路径）。
FOUNDATION_EXPORT id PipEnablerDetectedContentPlayerLayer(void);

#ifdef __cplusplus
}
#endif

#endif /* PIP_ENABLER_H */
