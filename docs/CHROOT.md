# Chroot 模式

Chroot 只适用于已经 Root 且了解 Android 挂载和恢复流程的设备。它与 Android 共用内核；XTMOE 会尝试提供嵌套 systemd，但 cgroup 和 namespace 仍由 Android 内核决定。

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
7. 初始化 `/etc/hostname`、`/etc/hosts`、名称解析策略、`/etc/resolv.conf`、`/etc/mtab` 和运行目录；
8. 默认确认后安装 Ubuntu 标准组件和 systemd，把 `/bin/sh` 切换为 Bash，并启动嵌套 systemd。

目前不支持跨架构 Chroot。需要跨架构时请使用 PRoot 加 QEMU。

## 登录、命令和初始化

全新安装默认已经完成组件和 systemd/Bash 初始化。交互进入嵌套 systemd：

```sh
xtmoe chroot systemd-login ubuntu
xtmoe chroot systemd-exec ubuntu -- uname -a
```

普通 Chroot Shell 仍可用于修复或维护：

```sh
xtmoe chroot login ubuntu
xtmoe chroot setup ubuntu
```

`setup` 会更新 apt，并安装 `ubuntu-standard`、CA 证书、curl、locale、OpenSSH Server、sudo、systemd、D-Bus、Bash、procps、util-linux、kmod 和 mount。安装期间临时阻止包脚本启动宿主服务，之后由嵌套 systemd 管理。

初始化会保留镜像中已有的其他主机映射，并确保 `localhost` 同时映射到 `127.0.0.1` 和 `::1`。每次 `login`、`exec` 或 `setup` 还会自动补齐已有容器缺失的本机名称配置，这可以避免 `sudo: unable to resolve host localhost` 一类的错误。

## 嵌套 systemd

Chroot 不会成为 Android 的 PID 1，因此这里提供的是独立 PID namespace 中的嵌套 systemd。先检查并启动：

```sh
xtmoe chroot systemd-check ubuntu
xtmoe chroot systemd-start ubuntu
xtmoe chroot systemd-status ubuntu
xtmoe chroot systemd-login ubuntu
```

在 systemd 会话中可以直接使用 `systemctl`、`journalctl` 等命令。结束时执行：

```sh
xtmoe chroot systemd-stop ubuntu
```

嵌套 systemd 不等于 Android 原生启动服务，也不会绕过缺少 pids cgroup 等内核限制。只要 `systemd-check` 出现 `[缺失]`，就不应继续安装 Docker 或 1Panel。

## Bash 作为 `/bin/sh`

全新安装默认询问是否把 `/bin/sh` 切换为 Bash；接受后即可兼容声明 `#!/bin/sh` 却使用 Bash 数组的第三方脚本。也可以随时显式执行：

```sh
xtmoe chroot use-bash-sh ubuntu
```

该命令通过 dash 的包配置切换默认 Shell，并把 `/bin/sh` 以相对链接指向 Bash，避免 usrmerge rootfs 在宿主侧被误判。原生 Ubuntu 默认使用 dash；XTMOE 专用容器默认选择 Bash，以兼容 1Panel 等安装器。拒绝切换时使用 `--skip-bash-sh`，或在安装确认提示中回答 `n`。

在安装 Docker 或 1Panel 前运行只读内核检查：

```sh
xtmoe chroot docker-check ubuntu
```

它检查 namespace、cgroup controller、OverlayFS、IPv4 转发、iptables、dockerd、Docker socket 和 PID 1，不安装或更改 Docker。只要存在 `[缺失]`，就不应继续安装 1Panel。

每次登录会受控挂载 rootfs 自身、`/proc`、`/sys`、`/dev` 和 `/run`。Shell 正常退出后会尝试卸载；如果容器中留下后台进程，卸载可能失败。

交互登录通过 Termux `util-linux` 提供的 `script` 创建独立伪终端。Ctrl+C 只中断容器内当前前台命令并返回提示符，不会退出容器；使用 `exit` 或 Ctrl+D 才结束登录。`xtmoe chroot exec` 保持非交互模式，不分配伪终端。

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
xtmoe chroot systemd-stop ubuntu
xtmoe chroot systemd-start ubuntu
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

也可以使用统一的镜像卸载命令：

```sh
xtmoe chroot stop ubuntu
xtmoe uninstall chroot ubuntu
```

脚本化删除必须显式添加 `--yes`：

```sh
xtmoe chroot remove --yes ubuntu
xtmoe uninstall --yes chroot ubuntu
```

## 非交互安装

自动化环境使用：

```sh
xtmoe chroot install --yes ubuntu 24.04 ubuntu
```

明确跳过可选初始化：

```sh
xtmoe chroot install --skip-systemd --skip-bash-sh ubuntu 24.04 ubuntu
```

`--yes` 接受默认 systemd/Bash 初始化。手机重启或 Termux 被 Android 杀死后，需要重新执行 `xtmoe chroot systemd-start ubuntu`；嵌套 systemd 不是 Android 启动服务。

## systemd 兼容边界

systemd 必须在 PID namespace 中作为 PID 1，并使用可写 cgroup。XTMOE 会在内核允许时附加 IPC、UTS 和 cgroup namespace，但不能补造 Android 内核未编译的 controllers。缺少 pids controller 时 systemd 可能启动，但 Docker/1Panel 仍可能降级或失败。`systemd-container` 或 `systemctl` 文件存在并不代表 Android 内核已经满足运行条件。

