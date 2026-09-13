# immortalwrt-custom-firmware

专门给 `fu5502` 的 PVE x86/64 软路由使用的 ImmortalWrt 自定义固件仓库。

## 目标

- 固件版本默认自动跟随 ImmortalWrt 最新稳定版
- 目标平台固定为 `x86/64 generic`
- 默认生成 PVE 最常用的 `ext4-combined.img.gz` 镜像
- 根分区默认 `4096 MB`，避免每次升级后再手动扩容
- 内置常用 LuCI 插件、代理组件、存储工具和维护工具
- 上游插件默认每天刷新，OpenClash、PassWall 等可通过配置文件继续扩展
- OpenClash 默认下载 `vernesong/OpenClash` 最新 Release 的 `.apk`
- PassWall LuCI 包默认用 ImmortalWrt SDK 从 `Openwrt-Passwall` 最新 feed 编译
- iStore 商店和 quickstart 首页默认从 iStore apk 源安装
- 自动嵌入 `fu5502/luci-app-homepage-api` 的 LuCI 文件
- 自动集成最新 Open-Box（`liandu2024/Open-Box`）及其完整 LuCI 控制面板（端口 `2026`）
- LuCI“状态 → 概览”内置自定义固件项目和 Releases 入口
- 内置 Cloudflare 节点优选与提速插件（`服务 -> CF 节点优选` 与 `/root/cf_optimize` 测速脚本）
- 修复 LuCI 状态概览中 CPU 使用率显示为 `?` 以及型号尾部出现 `undefined` 的问题
- GitHub Actions 构建成功后自动发布到 Releases

## 构建

进入 GitHub Actions 页面运行 `Build custom ImmortalWrt firmware`。

默认参数：

```text
release=latest
rootfs_partsize=4096
upstream_packages=1
target=x86/64
profile=generic
```

`release=latest` 会在构建时从 ImmortalWrt 官方 releases 目录解析最新版本，并用对应版本的 ImageBuilder 和软件源构建。也可以手动指定固定版本，比如 `25.12.1`。

也可以手动运行 workflow 时把 `rootfs_partsize` 改成 `2048`、`8192` 等；把 `upstream_packages` 改成 `0` 可以临时只使用 ImmortalWrt release 软件源。

## 包清单

主要包清单在：

```text
config/packages.txt
```

当前路由器包快照在：

```text
config/router-installed-packages-2026-06-30.txt
```

快照只做参考，不直接用于构建，避免把底层系统包、内核包和版本绑定包全部硬塞进固件。

每次构建时，`config/packages.txt` 里的普通包会由当前 ImmortalWrt 版本对应的软件源解析并安装最新可用版本。

上游插件单独处理，避免被 ImmortalWrt release 源里的旧版本锁住。默认配置在：

```text
config/upstream-release-apks.txt
config/upstream-apk-repositories.txt
config/upstream-sdk-packages.txt
```

`config/upstream-release-apks.txt` 用于直接从 GitHub 最新 Release 下载 `.apk`：

```text
name|github_repo|asset_name_regex
```

`config/upstream-apk-repositories.txt` 用于给 ImageBuilder 增加外部 apk 软件源，并把指定包追加进固件：

```text
name|apk_signing_key_url|repository_urls|packages
```

`config/upstream-sdk-packages.txt` 用于通过当前 ImmortalWrt 版本匹配的 SDK，从最新源码 feed 编译包：

```text
name|feed_name|feed_git_url|branch|make_target|artifact_globs|kconfig_snippet
```

当前默认包括：

- OpenClash：下载 `vernesong/OpenClash` 最新 GitHub Release 里的 `.apk`
- iStore：加入 `istore.istoreos.com` apk 源，并安装 `luci-app-store` 与 `luci-i18n-quickstart-zh-cn`
- PassWall：下载 ImmortalWrt SDK，并从 `Openwrt-Passwall/openwrt-passwall` 最新 main feed 编译 LuCI `.apk`

PassWall 的 Kconfig 固定项在：

```text
config/sdk/passwall.config
```

PassWall 的核心依赖包，比如 `sing-box`、`xray-core`、`chinadns-ng` 等，仍由当前 ImmortalWrt release 软件源解析。这样可以避免把 Go/Rust 运行核心全部源码编译进 Actions，构建更稳定。

## PassWall 一键更新

固件内置 `/usr/bin/update-passwall`，默认从 PassWall 最新 GitHub Release 下载适配 OpenWrt/ImmortalWrt 25.12+ 的 APK：

```sh
# 一键升级
update-passwall

# 只检查最新版本
update-passwall --check

# 强制重新安装最新版本
update-passwall --force
```

脚本会校验 GitHub Release 提供的 SHA256，安装前自动备份 `/etc/config/passwall*`，模拟安装并阻止删除已有依赖包，升级后恢复 PassWall 与 PassWall Server 原有的启用和运行状态。备份保存在 `/root/passwall-backups/`。

每次构建都会产出：

```text
UPSTREAM-PACKAGES.txt
```

这个文件会记录 OpenClash 使用的 release asset、iStore 使用的 apk 源、PassWall 使用的 feed commit，以及后续新增上游插件的来源。

如果需要临时回到纯 ImmortalWrt release 源版本，可以在 workflow 环境变量里设置：

```text
BUILD_UPSTREAM_PACKAGES=0
```

这会关闭 OpenClash 最新 Release、iStore 外部 apk 源和 PassWall SDK 编译等上游刷新逻辑。旧变量 `BUILD_UPSTREAM_PROXY_PACKAGES=0` 仍兼容。

## PVE 使用建议

推荐下载 Release 里的 `ext4-combined.img.gz`，解压后导入 PVE 磁盘。

首次切换到这个自定义固件前，先在 PVE 做快照或备份当前 ImmortalWrt VM。

## Homepage API

构建时会从下面仓库拉取最新版文件并嵌入固件：

```text
https://github.com/fu5502/luci-app-homepage-api
```

如果使用保留配置升级，现有 `/etc/config/homepage_api` 和 rpcd 密码哈希会继续保留。

## Cloudflare 节点优选（优选 IP）

固件内置 Cloudflare 优选节点管理页面与测速任务脚本：

- 菜单位置：`服务 -> CF 节点优选`（`/cgi-bin/luci/admin/services/cf_optimize`）
- 任务脚本目录：`/root/cf_optimize/`
- 核心脚本：`/root/cf_optimize/cf-autoupdate.sh`（执行测速、提取最优 IP、接管 Argo Tunnel 并刷新 DNS）
- 测速工具与 IP 库：`/root/cf_optimize/CloudflareST`、`ip.txt`、`ipv6.txt`
- 保留配置升级：`/root/cf_optimize/` 已加入 `/etc/sysupgrade.conf`，升级固件不会丢失本地测速数据与自定义参数。

## Open-Box 集成与数据持久化

固件在构建阶段自动拉取并嵌入 `liandu2024/Open-Box` 最新官方 Linux x64 发布包：

- 部署路径：`/opt/open-box/`（内置 Node.js 运行时、sing-box 内核及管理面板）
- 界面入口：`服务 -> Open-Box`，面板原生监听端口为 `2026`（如 `http://192.168.99.251:2026/`）
- 开机自启：系统首次引导时通过 uci-defaults 自动将 `openbox-panel` 设为开机自启
- 数据持久化防护：固件自动将核心配置与规则数据库目录 `/opt/open-box/data/` 以及服务脚本登记至 `/etc/sysupgrade.conf`，今后无论通过 LuCI 还是命令行执行保留配置刷机升级，均不会丢失任何已保存的节点、分流规则或 SQLite 数据库。

## 系统概览 CPU 使用率与型号修复

ImmortalWrt 25.12+ 的 `luci-mod-status` 在系统概况模块调用了 `luci.getCPUUsage`、`luci.getCPUInfo` 和 `luci.getCPUBench`。当 `luci-base` 的 ucode RPC 未提供对应方法时，会导致 CPU 使用率显示为 `?`，且型号末尾追加 `undefined`。

本固件在 `/usr/share/rpcd/ucode/luci` 中补充了这组标准 RPC 方法，并在 `/www/luci-static/resources/view/status/include/10_system.js` 中做了防空保护，确保 CPU 实时使用率（%）正常刷新，型号与 CPU 架构显示完整。
