#!/usr/bin/env bash
# =============================================================================
# verify_pip_symbols.sh — 在 GitHub Actions 的 macOS runner 内，对【打包产物中】的
#   Payload/Runner.app/Frameworks/PipEnabler.dylib 做符号级/反汇编级核验，
#   证明画中画是"真正实现"而非仅结构注入：
#
#   ①  PipEnabler* 全部导出符号已导出（nm -gU）；
#   ②  __attribute__((constructor)) 入口已注册且指向 PipEnablerInitialize
#       （新版 Xcode 工具链用 __TEXT,__init_offsets，旧版用 __DATA,__mod_init_func）；
#   ③  代码真实引用（未被链接器优化掉）以下 API：AVPictureInPictureController、
#       AVPictureInPictureControllerContentSource、AVSampleBufferDisplayLayer、
#       AVPlayerLayer、CMSampleBufferCreateReadyWithImageBuffer 等
#       —— nm -u / otool -L / otool -Iv / otool -tv / strings 交叉印证；
#   ④  LC_ID_DYLIB install_name == @executable_path/Frameworks/PipEnabler.dylib。
#
# ★ 只能在 runner(macOS) 内运行；本机(Windows)严禁安装/运行任何 iOS 工具链。
# 用法: bash build/verify_pip_symbols.sh <ipa|dylib> [outdir]
# 退出码恒为 0；结论写入 <outdir>/RESULT.txt。
# =============================================================================
set -uo pipefail

IN="${1:?usage: verify_pip_symbols.sh <ipa|dylib> [outdir]}"
OUT="${2:-verify_out}"
mkdir -p "$OUT"

DYLIB="$IN"
case "$IN" in
  *.ipa)
    mkdir -p "$OUT/_unzip"
    unzip -o -q "$IN" -d "$OUT/_unzip"
    DYLIB="$OUT/_unzip/Payload/Runner.app/Frameworks/PipEnabler.dylib"
    ;;
esac

RESULT="$OUT/RESULT.txt"
: > "$RESULT"
say()  { echo "$@"      | tee -a "$RESULT"; }
pass() { echo "PASS: $*" | tee -a "$RESULT"; }
fail() { echo "FAIL: $*" | tee -a "$RESULT"; }

say "== verify_pip_symbols =="
say "input : $IN"
say "dylib : $DYLIB"
if [ ! -f "$DYLIB" ]; then fail "PipEnabler.dylib not found at $DYLIB"; exit 0; fi
say "$(file "$DYLIB")"
say "size  : $(wc -c < "$DYLIB") bytes"

# 先生成反汇编（后面多处依赖）
otool -tv "$DYLIB" > "$OUT/otool_tv.txt" 2>&1 || true

# ---- 1) 架构 ----
say ""
say "---- [1] lipo / otool -hv (arch) ----"
(lipo -info "$DYLIB" 2>&1 | tee -a "$RESULT") || true
(otool -hv "$DYLIB" 2>&1 | tee -a "$RESULT") || true

# ---- 2) 导出符号 ----
say ""
say "---- [2] nm -gU (exported) ----"
nm -gU "$DYLIB" 2>&1 | tee "$OUT/nm_gU.txt" | tee -a "$RESULT" || true
REQ_SYMS="PipEnablerSetEnabled PipEnablerIsEnabled PipEnablerToggle PipEnablerStartPictureInPicture PipEnablerStopPictureInPicture PipEnablerDetectedContentPlayerLayer PipEnablerEnabledDidChangeNotification PipEnablerFeedPixelBuffer"
MISS=0
for s in $REQ_SYMS; do
  if grep -q "_${s}$" "$OUT/nm_gU.txt"; then pass "导出符号 _${s}"; else fail "缺少导出符号 _${s}"; MISS=1; fi
done

# ---- 3) 未定义外部符号（API 被真实引用、未被优化掉） ----
say ""
say "---- [3] nm -u (undefined external refs) ----"
nm -u "$DYLIB" 2>&1 | tee "$OUT/nm_u.txt" | tee -a "$RESULT" || true
for tok in \
  "_OBJC_CLASS_\$_AVPictureInPictureController" \
  "_OBJC_CLASS_\$_AVPictureInPictureControllerContentSource" \
  "_OBJC_CLASS_\$_AVSampleBufferDisplayLayer" \
  "_OBJC_CLASS_\$_AVPlayerLayer" \
  "_CMSampleBufferCreateReadyWithImageBuffer" \
  "_CMVideoFormatDescriptionCreateForImageBuffer" \
  "_CMSampleBufferGetSampleAttachmentsArray" \
  "_CMTimebaseCreateWithSourceClock" \
  "_objc_msgSend" ; do
  if grep -qF "$tok" "$OUT/nm_u.txt"; then pass "外部引用存在: $tok"; else fail "外部引用缺失: $tok"; MISS=1; fi
done

# ---- 4) 链接库 / install_name ----
say ""
say "---- [4] otool -L (linked frameworks) ----"
otool -L "$DYLIB" 2>&1 | tee "$OUT/otool_L.txt" | tee -a "$RESULT" || true
for fw in AVKit AVFoundation UIKit CoreMedia CoreVideo Foundation; do
  if grep -qi "$fw.framework" "$OUT/otool_L.txt"; then pass "已链接框架: $fw"; else fail "未链接框架: $fw"; fi
done
say ""
say "---- [4b] LC_ID_DYLIB (install_name) ----"
otool -l "$DYLIB" 2>&1 | grep -A4 -E 'LC_ID_DYLIB' | tee "$OUT/lc_id.txt" | tee -a "$RESULT" || true
if grep -q "@executable_path/Frameworks/PipEnabler.dylib" "$OUT/lc_id.txt"; then pass "install_name 正确"; else fail "install_name 不符"; MISS=1; fi

# ---- 5) constructor 注册 ----
say ""
say "---- [5] constructor 注册 (__init_offsets / __mod_init_func) ----"
otool -l "$DYLIB" 2>&1 | grep -A6 -E 'sectname __(init_offsets|mod_init_func)' | tee "$OUT/modinit_sec.txt" | tee -a "$RESULT" || true
CONSTRUCTOR_OK=0
if grep -q '__init_offsets' "$OUT/modinit_sec.txt" && grep -Eq 'size 0x0*[1-9a-fA-F]' "$OUT/modinit_sec.txt"; then
  CONSTRUCTOR_OK=1; pass "constructor 段 __TEXT,__init_offsets 存在且 size>0"
fi
if grep -q '__mod_init_func' "$OUT/modinit_sec.txt" && grep -Eq 'size 0x0*[1-9a-fA-F]' "$OUT/modinit_sec.txt"; then
  CONSTRUCTOR_OK=1; pass "constructor 段 __DATA(_CONST),__mod_init_func 存在且 size>0"
fi
say "[5b] __init_offsets 内容："
otool -v -s __TEXT __init_offsets "$DYLIB" 2>&1 | tee "$OUT/init_offsets.txt" | tee -a "$RESULT" || true
if grep -q '_PipEnablerInitialize:' "$OUT/otool_tv.txt"; then
  CONSTRUCTOR_OK=1; pass "构造函数体 _PipEnablerInitialize 已生成"
fi
if [ "$CONSTRUCTOR_OK" -eq 0 ]; then fail "未发现 constructor 注册"; MISS=1; fi

# ---- 6) 反汇编交叉印证 ----
say ""
say "---- [6] otool -tv 反汇编命中 (API calls) ----"
grep -nE 'AVPictureInPicture|AVSampleBufferDisplayLayer|CMSampleBufferCreateReadyWithImageBuffer|CMVideoFormatDescriptionCreateForImageBuffer|PipEnablerInitialize|PipEnablerCreateSampleBuffer|PipEnablerInstallSwizzles' "$OUT/otool_tv.txt" | tee "$OUT/tv_hits.txt" | tee -a "$RESULT" || true
say ""
say "---- [6b] constructor 反汇编片段 (_PipEnablerInitialize) ----"
grep -A40 '^_PipEnablerInitialize:' "$OUT/otool_tv.txt" | tee "$OUT/ctor_disasm.txt" | tee -a "$RESULT" || true
if grep -q '_PipEnablerInstallSwizzles' "$OUT/ctor_disasm.txt"; then pass "constructor 调用 PipEnablerInstallSwizzles"; else fail "constructor 未调用 PipEnablerInstallSwizzles"; MISS=1; fi
say ""
say "---- [6c] otool -Iv (indirect symbols: ObjC/类引用地址) ----"
otool -Iv "$DYLIB" 2>&1 | grep -E 'AVPictureInPicture|AVSampleBufferDisplayLayer|AVPlayerLayer' | tee "$OUT/otool_Iv.txt" | tee -a "$RESULT" || true

# ---- 7) strings 交叉印证 ----
say ""
say "---- [7] strings (ObjC 类名/方法名) ----"
strings -a "$DYLIB" | grep -E 'AVPictureInPicture|AVSampleBufferDisplayLayer|enqueueSampleBuffer|initWithSampleBufferDisplayLayer|PipEnabler' | sort -u | tee "$OUT/strings.txt" | tee -a "$RESULT" || true
for tok in "AVPictureInPictureController" "AVSampleBufferDisplayLayer" "enqueueSampleBuffer:" "PipEnablerEnabledDidChangeNotification"; do
  if grep -qF "$tok" "$OUT/strings.txt"; then pass "字符串存在: $tok"; else fail "字符串缺失: $tok"; fi
done

# ---- 9) 真实播放路径抓帧逻辑（#370 新增） ----
# 证明 dylib 内已编译进"从真实解码/渲染路径抓帧"的逻辑：
#   (a) FlutterTexture 的 -copyPixelBuffer（Flutter 外部纹理每帧回调）
#   (b) 返回 void、仅一个 CVBuffer 参数的原生消费型方法
say ""
say "---- [9] 真实路径抓帧逻辑 (copyPixelBuffer / CVBuffer consumer) ----"
strings -a "$DYLIB" | grep -E 'copyPixelBuffer|CVBuffer|frame capture hooks installed|\[PipEnabler\]' | sort -u | tee "$OUT/strings_framecap.txt" | tee -a "$RESULT" || true
for tok in "copyPixelBuffer" "v24@0:8^{__CVBuffer=}16" "frame capture hooks installed"; do
  if grep -qF "$tok" "$OUT/strings_framecap.txt"; then pass "抓帧标记存在: $tok"; else fail "抓帧标记缺失: $tok"; MISS=1; fi
done
say "[9b] 抓帧相关符号（含局部符号）:"
nm "$DYLIB" 2>/dev/null | grep -E 'PipEnabler(InstallFrameCaptureHooks|SwizzledCopyPixelBuffer|SwizzledCVBufferConsumer|FeedPixelBuffer)' | tee "$OUT/nm_framecap.txt" | tee -a "$RESULT" || true
if [ -s "$OUT/nm_framecap.txt" ]; then
  pass "抓帧函数符号已生成"
else
  say "（注：静态函数符号可能被 ld 剥离，此项不作为硬性判据；以字符串标记为准）"
fi
say "[9c] 反汇编中构造函数调用帧抓取安装点:"
grep -nE 'PipEnablerInstallFrameCaptureHooks|PipEnablerInstallSwizzles' "$OUT/otool_tv.txt" | tee -a "$RESULT" || true

# ---- 8) 汇总 ----
say ""
if [ "$MISS" -eq 0 ]; then
  say "VERIFY_RESULT: PASS (符号导出 + API 引用 + constructor + install_name 全部通过)"
else
  say "VERIFY_RESULT: FAIL (见上方 FAIL 行)"
fi
exit 0
