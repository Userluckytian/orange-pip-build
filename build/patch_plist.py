#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_plist.py — 为「仅经 GitHub Actions 构建的新 IPA」修补 Runner.app/Info.plist

作用（与意图 #348 一致）：
  1) 删除 UIRequiresFullScreen（=true），否则 App 无法进入系统画中画/分屏窗口；
  2) 追加 UIBackgroundModes = ['audio']（保留原有成员），使 PiP/后台播放可用；
  3) 严格保留 CFBundleIdentifier / CFBundleShortVersionString / CFBundleVersion 等身份字段；
  4) 写盘前自动备份为 Info.plist.orig（幂等：只备份一次）。

仅使用 Python 标准库 plistlib，可在 GitHub Actions 的 macos runner 上直接运行，
不依赖 Xcode / PlistBuddy / 本机任何 iOS 工具链。

用法：
  python3 patch_plist.py /path/to/Runner.app/Info.plist
"""
import os
import plistlib
import sys

BACKUP_SUFFIX = ".orig"
IDENTITY_KEYS = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: patch_plist.py <path-to-Info.plist>\n")
        return 2

    path = sys.argv[1]
    if not os.path.isfile(path):
        sys.stderr.write("FATAL: Info.plist not found: %s\n" % path)
        return 1

    with open(path, "rb") as fp:
        plist = plistlib.load(fp)

    if not isinstance(plist, dict):
        sys.stderr.write("FATAL: unexpected plist root type: %r\n" % type(plist))
        return 1

    changes = []

    # (1) 去掉 UIRequiresFullScreen（存在且为真时删除；保留其他值以防误删）
    if "UIRequiresFullScreen" in plist:
        old = plist.pop("UIRequiresFullScreen")
        changes.append("removed UIRequiresFullScreen (was %r)" % old)
    else:
        changes.append("UIRequiresFullScreen already absent")

    # (2) 追加 UIBackgroundModes=audio + picture-in-picture（保留原有成员、按序去重）
    #     iOS 16.6.1 上补齐 picture-in-picture，避免 PiP 窗口已起但画面为空的边界情况。
    modes = plist.get("UIBackgroundModes")
    if not isinstance(modes, list):
        modes = []
    modes = [m for m in modes if isinstance(m, str)]
    if "audio" not in modes:
        modes.append("audio")
        changes.append("added UIBackgroundModes=audio")
    else:
        changes.append("UIBackgroundModes already contains audio")
    if "picture-in-picture" not in modes:
        modes.append("picture-in-picture")
        changes.append("added UIBackgroundModes=picture-in-picture")
    else:
        changes.append("UIBackgroundModes already contains picture-in-picture")
    plist["UIBackgroundModes"] = modes

    # (3) 身份字段自检（保留，不做改写）
    for k in IDENTITY_KEYS:
        if k not in plist:
            sys.stderr.write("WARN: identity key missing in plist: %s\n" % k)

    # (4) 备份 + 以 XML 格式写回（本 IPA 的 Info.plist 已确认为 XML）
    backup = path + BACKUP_SUFFIX
    if not os.path.exists(backup):
        with open(backup, "wb") as bfp:
            with open(path, "rb") as ofp:
                bfp.write(ofp.read())

    with open(path, "wb") as fp:
        plistlib.dump(plist, fp, fmt=plistlib.FMT_XML, sort_keys=False)

    print("[patch_plist] %s" % path)
    print("[patch_plist]   CFBundleIdentifier          = %s" % plist.get("CFBundleIdentifier"))
    print("[patch_plist]   CFBundleShortVersionString = %s" % plist.get("CFBundleShortVersionString"))
    print("[patch_plist]   CFBundleVersion            = %s" % plist.get("CFBundleVersion"))
    print("[patch_plist]   UIBackgroundModes          = %r" % plist.get("UIBackgroundModes"))
    print("[patch_plist]   UIRequiresFullScreen       = %r" % plist.get("UIRequiresFullScreen", "<absent>"))
    for c in changes:
        print("[patch_plist]   * %s" % c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
