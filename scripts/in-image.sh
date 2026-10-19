#!/bin/sh
# 在 arm64 容器内执行（qemu 模拟），给 MU300 OpenWrt rootfs 加装插件并打署名。
# 由 .github/workflows/build-lhhc.yml 调用，不单独使用。
set -eu

LHHC_TAG=${LHHC_TAG:-lhhc_02}
UPSTREAM_RELEASE=${UPSTREAM_RELEASE:-unknown}
OUT=${OUT:-mu300-openwrt-luci-rootfs.tar.gz}
WITH_CORE=${WITH_CORE:-1}
BUILD_TIME=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

step() { printf '\n########## %s ##########\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
opt_add() { for p in "$@"; do apk add "$p" >/dev/null 2>&1 || warn "可选包 $p 未安装（跳过）"; done; }

mkdir -p /var/lock /var/run /tmp

step "0/12 环境自检"
[ -f /etc/openwrt_release ] || die "不是 OpenWrt rootfs"
. /etc/openwrt_release
[ "$DISTRIB_ARCH" = "aarch64_generic" ] || die "架构不符：$DISTRIB_ARCH（安装器要求 aarch64_generic）"
[ -f /opt/mu300/bin/mu300-next-boot ] || die "缺少 MU300 组件，这不是官方项目 rootfs"
[ -d /usr/share/rpcd/acl.d ] && [ -f /usr/share/rpcd/acl.d/luci-app-mu300.json ] \
    || die "缺少 MU300 控制面板，请用 openwrt-luci 版 rootfs"
KREL=$(ls /lib/modules 2>/dev/null | grep -v '^6\.' | head -n 1)
[ -n "$KREL" ] || die "/lib/modules 下找不到厂商内核模块目录"
echo "基础系统 : $DISTRIB_DESCRIPTION"
echo "厂商内核 : $KREL"
echo "署名字段 : $LHHC_TAG"
echo "上游发布 : $UPSTREAM_RELEASE"

step "1/12 刷新 apk 索引并升级到 release 分支最新"
apk update >/dev/null
apk upgrade >/dev/null
echo "apk 版本: $(apk --version)"
echo "内核模块目录（升级后）: $(ls /lib/modules | tr '\n' ' ')"

step "2/12 dnsmasq 换成 dnsmasq-full（OpenClash/AdGuard 依赖）"
cp -a /etc/config/dhcp /tmp/dhcp.keep 2>/dev/null || true
if apk info -e dnsmasq >/dev/null 2>&1; then
    apk del dnsmasq >/dev/null
fi
apk add dnsmasq-full >/dev/null
[ -f /etc/config/dhcp ] || cp -a /tmp/dhcp.keep /etc/config/dhcp 2>/dev/null || true
[ -f /etc/config/dhcp ] || die "/etc/config/dhcp 丢失"
echo "dnsmasq-full: $(apk info -v dnsmasq-full 2>/dev/null | head -n 1)"

step "3/12 基础依赖"
apk add curl unzip ruby ca-bundle ip-full bash >/dev/null
opt_add ruby-yaml          # OpenClash 的 yaml 处理依赖
echo "ruby: $(ruby --version 2>/dev/null || echo 缺失)"

step "4/12 Tailscale + LuCI"
apk add tailscale >/dev/null
command -v tailscale >/dev/null || die "tailscale 未安装成功"
opt_add luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn
echo "tailscale: $(tailscale version 2>/dev/null | head -n 1)"

step "5/12 AdGuardHome + LuCI"
apk add adguardhome >/dev/null
command -v AdGuardHome >/dev/null || die "adguardhome 未安装成功"
opt_add luci-app-adguardhome luci-i18n-adguardhome-zh-cn
echo "AdGuardHome: $(AdGuardHome --version 2>/dev/null | head -n 1)"

step "6/12 OpenClash（官方 .apk 安装包）"
[ -s /assets/luci-app-openclash.apk ] || die "缺少 /assets/luci-app-openclash.apk"
apk add --allow-untrusted /assets/luci-app-openclash.apk >/dev/null
[ -x /etc/init.d/openclash ] || die "OpenClash 安装后没有 /etc/init.d/openclash"
echo "OpenClash: $(grep -m1 '^Version:' /usr/share/openclash/openclash_version 2>/dev/null || echo 已安装)"

step "7/12 lucky（静态 arm64 二进制 + procd 服务）"
[ -s /assets/lucky.tar.gz ] || die "缺少 /assets/lucky.tar.gz"
rm -rf /tmp/lucky && mkdir -p /tmp/lucky
tar -xzf /assets/lucky.tar.gz -C /tmp/lucky
[ -f /tmp/lucky/lucky ] || die "lucky 压缩包里没有 lucky 可执行文件"
cp -f /tmp/lucky/lucky /usr/bin/lucky
chmod 0755 /usr/bin/lucky
mkdir -p /etc/lucky /var/log/lucky
cp -f /assets/lucky-init.d /etc/init.d/lucky
chmod 0755 /etc/init.d/lucky
# 构建容器里没有 ubus，rc.common 的 enable 不可用：直接建启动链接（与上游 build-rootfs.sh 同法）
LSTART=$(sed -n 's/^START=//p' /etc/init.d/lucky)
[ -n "$LSTART" ] || LSTART=99
ln -sf ../init.d/lucky /etc/rc.d/S${LSTART}lucky
echo "lucky: $(/usr/bin/lucky -v 2>&1 | head -n 1 || echo 已安装)"

step "8/12 预置 mihomo 内核（OpenClash 用）"
if [ "$WITH_CORE" = "1" ] && [ -s /assets/mihomo.gz ]; then
    mkdir -p /etc/openclash/core
    gzip -dc /assets/mihomo.gz > /etc/openclash/core/clash_meta
    chmod 0755 /etc/openclash/core/clash_meta
    [ -s /etc/openclash/core/clash_meta ] || die "mihomo 内核写入失败"
    echo "mihomo 内核: $(/etc/openclash/core/clash_meta -v 2>&1 | head -n 1 || echo 已写入)"
else
    warn "未预置 mihomo 内核，首次进 OpenClash 网页时在线下载"
fi

step "9/12 服务默认状态"
# 需要用户自己填配置的服务默认不自启，避免首启抢占 53 端口或空跑
for s in tailscale openclash adguardhome; do
    rm -f /etc/rc.d/S*"$s" 2>/dev/null || true
    echo "  $s: 默认不启动（进 LuCI 配置后手动启用）"
done
echo "  lucky: 默认启动（独立端口 16601，不影响路由）"

step "10/12 写入署名字段"
# DISTRIB_RELEASE 保持 25.12.5：安装器把它当版本号，改了会影响识别与后续升级流程
sed -i "s|^DISTRIB_DESCRIPTION=.*|DISTRIB_DESCRIPTION='OpenWrt $DISTRIB_RELEASE $LHHC_TAG'|" /etc/openwrt_release
grep -q '^DISTRIB_LHHC=' /etc/openwrt_release || echo "DISTRIB_LHHC='$LHHC_TAG'" >> /etc/openwrt_release
sed -i "s|^PRETTY_NAME=.*|PRETTY_NAME=\"OpenWrt $DISTRIB_RELEASE $LHHC_TAG\"|" /etc/os-release

cat >> /etc/banner <<EOF

 ------------------------------------------------------------
  $LHHC_TAG  |  based on MU300 $UPSTREAM_RELEASE
  plugins: tailscale openclash lucky adguardhome
  built  : $BUILD_TIME
 ------------------------------------------------------------
EOF

mkdir -p /etc/mu300
cat > /etc/mu300/lhhc-build <<EOF
tag=$LHHC_TAG
upstream=$UPSTREAM_RELEASE
openwrt=$DISTRIB_RELEASE
arch=$DISTRIB_ARCH
kernel_modules=$KREL
built=$BUILD_TIME
plugins=tailscale,luci-app-tailscale-community,luci-app-openclash,lucky,adguardhome,luci-app-adguardhome,dnsmasq-full
EOF
echo "DISTRIB_LHHC=$(grep '^DISTRIB_LHHC=' /etc/openwrt_release | cut -d= -f2)"

step "11/12 清理"
# OpenWrt 6.12 的 kmod 是 apk 依赖顺带装进来的，本机用 5.4 厂商内核，整目录删除（同上游做法）
rm -rf /lib/modules/6.*
rm -rf /var/cache/apk/* /tmp/lucky /tmp/dhcp.keep
rm -rf /boot
echo "剩余内核模块目录: $(ls /lib/modules | tr '\n' ' ')"

step "12/12 打包"
R=/build/root
rm -rf "$R" && mkdir -p "$R"
for e in /*; do
    case "$e" in
        /proc|/sys|/dev|/build|/assets|/out|/tmp|/in-image.sh) continue ;;
    esac
    cp -a "$e" "$R/"
done
mkdir -p "$R/proc" "$R/sys" "$R/dev" "$R/tmp" "$R/run"
# docker 会把宿主的 resolv.conf / hosts / hostname 挂进来，恢复 OpenWrt 自己的
ln -sf /tmp/resolv.conf "$R/etc/resolv.conf"
printf '127.0.0.1\tlocalhost\n\n::1\tlocalhost ip6-localhost ip6-loopback\nff02::1\tip6-allnodes\nff02::2\tip6-allrouters\n' > "$R/etc/hosts"
printf 'mu300\n' > "$R/etc/hostname"

# 终检：安装器 Firmware.py 的硬性要求
[ -x "$R/sbin/init" ] || die "缺少 sbin/init"
[ -f "$R/opt/mu300/bin/mu300-next-boot" ] || die "缺少 opt/mu300/bin/mu300-next-boot"
[ -f "$R/opt/mu300/bin/mobile-data" ] || die "缺少 opt/mu300/bin/mobile-data"
[ -f "$R/usr/share/rpcd/acl.d/luci-app-mu300.json" ] || die "缺少 MU300 面板 ACL"
grep -q "DISTRIB_ARCH='aarch64_generic'" "$R/etc/openwrt_release" || die "DISTRIB_ARCH 被改坏"
grep -q "$LHHC_TAG" "$R/etc/openwrt_release" || die "署名字段没写进 openwrt_release"
[ -x "$R/usr/bin/lucky" ] || die "lucky 未进入镜像"
[ -x "$R/usr/sbin/AdGuardHome" ] || [ -x "$R/usr/bin/AdGuardHome" ] || die "AdGuardHome 未进入镜像"
[ -f "$R/etc/init.d/openclash" ] || die "OpenClash 未进入镜像"

apk list --installed 2>/dev/null | sort > "$R/etc/mu300/packages.txt" || true

cd "$R"
tar -czf "/out/$OUT" .
ls -la "/out/$OUT"
echo "打包完成：/out/$OUT"
