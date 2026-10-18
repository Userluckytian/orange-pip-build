#!/usr/bin/env bash
# =============================================================================
# inject_and_pack.sh — 注入 PiP 使能 dylib、伪签名并重新打包成新 IPA
#
# ★ 只允许在 GitHub Actions 的 macOS runner 内执行；严禁在本机(Windows)运行，
#   本脚本会调用 ldid/clang/zip 等 iOS 工具链，本机不得安装它们。★
#
# 步骤：
#   0) 前置：patch_plist.py 修改 Info.plist（去 UIRequiresFullScreen、补 UIBackgroundModes=audio）
#   1) 把 PipEnabler.dylib 拷入 <App>.app/Frameworks/
#   2) 用 inject_lc.py 向主二进制 load command 表头追加
#        LC_LOAD_WEAK_DYLIB @executable_path/Frameworks/<name>
#      （主二进制已解密、cryptid=0、表头有 5712 字节余量，就地写入，不移动内容）
#   3) ldid -S 对主二进制 / 所有 .dylib / 所有 .framework 主二进制做伪签名
#   4) 将 <App>.app 重新 zip 成新 IPA
#
# 用法：
#   bash inject_and_pack.sh <Runner.app> <path-to-dylib> [dylib-install-name] [ipla-name]
# 环境变量：
#   OUT_DIR   输出目录（默认 <script_dir>/output）
#   SKIP_PLIST=1  跳过 Info.plist 修补（默认会在脚本内再跑一次 patch_plist.py，幂等）
# =============================================================================
set -euo pipefail

APP="${1:?usage: inject_and_pack.sh <App>.app <path-to-dylib> [install-name] [ipa-name]}"
DYLIB_SRC="${2:?missing path-to-dylib}"
DYLIB_NAME="${3:-$(basename "$DYLIB_SRC")}"
IPA_NAME="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/output}"

if [ ! -d "$APP" ]; then
  echo "FATAL: app bundle not found: $APP" >&2
  exit 1
fi
if [ ! -f "$DYLIB_SRC" ]; then
  echo "FATAL: dylib not found: $DYLIB_SRC" >&2
  exit 1
fi

# ---- 0) Info.plist 修补（幂等；可 SKIP_PLIST=1 跳过） ----
if [ "${SKIP_PLIST:-0}" != "1" ]; then
  echo "==> [0/4] patch Info.plist"
  python3 "$SCRIPT_DIR/patch_plist.py" "$APP/Info.plist"
fi

# ---- 解析主可执行文件名 ----
MAIN_BIN_NAME="$(python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleExecutable", "Runner"))
PY
)"
MAIN_BIN="$APP/$MAIN_BIN_NAME"
if [ ! -f "$MAIN_BIN" ]; then
  echo "FATAL: main binary not found: $MAIN_BIN" >&2
  exit 1
fi
echo "==> main executable: $MAIN_BIN"

# ---- 1) 拷贝 dylib 到 Frameworks/ ----
echo "==> [1/4] stage dylib into Frameworks/"
mkdir -p "$APP/Frameworks"
cp -f "$DYLIB_SRC" "$APP/Frameworks/$DYLIB_NAME"
chmod 0755 "$APP/Frameworks/$DYLIB_NAME"

INSTALL_NAME="@executable_path/Frameworks/$DYLIB_NAME"

# ---- 2) 注入 LC_LOAD_WEAK_DYLIB ----
echo "==> [2/4] inject $INSTALL_NAME"
python3 "$SCRIPT_DIR/inject_lc.py" "$MAIN_BIN" "$INSTALL_NAME"

# ---- ldid 可用性（仅 runner 内安装） ----
if ! command -v ldid >/dev/null 2>&1; then
  echo "==> ldid not found; installing (runner-only)"
  if command -v brew >/dev/null 2>&1; then
    brew install ldid
  else
    echo "FATAL: ldid missing and no brew; cannot pseudo-sign" >&2
    exit 1
  fi
fi
LDID="$(command -v ldid)"

# ---- 3) 伪签名（主二进制 / dylib / 各 framework 主二进制） ----
echo "==> [3/4] pseudo-sign (ldid -S)"
# 3a. 所有 .dylib
find "$APP" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' f; do
  echo "    ldid -S $f"
  "$LDID" -S "$f"
done
# 3b. 所有 .framework 内的主二进制
find "$APP" -type d -name '*.framework' -print0 | while IFS= read -r -d '' fw; do
  fwbin="$fw/$(basename "$fw" .framework)"
  if [ -f "$fwbin" ]; then
    echo "    ldid -S $fwbin"
    "$LDID" -S "$fwbin"
  fi
done
# 3c. 主可执行文件（最后签，覆盖注入后的改动）
echo "    ldid -S $MAIN_BIN"
"$LDID" -S "$MAIN_BIN"

# app 内其它可执行 Mach-O（App.framework 等已被 3b 覆盖；此处兜底 Mach-O 可执行文件）
find "$APP" -type f -perm -111 -print0 | while IFS= read -r -d '' f; do
  case "$f" in
    *.dylib) : ;;                       # 已签
    "$MAIN_BIN") : ;;                   # 已签
  esac
  if [ "$f" != "$MAIN_BIN" ] && [ "${f##*.}" != "dylib" ]; then
    # 仅对确为 Mach-O 的文件补签（file 命令判断，避免误签脚本/资源）
    if file -b "$f" | grep -qi "Mach-O"; then
      echo "    ldid -S $f"
      "$LDID" -S "$f" || true
    fi
  fi
done

# ---- 4) 重新打包为 IPA ----
echo "==> [4/4] repack IPA"
APP_BASE="$(basename "$APP" .app)"
DEFAULT_IPA="${APP_BASE}-pip.ipa"
IPA_FILE="$OUT_DIR/${IPA_NAME:-$DEFAULT_IPA}"

rm -rf "$OUT_DIR/Payload"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/Payload/"
# 清掉旧 IPA 再打包
rm -f "$IPA_FILE"
( cd "$OUT_DIR" && zip -qry "$IPA_FILE" Payload )

echo "==> DONE: $IPA_FILE"
ls -lh "$IPA_FILE"
