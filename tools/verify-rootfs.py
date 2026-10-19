#!/usr/bin/env python3
"""按 F50 刷机助手（src/Firmware.py）的同一套规则，校验本地 rootfs 能否被安装器接受。

    python verify-rootfs.py mu300-openwrt-luci-lhhc_02-rootfs.tar.gz

只读，不解压到磁盘，不修改任何文件。
"""
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath

OK, BAD, WARN = "[ OK ]", "[FAIL]", "[WARN]"


def field(text, key):
    m = re.search(r"^" + re.escape(key) + r"=[\"']?([^\"'\r\n]+)", text, re.M)
    return m.group(1) if m else ""


def main(argv):
    if len(argv) != 2:
        print("用法: python verify-rootfs.py <rootfs.tar.gz>")
        return 2
    path = Path(argv[1])
    if not path.is_file():
        print(f"{BAD} 文件不存在: {path}")
        return 2
    if not path.name.lower().endswith(".tar.gz"):
        print(f"{BAD} 必须是 .tar.gz")
        return 2

    problems = []
    wanted = {"etc/openwrt_release", "etc/os-release", "usr/lib/os-release", "etc/mu300-system"}
    names, texts, total = set(), {}, 0

    with tarfile.open(path, "r:gz") as ar:
        for item in ar:
            n = item.name
            if n.startswith("/") or ".." in PurePosixPath(n).parts:
                print(f"{BAD} 归档里有不安全路径: {n}")
                return 1
            n = str(PurePosixPath(n))
            total += item.size
            names.add(n)
            if n in wanted and item.isfile() and item.size <= 65536:
                texts[n] = ar.extractfile(item).read().decode("utf-8", "replace")

    print(f"{OK} 归档可读，成员 {len(names)} 个，解压后约 {total / 1048576:.0f} MiB")

    for need in ("opt/mu300/bin/mu300-next-boot", "opt/mu300/bin/mobile-data"):
        (print(f"{OK} 必需品 {need}") if need in names
         else (problems.append(need), print(f"{BAD} 缺 {need}（不是 MU300 项目 rootfs）")))
    (print(f"{OK} sbin/init") if "sbin/init" in names
     else (problems.append("sbin/init"), print(f"{BAD} 缺 sbin/init")))

    if "etc/openwrt_release" not in texts:
        print(f"{BAD} 缺 etc/openwrt_release，安装器无法识别系统")
        return 1

    rel = texts["etc/openwrt_release"]
    arch = field(rel, "DISTRIB_ARCH")
    if arch != "aarch64_generic":
        problems.append("arch")
        print(f"{BAD} DISTRIB_ARCH={arch!r}，安装器要求 aarch64_generic")
    else:
        print(f"{OK} 架构 aarch64_generic")

    luci = (texts.get("etc/mu300-system", "").strip() == "openwrt-luci"
            or "usr/share/rpcd/acl.d/luci-app-mu300.json" in names)
    system = "openwrt-luci" if luci else "openwrt"
    print(f"{OK} 系统类型 {system}，安装器会存为 mu300-{system}-rootfs.tar.gz")

    ver = field(rel, "DISTRIB_RELEASE")
    print(f"{OK} 版本字段 DISTRIB_RELEASE={ver}（助手识别用，定制版应为 25.12.5）")
    desc = field(rel, "DISTRIB_DESCRIPTION")
    print(f"{'  '}     DISTRIB_DESCRIPTION={desc}")
    lhhc = field(rel, "DISTRIB_LHHC")
    print(f"{OK} 署名字段 DISTRIB_LHHC={lhhc}" if lhhc
          else f"{WARN} 没有 DISTRIB_LHHC 字段（不是本流程的产物？）")

    mods = sorted({p.split("/")[2] for p in names
                   if p.startswith("lib/modules/") and len(p.split("/")) > 3})
    print(f"{'  '}     /lib/modules: {mods or '空'}")
    if any(m.startswith("6.") for m in mods):
        print(f"{WARN} 存在 6.x 内核模块目录（OpenWrt 自带 6.12 kmod 没删净，一般无害）")
    vendor = [m for m in mods if not m.startswith("6.")]
    print(f"{OK} 厂商内核模块目录 {vendor}" if vendor
          else f"{BAD} 没有厂商内核模块目录，刷进去开不了机")
    if not vendor:
        problems.append("modules")

    plugins = {
        "tailscale": ["usr/sbin/tailscale", "usr/bin/tailscale"],
        "OpenClash": ["etc/init.d/openclash"],
        "lucky": ["usr/bin/lucky", "etc/init.d/lucky"],
        "AdGuardHome": ["usr/sbin/AdGuardHome", "usr/bin/AdGuardHome"],
        "mihomo 内核": ["etc/openclash/core/clash_meta"],
    }
    for label, cands in plugins.items():
        hit = next((c for c in cands if c in names), None)
        print(f"{OK} 插件 {label}: /{hit}" if hit else f"{WARN} 插件 {label}: 未找到")

    if "etc/mu300/lhhc-build" in names:
        with tarfile.open(path, "r:gz") as ar:
            body = ar.extractfile("etc/mu300/lhhc-build").read().decode("utf-8", "replace")
        print(f"{OK} 构建元数据 /etc/mu300/lhhc-build:")
        for line in body.strip().splitlines():
            print(f"        {line}")
    else:
        print(f"{WARN} 没有 /etc/mu300/lhhc-build")

    size = path.stat().st_size / 1048576
    print(f"{'  '}     文件大小 {size:.1f} MiB（官方约 23 MiB；助手要求设备留 ≥800 MiB）")

    if problems:
        print(f"\n{BAD} 结论：这个包装不进 F50（缺 {', '.join(problems)}）")
        return 1
    print(f"\n{OK} 结论：PASS —— 可以直接在刷机助手里选「本地 rootfs 文件」")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
