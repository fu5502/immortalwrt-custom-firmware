# immortalwrt-custom-firmware

专门给 `fu5502` 的 PVE x86/64 软路由使用的 ImmortalWrt 自定义固件仓库。

## 目标

- 固件版本默认自动跟随 ImmortalWrt 最新稳定版
- 目标平台固定为 `x86/64 generic`
- 默认生成 PVE 最常用的 `ext4-combined.img.gz` 镜像
- 根分区默认 `4096 MB`，避免每次升级后再手动扩容
- 内置常用 LuCI 插件、代理组件、存储工具和维护工具
- OpenClash 默认下载 `vernesong/OpenClash` 最新 Release 的 `.apk`
- PassWall 默认用 ImmortalWrt SDK 从 `Openwrt-Passwall` 最新 feed 编译
- 自动嵌入 `fu5502/luci-app-homepage-api` 的 LuCI 文件
- GitHub Actions 构建成功后自动发布到 Releases

## 构建

进入 GitHub Actions 页面运行 `Build custom ImmortalWrt firmware`。

默认参数：

```text
release=latest
rootfs_partsize=4096
target=x86/64
profile=generic
```

`release=latest` 会在构建时从 ImmortalWrt 官方 releases 目录解析最新版本，并用对应版本的 ImageBuilder 和软件源构建。也可以手动指定固定版本，比如 `25.12.1`。

也可以手动运行 workflow 时把 `rootfs_partsize` 改成 `2048`、`8192` 等。

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

OpenClash 和 PassWall 单独处理，避免被 ImmortalWrt release 源里的旧版本锁住：

- OpenClash：下载 `vernesong/OpenClash` 最新 GitHub Release 里的 `.apk`
- PassWall：下载 ImmortalWrt SDK，并从 `Openwrt-Passwall/openwrt-passwall` 与 `Openwrt-Passwall/openwrt-passwall-packages` 最新 main feed 编译 `.apk`

如果需要临时回到纯 ImmortalWrt release 源版本，可以在 workflow 环境变量里设置：

```text
BUILD_UPSTREAM_PROXY_PACKAGES=0
```

## PVE 使用建议

推荐下载 Release 里的 `ext4-combined.img.gz`，解压后导入 PVE 磁盘。

首次切换到这个自定义固件前，先在 PVE 做快照或备份当前 ImmortalWrt VM。

## Homepage API

构建时会从下面仓库拉取最新版文件并嵌入固件：

```text
https://github.com/fu5502/luci-app-homepage-api
```

如果使用保留配置升级，现有 `/etc/config/homepage_api` 和 rpcd 密码哈希会继续保留。
