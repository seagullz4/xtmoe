# Chroot 模式

Chroot 只适用于已经 Root 且了解 Android 挂载和恢复流程的设备。它与 Android 共用内核，也不会自动获得 systemd、cgroup 或完整 namespace 支持。

## 风险

- 容器中的 root 是高权限进程，不是 PRoot 模拟出来的 root。
- 宿主目录一旦以 `rw` 挂载，容器可以修改或删除其中的数据。
- 容器未卸载时直接删除 rootfs，可能越过容器目录影响绑定挂载的宿主数据。
- SELinux、厂商内核和 Root 管理器可能阻止 `mount`、`chroot` 或 `/proc` 操作。

XTMOE 通过固定数据目录、容器标记、路径规范化检查和“有挂载就拒绝删除”降低误删概率，但不能消除 Root 操作本身的风险。

## 准备

在普通 Termux 会话运行：

```sh
xtmoe chroot prepare
xtmoe doctor
```

`prepare` 安装 `tsu`、`mount-utils`、`coreutils`、`curl` 和 `tar`。Root 授权由 Magisk、KernelSU 或 APatch 等外部方案提供。

不要这样运行：

```sh
su
xtmoe chroot install ...
```

XTMOE 必须从普通 Termux 用户启动，只有挂载、解压属主和 `chroot` 本身通过受控助手提权。

## 安装 Ubuntu 24.04

```sh
xtmoe chroot install ubuntu 24.04 ubuntu
```

流程如下：

1. 根据 `uname -m` 选择 `arm64`、`armhf` 或 `amd64`；
2. 从 Canonical Ubuntu Base 24.04 发布页寻找最新的 24.04.x 镜像；
3. 下载官方 `SHA256SUMS`；
4. 校验镜像；
5. 以 Root 保留原始 UID/GID 解压；
6. 优先读取 Android 当前 DNS，若系统未公开 DNS 属性则使用后备 DNS；
7. 初始化 `/etc/mtab` 和运行目录。

目前不支持跨架构 Chroot。需要跨架构时请使用 PRoot 加 QEMU。

## 登录、命令和初始化

```sh
xtmoe chroot login ubuntu
xtmoe chroot exec ubuntu -- uname -a
xtmoe chroot setup ubuntu
```

`setup` 会更新 apt，并安装 CA 证书、curl、locale、OpenSSH Server 和 sudo。Ubuntu Base 默认非常精简，缺少许多常见工具是正常现象。

每次登录会受控挂载 rootfs 自身、`/proc`、`/sys`、`/dev` 和 `/run`。Shell 正常退出后会尝试卸载；如果容器中留下后台进程，卸载可能失败。

XTMOE 在卸载失败时返回失败状态，不会把“Shell 已退出”误报成“容器已安全停止”。此时应按照下面的停止流程处理占用进程。

## 停止和检查

```sh
xtmoe chroot stop ubuntu
xtmoe chroot status ubuntu
xtmoe chroot list
```

进行备份、恢复或删除前，`status` 应显示 `stopped`。

若提示 busy，先返回容器停止服务和后台进程，再执行 `stop`。不要跳过检查直接删除目录。

## 配置绑定挂载

授予 Termux 存储权限：

```sh
termux-setup-storage
```

添加只读下载目录：

```sh
xtmoe chroot bind ubuntu "$HOME/storage/downloads" /mnt/download ro
```

需要写入时明确使用 `rw`：

```sh
xtmoe chroot bind ubuntu "$HOME/storage/downloads" /mnt/download rw
```

移除配置：

```sh
xtmoe chroot unbind ubuntu /mnt/download
xtmoe chroot stop ubuntu
```

配置保存在 `~/.config/xtmoe/chroot/<名称>.binds`，使用数据格式解析，不会作为 Shell 脚本执行。`/dev`、`/proc`、`/sys` 和 `/run` 是保留挂载点，不能自定义覆盖。

为避免把整个 Android 文件系统暴露给容器，XTMOE 拒绝把宿主 `/` 或整个 `/data` 作为自定义挂载源；请选择 `/sdcard/Download`、Termux 项目目录等范围明确的子目录。

## 备份、恢复和删除

```sh
xtmoe chroot stop ubuntu
xtmoe chroot backup ubuntu "$HOME/storage/downloads/ubuntu-chroot.tar.gz"
xtmoe chroot restore "$HOME/storage/downloads/ubuntu-chroot.tar.gz" ubuntu-copy
```

Chroot 备份只包含容器文件系统，不自动恢复宿主绑定挂载配置；恢复后需要重新执行 `xtmoe chroot bind`。这是为了避免在另一台设备上意外挂载原设备路径。

备份通过同目录临时文件原子完成，并拒绝覆盖已经存在的同名文件；失败的临时备份不会被当成有效备份交付。

删除必须经过确认：

```sh
xtmoe chroot stop ubuntu
xtmoe chroot remove ubuntu
```

脚本化删除必须显式添加 `--yes`：

```sh
xtmoe chroot remove --yes ubuntu
```

## systemd 说明

本实现默认不启动 systemd。普通 Android 内核经常缺少或限制 systemd 所需的 PID namespace、mount namespace、cgroup v2 和设备管理能力。`systemd-container` 软件包存在并不代表 `systemd-nspawn` 能在手机内核上工作。

在容器内应优先直接启动所需服务，例如 `/usr/sbin/sshd`、`nginx` 或数据库进程，而不是依赖 `systemctl`。

