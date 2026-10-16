# PRoot 模式

PRoot 不需要手机 Root。新版 TMOE 将容器生命周期委托给 Termux 官方维护的 `proot-distro`，TMOE 负责统一入口、环境诊断和危险操作确认。

## 安装容器

默认安装 Ubuntu 24.04：

```sh
tmoe proot install
```

显式指定 OCI/Docker 镜像和本地名称：

```sh
tmoe proot install ubuntu:24.04 ubuntu
tmoe proot install debian:13 debian
tmoe proot install alpine:latest alpine
```

镜像名称和可用架构由 `proot-distro` 解析。需要精确复现时，可以使用带 `sha256` 摘要的镜像引用。

## 进入和执行命令

```sh
tmoe proot login ubuntu
tmoe proot exec ubuntu -- uname -a
tmoe proot exec ubuntu -- /bin/bash -lc 'apt-get update && apt-get upgrade -y'
```

退出交互式 Shell：

```sh
exit
```

## 共享文件

先授予 Termux 存储权限：

```sh
termux-setup-storage
```

将 Download 映射到容器 `/mnt/download`：

```sh
tmoe proot login ubuntu --bind "$HOME/storage/downloads:/mnt/download"
```

共享 Termux 临时目录或 X11 socket：

```sh
tmoe proot login ubuntu --shared-tmp
tmoe proot login ubuntu --shared-x11
```

这些参数由当前 `proot-distro login` 提供；可用选项以设备上的帮助为准：

```sh
tmoe proot raw login --help
```

## 会话和后台进程

```sh
tmoe proot ps
tmoe proot stop ubuntu
```

`stop` 会让 `proot-distro` 停止该容器已登记的活动会话。需要使用更高级的后台、入口点或会话参数时，可直接调用：

```sh
tmoe proot raw run --help
tmoe proot raw login --help
```

## 备份与恢复

先停止活动会话，再备份：

```sh
tmoe proot stop ubuntu
tmoe proot backup ubuntu "$HOME/storage/downloads/ubuntu.tar.gz"
```

恢复时，容器名称来自备份内容：

```sh
tmoe proot restore "$HOME/storage/downloads/ubuntu.tar.gz"
```

如需改名，查看当前 `proot-distro` 的 rename 命令：

```sh
tmoe proot raw rename --help
```

## 删除

```sh
tmoe proot remove ubuntu
```

非交互脚本必须显式确认：

```sh
tmoe proot remove --yes ubuntu
```

删除无法撤销，建议先备份。

## PRoot 限制

- PRoot 通过 `ptrace` 转换文件路径和部分系统调用，会有性能损耗。
- 它不提供真正的 Linux 内核、虚拟机或强安全隔离。
- systemd、内核模块、FUSE、Docker 等依赖底层内核能力的功能通常不可用或受限。
- Android 12 及以上系统可能因后台进程限制终止长时间运行的任务；应关闭 Termux 的电池优化，并按设备系统设置允许后台运行。

