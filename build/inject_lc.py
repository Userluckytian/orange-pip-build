#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inject_lc.py — 向已解密的 thin arm64 Mach-O（Runner 主二进制）追加一条
               LC_LOAD_WEAK_DYLIB 加载命令，指向注入的 PiP 使能 dylib。

设计依据（沿用 i343/lc_headroom.py 的只读探测思路，均在 Windows 本机静态核实）：
  * Runner 主二进制为 thin arm64 little-endian：magic = 0xfeedfacf，size = 19178560。
  * 头部：ncmds=97，sizeofcmds=10640 → load commands 结束于 file offset 10672。
  * __TEXT segment：fileoff=0，filesize=14680064；其首个 section __text fileoff=16384。
  * 因此 load commands 结尾与首个 section 之间存在 16384-10672 = 5712 字节零填充「余量」，
    足以就地写入一条新的加载命令而【无需移动任何已有文件内容、无需改动段/节偏移】。
  * 主二进制 cryptid=0（已由 DumpDecrypter 解密），因此可直接改写；改完由 ldid -S 重新伪签名。

算法：
  1) 校验 magic == 0xfeedfacf（否则拒绝，避免破坏 fat/其它架构）；
  2) 解析现有 load commands，计算 first_section_fileoff，得出余量 headroom；
  3) 若已存在同名加载命令则跳过（幂等）；
  4) 在 lc_end 处就地写入新的 dylib_command（仅覆盖零填充），
     并同步更新 mach_header_64 的 ncmds(+1) 与 sizeofcmds(+cmdsize)。

用法：
  python3 inject_lc.py <path-to-macho> <install_name>
  例：python3 inject_lc.py Runner "@executable_path/Frameworks/PipEnabler.dylib"
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
# 其它 load-dylib 家族（用于幂等检查）
DYLIB_CMDS = {
    0xC: "LC_LOAD_DYLIB",
    0x18: "LC_LOAD_WEAK_DYLIB",
    0x1F: "LC_REEXPORT_DYLIB",
    0x20: "LC_LAZY_LOAD_DYLIB",
    0x80000018: "LC_LOAD_WEAK_DYLIB",
    0x8000001F: "LC_REEXPORT_DYLIB",
    0x80000020: "LC_LAZY_LOAD_DYLIB",
}


def align8(n):
    return (n + 7) & ~7


def find_name(raw, off, cmdsize):
    nameoff = struct.unpack_from("<I", raw, off + 8)[0]
    return bytes(raw[off + nameoff:off + cmdsize]).split(b"\x00")[0]


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: inject_lc.py <macho> <install_name>\n")
        return 2

    path = sys.argv[1]
    install_name = sys.argv[2]
    name_bytes = install_name.encode("utf-8") + b"\x00"

    with open(path, "rb") as fp:
        raw = bytearray(fp.read())

    if len(raw) < 32:
        sys.stderr.write("FATAL: file too small: %d\n" % len(raw))
        return 1

    magic = struct.unpack_from("<I", raw, 0)[0]
    if magic != MH_MAGIC_64:
        sys.stderr.write(
            "FATAL: not a thin 64-bit little-endian Mach-O (magic=%#x). "
            "Py script refuses to touch fat/other-arch binaries.\n" % magic
        )
        return 1

    ncmds = struct.unpack_from("<I", raw, 16)[0]
    sizeofcmds = struct.unpack_from("<I", raw, 20)[0]
    lc_start = 32
    lc_end = 32 + sizeofcmds

    off = lc_start
    first_sect_fileoff = None
    already = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", raw, off)
        if cmdsize <= 0 or off + cmdsize > len(raw):
            sys.stderr.write("FATAL: malformed load command at off=%d\n" % off)
            return 1
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", raw, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                sf = struct.unpack_from("<I", raw, so + 48)[0]
                if sf > 0 and (first_sect_fileoff is None or sf < first_sect_fileoff):
                    first_sect_fileoff = sf
                so += 80
        elif cmd in DYLIB_CMDS:
            if find_name(raw, off, cmdsize) == install_name.encode("utf-8"):
                already = True
        off += cmdsize

    if already:
        print("[inject_lc] already present, skip: %s" % install_name)
        return 0

    if first_sect_fileoff is None:
        # 退路：没有可定位 section 时，用 __TEXT segment 的 filesize 作为边界
        first_sect_fileoff = len(raw)

    headroom = first_sect_fileoff - lc_end
    cmdsize = align8(24 + len(name_bytes))
    if cmdsize > headroom:
        sys.stderr.write(
            "FATAL: insufficient headroom: need %d bytes, have %d "
            "(lc_end=%d first_sect_fileoff=%d)\n"
            % (cmdsize, headroom, lc_end, first_sect_fileoff)
        )
        return 1

    # 组装 dylib_command：cmd(4)+cmdsize(4)+name_offset(4)+timestamp(4)
    #                    +current_version(4)+compatibility_version(4) = 24 字节，随后是路径串
    cmd = bytearray(cmdsize)
    struct.pack_into("<II", cmd, 0, LC_LOAD_WEAK_DYLIB, cmdsize)
    struct.pack_into("<I", cmd, 8, 24)          # name offset (相对本命令起始)
    struct.pack_into("<I", cmd, 12, 0)          # timestamp
    struct.pack_into("<I", cmd, 16, 0x10000)    # current version 1.0.0
    struct.pack_into("<I", cmd, 20, 0x10000)    # compatibility version 1.0.0
    cmd[24:24 + len(name_bytes)] = name_bytes

    # 就地写入零填充区（不移动任何已有内容）
    raw[lc_end:lc_end + cmdsize] = cmd
    struct.pack_into("<I", raw, 16, ncmds + 1)
    struct.pack_into("<I", raw, 20, sizeofcmds + cmdsize)

    with open(path, "wb") as fp:
        fp.write(raw)

    print(
        "[inject_lc] injected %s (cmdsize=%d, headroom_was=%d) "
        "new ncmds=%d sizeofcmds=%d"
        % (install_name, cmdsize, headroom, ncmds + 1, sizeofcmds + cmdsize)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
