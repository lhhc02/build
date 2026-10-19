# MU300 / F50 OpenWrt 定制固件（lhhc 署名版）· GitHub 云编译

给中兴 F50（MU300，紫光展锐 T760）做的 OpenWrt 定制固件，在原项目
[dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux) 的
`openwrt-luci`（OpenWrt 25.12.5 + MU300 控制面板）基础上加装：

| 插件 | 来源 | 默认状态 |
|---|---|---|
| Tailscale | OpenWrt 官方 feed（`tailscale` + `luci-app-tailscale-community` + 中文包） | 装好不自启，登录后手动开 |
| OpenClash | vernesong/OpenClash 官方 `.apk`（含 ruby 依赖） | 装好不自启，配好订阅再开 |
| mihomo 内核 | MetaCubeX/mihomo arm64 | 预置到 `/etc/openclash/core/clash_meta` |
| lucky | gdy666/lucky 静态 arm64 + 自写 procd 服务 | **默认自启**，端口 16601 |
| AdGuardHome | OpenWrt 官方 feed（`adguardhome` + LuCI） | 装好不自启，避免抢 53 端口 |

版本署名字段默认 `lhhc_02`，会写进：LuCI 概览的固件版本、SSH 登录 banner、`/etc/mu300/lhhc-build`。

---

## 1. 为什么是"重组装"而不是"编内核"

原仓库的 OpenWrt 不是从源码 `make menuconfig` 编出来的，它的
`openwrt/build-rootfs.sh` 做的是：**拉官方 `armsr/armv8` rootfs → docker import →
容器里 `apk add` 装包 → 打 tar.gz**。而内核那一步（`upstream/build.sh`）需要先从
真机提取 Android vendor 文件（`android-subset/`、`firmware/`），在云端跑不通。

所以这里走的是**同一条路、更短的一步**：拿官方已发布的 `mu300-openwrt-luci-rootfs.tar.gz`
当底座，在里面 `apk add` 插件，重新打包。好处：

- 20 分钟内出结果，不碰内核、不碰分区、不碰 boot，刷坏的窗口极小
- 产物体积/格式与官方完全一致，安装器的「本地 rootfs」直接认

已核实：5.4 厂商内核里 `tun`、`nft_tproxy`、`nf_socket`、`inet_diag`、`wireguard`
**都是 builtin**，所以 Tailscale 的 TUN、OpenClash 的 TProxy 不需要任何 `kmod`。
apk 顺带拉进来的 6.12 `kmod-*` 会被整目录删掉（与原项目做法一致）。

---

## 2. 上云三步

### 2.1 建仓库

GitHub 上新建一个**空仓库**（Private 也行），名字随意，比如 `mu300-lhhc`。
不需要 fork 上游 —— 本流程不依赖上游仓库里的任何文件。

### 2.2 放文件（两种方式，任选一种）

#### 方式 A：单文件版（推荐，绕开 `.github` 隐藏目录的问题）

本目录的 `.github/workflows/build-lhhc.yml` 就是单文件版：容器内脚本全部内联，
**只需创建这一个文件**，不用管 `scripts/`。

1. 仓库首页 → 右上 **Add file** → **Create new file**
2. 文件名输入框里**直接敲**（斜杠会自动建目录，这是 GitHub 的官方行为）：

   ```
   .github/workflows/build-lhhc.yml
   ```
3. 把本目录 `.github/workflows/build-lhhc.yml` 的全部内容粘进编辑区
4. 底部 **Commit changes**

> 为什么单独提这个：`.github` 是点开头的目录，Windows 资源管理器解压后
> 拖拽上传时常被忽略，结果仓库里只有 `scripts/`，Actions 里根本没有 workflow 可选。
> 用 Create new file 手动敲路径最稳。

#### 方式 B：多文件版（脚本可读，改插件方便）

用 `alt/build-lhhc-multifile.yml` 当 workflow，再把这些一起传上去：

```
alt/build-lhhc-multifile.yml  →  传到 .github/workflows/build-lhhc.yml
scripts/in-image.sh           →  容器内组装脚本
scripts/lucky-init.d          →  lucky 的 procd 服务
tools/verify-rootfs.py        →  本地校验工具（可选）
```

> 两个版本功能完全相同，**同一个仓库里只放一个**，否则 Actions 列表里会出现两个同名 `build-lhhc`。

### 2.3 跑起来

1. 仓库页面 → **Actions** 标签页 → 若提示 workflow 未启用，点 `I understand my workflows, go ahead and enable them`
2. 左侧选 **build-lhhc** → 右侧 **Run workflow**
3. 三个参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `mu300_release` | `v2026.10.17` | **必须与刷机助手内置内核包同版本**。F50-Flasher 1.8.6 内置的是 v2026.10.17，填别的会导致内核模块版本对不上、开不了机 |
| `lhhc_tag` | `lhhc_02` | 署名字段，随便改 |
| `with_mihomo_core` | `yes` | 预置 mihomo 内核；`no` 则首次进 OpenClash 时联网下载 |

4. 约 15–25 分钟（qemu 模拟 arm64，apk 装 ruby/tailscale 比较慢）
5. 跑完进这次 run → 页面底部 **Artifacts** → 下载 `mu300-openwrt-luci-lhhc_02`
6. 解压得到 `mu300-openwrt-luci-lhhc_02-rootfs.tar.gz` + `.sha256`

---

## 3. 用 F50 刷机助手安装

安装器路径：`C:\Users\szy\Downloads\Telegram Desktop\F50-Windows-v1.8.6-Portable\F50-v1.8.6\F50-Flasher.exe`

1. Android 里确认已 ROOT、USB 调试打开 → 连电脑 → 助手首页「刷新设备」→「检测 ROOT」
2. 固件来源选 **本地 rootfs 文件**，选中刚下载的 `mu300-openwrt-luci-lhhc_02-rootfs.tar.gz`
   - 助手会自动识别为 `openwrt-luci` 系统、版本 25.12.5（`DISTRIB_RELEASE` 故意没改，
     改了会让助手识别异常）
3. 安装位置：内部 Linux 空间或 TF 卡
4. 执行第 2 步空间检查（定制版比官方大约 3 倍，**至少留 800 MiB**）
5. 开始安装 → 选内核（任意，rootfs 自带 5.4 模块，装 6.18/7.2 内核时
   `mu300-update` 会补上对应模块）→ 设置密码 → 输入 `INSTALL`
6. 重启，浏览器进 `http://192.168.77.1`，账号 `root`

> 装了 TF 卡时优先从卡启动；首次开机走完 MU300 面板初始化再动插件。

---

## 4. 装完之后

全部在 LuCI（`http://192.168.77.1`）里操作，需要命令行就用面板自带的终端。

**lucky**（已自启）
```
http://192.168.77.1:16601     初始账号/密码 666 / 666（首次登录强制改）
/etc/init.d/lucky restart|stop
```

**Tailscale**（先登录再开自启）
```
tailscale up --accept-routes --accept-dns=false
/etc/init.d/tailscale enable && /etc/init.d/tailscale start
```
LuCI → 服务 → Tailscale 里有对应的开关和状态。

**OpenClash**（内核已预置，配好订阅再启动）
```
/etc/init.d/openclash enable
```
LuCI → 服务 → OpenClash → 配置文件订阅 / 订阅转换 → 添加 → 启用。
首次进页面若提示内核版本不匹配，点一次「检查并更新」即可（会走你预置的 clash_meta）。

**AdGuardHome**（别抢 53）
```
/etc/init.d/adguardhome enable && /etc/init.d/adguardhome start
```
LuCI → 服务 → AdGuardHome → 首次进 `:3000` 初始化向导。
想让它接管全屋 DNS 的话：AdGuardHome 监听 `53`，把 dnsmasq 的
`dhcp.@dnsmasq[0].port` 改成 `5353`，再让 AdGuardHome 上游指向 `127.0.0.1:5353`。
直接两个都抢 53 会双双起不来。

---

## 5. 必须知道的几件事

1. **不要用助手的「SSH 固件升级」**。它会把官方 rootfs 覆盖上来，lhhc 的插件和
   署名全部消失（`image-version` 保持官方 tag，所以升级校验会通过、不会报错，
   属于静默覆盖）。要换新版就重新跑一遍云编译再本地刷。
2. **LuCI 里别 `apk upgrade`**。会拉新的 LuCI/依赖，可能把 OpenClash 的 ruby 依赖树
   搅乱；`kernel` 包在 world 里是锁死版本，upgrade 不会换内核，但其它包会动。
3. **空间**。定制版 rootfs 约 70–90 MB（官方 23 MB），解压后 300 MB 上下，
   助手要求 OpenWrt 至少 800 MiB 可用空间。
4. **恢复原厂**：助手「恢复原厂」页，走官方 `uninstall.sh`，保留 ROOT 和 Android 固件。
5. 产物的 `SHA256SUMS` 只有自校验意义，不是官方签名。

---

## 6. 本地先验一遍（可选）

下载 artifact 后，在 Windows 上跑：

```bash
python tools/verify-rootfs.py "D:\下载\mu300-openwrt-luci-lhhc_02-rootfs.tar.gz"
```

它会按刷机助手 `src/Firmware.py` 的同一套规则检查（架构、必备路径、系统类型），
输出 `PASS` 或具体缺什么，避免白刷一次。

---

## 7. 文件说明

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-lhhc.yml` | **单文件版**：下载官方 rootfs/插件 → qemu 容器内组装 → 自检 → 上传 artifact。脚本已内联，单独一个文件就能跑 |
| `alt/build-lhhc-multifile.yml` | 多文件版 workflow，逻辑相同，但要配 `scripts/` 一起用 |
| `scripts/in-image.sh` | 容器内真正干活的脚本：apk 装包、装 lucky、写署名、删 6.12 kmod、打包 |
| `scripts/lucky-init.d` | lucky 的 procd 启动脚本（`START=99`，崩溃自动重启） |
| `tools/verify-rootfs.py` | 按安装器规则校验产物 |

改插件清单就改 `in-image.sh` 第 3–8 步；改署名逻辑改第 10 步。
用单文件版时，同一段内容在 workflow 的「生成容器内脚本」步骤里（`SH_EOF` 之间）。
