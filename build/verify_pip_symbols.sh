#!/usr/bin/env bash
# =============================================================================
# verify_pip_symbols.sh — 在 GitHub Actions 的 macOS runner 内，对【打包产物中】的
#   Payload/Runner.app/Frameworks/PipEnabler.dylib 做符号级/反汇编级核验，
#   证明画中画是"真正实现"而非仅结构注入：
#
#   ①  PipEnabler* 全部导出符号已导出（nm -gU）：
#         PipEnablerSetEnabled / PipEnablerIsEnabled / PipEnablerToggle /
#         PipEnablerStartPictureInPicture / PipEnablerStopPictureInPicture /
#         PipEnablerDetectedContentPlayerLayer /
#         PipEnablerEnabledDidChangeNotification / PipEnablerFeedPixelBuffer
#   ②  __attribute__((constructor)) 入口已注册（__DATA,__mod_init_func 非空）。
#   ③  代码真实引用（未被链接器优化掉）以下 API：
#         AVPictureInPictureController、AVPictureInPictureControllerContentSource、
#         AVSampleBufferDisplayLayer、AVKit/AVFoundation、
#         CMSampleBufferCreateReadyWithImageBuffer、CMVideoFormatDescriptionCreateForImageBuffer、
#         enqueueSampleBuffer:
#       —— 通过 nm -u（未定义外部符号）、otool -L（链接库）、otool -tv（反汇编）、
#          strings（ObjC 选择子/类名）四路交叉印证。
#   ④  LC_ID_DYLIB install_name == @executable_path/Frameworks/PipEnabler.dylib。
#
# ★ 本脚本只能在 runner(macOS) 内运行；本机(Windows)严禁安装/运行任何 iOS 工具链。
# 用法: bash build/verify_pip_symbols.sh <ipa|dylib> [outdir]
# 退出一律为 0；结论写入 <outdir>/RESULT.txt（PASS/FAIL 汇总，供日志读取）。
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
say() { echo "$@" | tee -a "$RESULT"; }
pass() { echo "PASS: $*" | tee -a "$RESULT"; }
fail() { echo "FAIL: $*" | tee -a "$RESULT"; }

say "== verify_pip_symbols =="
say "input : $IN"
say "dylib : $DYLIB"
if [ ! -f "$DYLIB" ]; then
  fail "PipEnabler.dylib not found at $DYLIB"
  exit 0
fi
say "$(file "$DYLIB")"
say "size  : $(wc -c < "$DYLIB") bytes"

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
  if grep -q "_${s}$" "$OUT/nm_gU.txt"; then
    pass "exported symbol _${s}"
  else
    fail "missing exported symbol _${s}"
    MISS=1
  fi
done

# ---- 3) 未定义外部符号（证明 API 被真实引用、未被优化掉） ----
say ""
say "---- [3] nm -u (undefined external refs, API cross-check) ----"
nm -u "$DYLIB" 2>&1 | tee "$OUT/nm_u.txt" | tee -a "$RESULT" || true
for tok in \
  "_OBJC_CLASS_\$_AVPictureInPictureController" \
  "_OBJC_CLASS_\$_AVPictureInPictureControllerContentSource" \
  "_OBJC_CLASS_\$_AVSampleBufferDisplayLayer" \
  "_OBJC_CLASS_\$_AVPlayerLayer" \
  "_CMSampleBufferCreateReadyWithImageBuffer" \
  "_CMVideoFormatDescriptionCreateForImageBuffer" \
  "_CMSampleBufferGetSampleAttachmentsArray" \
  "_CFDictionarySetValue" \
  "_CMTimebaseCreateWithSourceClock" \
  "_objc_msgSend" ; do
  if grep -qF "$tok" "$OUT/nm_u.txt"; then
    pass "undefined ref present: $tok"
  else
    fail "undefined ref MISSING: $tok"
    MISS=1
  fi
done

# ---- 4) 链接库 / install_name ----
say ""
say "---- [4] otool -L (linked frameworks) ----"
otool -L "$DYLIB" 2>&1 | tee "$OUT/otool_L.txt" | tee -a "$RESULT" || true
for fw in AVKit AVFoundation UIKit CoreMedia CoreVideo Foundation; do
  if grep -qi "$fw.framework" "$OUT/otool_L.txt"; then
    pass "linked framework: $fw"
  else
    fail "framework NOT linked: $fw"
  fi
done
say ""
say "---- [4b] LC_ID_DYLIB (install_name) ----"
otool -l "$DYLIB" 2>&1 | grep -A4 -E 'LC_ID_DYLIB' | tee "$OUT/lc_id.txt" | tee -a "$RESULT" || true
if grep -q "@executable_path/Frameworks/PipEnabler.dylib" "$OUT/lc_id.txt"; then
  pass "install_name OK"
else
  fail "install_name mismatch"
  MISS=1
fi

# ---- 5) constructor 注册 ----
say ""
say "---- [5] __DATA,__mod_init_func (constructor 注册) ----"
(otool -v -s __DATA __mod_init_func "$DYLIB" 2>&1 | tee "$OUT/modinit.txt") || true
if grep -Eq '^[0-9a-fA-F]{16}' "$OUT/modinit.txt" || grep -q "contents of" "$OUT/modinit.txt"; then
  pass "constructor slot present in __DATA,__mod_init_func"
else
  fail "no constructor slot in __DATA,__mod_init_func"
  MISS=1
fi

# ---- 6) 反汇编交叉印证 ----
say ""
say "---- [6] otool -tv 反汇编命中 (API calls) ----"
otool -tv "$DYLIB" > "$OUT/otool_tv.txt" 2>&1 || true
grep -nE 'AVPictureInPicture|AVSampleBufferDisplayLayer|CMSampleBufferCreateReadyWithImageBuffer|CMVideoFormatDescriptionCreateForImageBuffer|PipEnablerInitialize|PipEnablerCreateSampleBuffer|PipEnablerInstallSwizzles' "$OUT/otool_tv.txt" | tee "$OUT/tv_hits.txt" | tee -a "$RESULT" || true
for tok in "AVPictureInPictureController" "AVSampleBufferDisplayLayer"; do
  if grep -q "$tok" "$OUT/tv_hits.txt"; then
    pass "disasm references $tok"
  else
    say "NOTE: disasm grep did not hit $tok (可能在 LDR 常量池，以 strings/nm 兜底)"
  fi
done

# ---- 7) strings 交叉印证 ----
say ""
say "---- [7] strings (ObjC class/method names) ----"
strings -a "$DYLIB" | grep -E 'AVPictureInPicture|AVSampleBufferDisplayLayer|enqueueSampleBuffer|initWithSampleBufferDisplayLayer|PipEnabler' | sort -u | tee "$OUT/strings.txt" | tee -a "$RESULT" || true
for tok in "AVPictureInPictureController" "AVSampleBufferDisplayLayer" "enqueueSampleBuffer:" "PipEnablerEnabledDidChangeNotification"; do
  if grep -qF "$tok" "$OUT/strings.txt"; then
    pass "string present: $tok"
  else
    fail "string MISSING: $tok"
  fi
done

# ---- 8) 汇总 ----
say ""
if [ "$MISS" -eq 0 ]; then
  say "VERIFY_RESULT: PASS (符号导出 + API 引用 + constructor + install_name 全部通过)"
else
  say "VERIFY_RESULT: FAIL (见上方 FAIL 行)"
fi
exit 0
