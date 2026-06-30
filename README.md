# immortalwrt-custom-firmware

专门给 `fu5502` 的 PVE x86/64 软路由使用的 ImmortalWrt 自定义固件仓库。

## 目标

- 固件版本默认跟随 ImmortalWrt `25.12.0`
- 目标平台固定为 `x86/64 generic`
- 默认生成 `ext4 combined` 镜像
- 根分区默认 `4096 MB`，避免每次升级后再手动扩容
- 内置常用 LuCI 插件、代理组件、存储工具和维护工具
- 自动嵌入 `fu5502/luci-app-homepage-api` 的 LuCI 文件
- GitHub Actions 构建成功后自动发布到 Releases

## 构建

进入 GitHub Actions 页面运行 `Build custom ImmortalWrt firmware`。

默认参数：

```text
release=25.12.0
rootfs_partsize=4096
target=x86/64
profile=generic
```

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

## PVE 使用建议

推荐下载 Release 里的 `ext4-combined.img.gz`，解压后导入 PVE 磁盘。

首次切换到这个自定义固件前，先在 PVE 做快照或备份当前 ImmortalWrt VM。

## Homepage API

构建时会从下面仓库拉取最新版文件并嵌入固件：

```text
https://github.com/fu5502/luci-app-homepage-api
```

如果使用保留配置升级，现有 `/etc/config/homepage_api` 和 rpcd 密码哈希会继续保留。
