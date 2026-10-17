# Chroot 模式

Chroot 只适用于已经 Root 且了解 Android 挂载和恢复流程的设备。它与 Android 共用内核；XTMOE 会尝试提供嵌套 systemd，但 cgroup 和 namespace 仍由 Android 内核决定。

开始本页的 Chroot 操作前，必须先在普通 Termux 用户会话的 XTMOE 源码目录执行 `sh termux.sh`，然后运行 `xtmoe doctor`。只有基础检查完成后才继续安装或管理 Chroot。

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
6. 写入固定公共 DNS `1.1.1.1`、`8.8.8.8` 并验证 `ports.ubuntu.com`；
7. 初始化 `/etc/hostname`、`/etc/hosts`、名称解析策略、`/etc/resolv.conf`、`/etc/mtab` 和运行目录；
8. 默认确认后安装 Ubuntu 标准组件和 systemd，把 `/bin/sh` 切换为 Bash，并启动嵌套 systemd；
9. 检查 namespace、cgroup、iptables 和转发能力；只有检查通过才安装 Docker；
10. 启用 `containerd`/`docker`，并通过 `docker info` 和 `hello-world` 实际验收。

初始化阶段记录为 `base-ready`、`network-ready`、`system-ready`、`docker-ready`、`ready` 或 `partial`。网络、APT、systemd 或 Docker 中途失败时保留 rootfs，修复外部条件后继续：

```sh
xtmoe chroot repair ubuntu
```

如果该容器期望安装 Docker，非交互修复还需要显式确认宿主网络变化：

```sh
xtmoe chroot repair --accept-host-network-changes ubuntu
```

目前不支持跨架构 Chroot。需要跨架构时请使用 PRoot 加 QEMU。

## 登录、命令和初始化

全新安装默认已经完成组件和 systemd/Bash 初始化。交互进入嵌套 systemd：

```sh
xtmoe chroot systemd-login ubuntu
xtmoe chroot systemd-exec ubuntu -- uname -a
```

`chroot login` 在 systemd 运行时会自动进入同一个嵌套 systemd 会话；只有 systemd 未运行时才使用普通 Chroot Shell。普通模式仍可用于修复或维护：

```sh
xtmoe chroot login ubuntu
xtmoe chroot setup ubuntu
```

`setup` 会更新 apt，并安装 `ubuntu-standard`、CA 证书、curl、locale、OpenSSH Server、sudo、systemd、D-Bus、Bash、procps、util-linux、kmod、mount、iproute2、iptables 和 iputils-ping。安装期间临时阻止包脚本启动宿主服务，之后由嵌套 systemd 管理。

完整网络诊断会打印 DNS、域名解析、数字 IP Ping、Ubuntu 源 HTTP 访问和代理变量是否设置：

```sh
xtmoe chroot network-check ubuntu
```

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

查看 cgroup v1/v2、挂载点、controller 和 cgroup namespace 能力：

```sh
xtmoe chroot cgroup-check ubuntu
```

XTMOE 只挂载内核真实提供的 cgroup 文件系统。缺少的 `pids`、`devices` 或 namespace 不能通过用户空间脚本补造。

## Bash 作为 `/bin/sh`

全新安装默认询问是否把 `/bin/sh` 切换为 Bash；接受后即可兼容声明 `#!/bin/sh` 却使用 Bash 数组的第三方脚本。也可以随时显式执行：

```sh
xtmoe chroot use-bash-sh ubuntu
```

该命令通过 dash 的包配置切换默认 Shell，并把 `/bin/sh` 以相对链接指向 Bash，避免 usrmerge rootfs 在宿主侧被误判。原生 Ubuntu 默认使用 dash；XTMOE 专用容器默认选择 Bash，以兼容 1Panel 等安装器。拒绝切换时使用 `--skip-bash-sh`，或在安装确认提示中回答 `n`。

## Docker 生命周期

在安装 Docker 或部署 1Panel 前运行只读内核检查：

```sh
xtmoe chroot docker-check ubuntu
```

它实际尝试创建 mount、PID、network、IPC 和 UTS namespace，并检查 cgroup hierarchy、`pids`、v1 `devices`、OverlayFS、IPv4 转发、iptables 和嵌套 systemd。只要存在 `[缺失]`，Docker 安装就会被严格跳过。

检查通过后安装 Docker 官方仓库版本：

```sh
xtmoe chroot docker-install ubuntu
```

Docker 标准 bridge 会影响 Android 宿主共享网络 namespace 中的 iptables 和 IP forwarding，交互安装必须确认。自动化使用：

```sh
xtmoe chroot docker-install --accept-host-network-changes ubuntu
```

服务管理和日志：

```sh
xtmoe chroot docker-start ubuntu
xtmoe chroot docker-status ubuntu
xtmoe chroot docker-restart ubuntu
xtmoe chroot docker-logs ubuntu
xtmoe chroot docker-stop ubuntu
```

安装成功后 `docker.service` 与 `containerd.service` 会被 enable，每次 `xtmoe chroot systemd-start ubuntu` 后由嵌套 systemd 自动拉起。这不等于 Android 开机自启。

Docker 有四种必须区分的结果：完全通过；systemd 可用但内核阻断；daemon 可用但 registry/`hello-world` 未验证；软件已安装但 daemon 启动失败。XTMOE 不会把后三者显示为完全可用，也不会自动安装 1Panel。

### 不依赖 systemd 的 direct dockerd 兼容模式

部分 Android 内核无法让嵌套 systemd 完整运行，但仍可能允许 `dockerd` 直接响应。此时不要把它当成严格模式或 1Panel 支持，而是显式选择 direct 兼容模式：

```sh
xtmoe chroot docker-direct-install ubuntu
```

该命令会要求确认 Docker bridge 对 Android 宿主 iptables/IP forwarding 的影响，安装 Docker 官方仓库版本，停止已有的嵌套 systemd 会话，然后在独立 mount namespace 内按等价于下列逻辑启动：

```sh
dockerd --iptables=true --host=unix:///var/run/docker.sock
```

XTMOE 将 daemon 的 PID 和日志纳入生命周期管理，因此不要自己在普通 `chroot login` Shell 中后台运行 `dockerd`。直接登录退出后普通 Chroot 会清理挂载，手动后台 daemon 容易遗留 busy 挂载或被会话信号停止。

direct 模式命令：

```sh
xtmoe chroot docker-direct-start ubuntu
xtmoe chroot docker-direct-status ubuntu
xtmoe chroot docker-direct-logs ubuntu
xtmoe chroot docker-direct-run-test ubuntu
xtmoe chroot docker-direct-stop ubuntu
```

`docker-direct-status` 等价验证 `docker info`，只说明 daemon API 可用；`docker-direct-run-test` 运行 `docker run --rm hello-world`，才验证 containerd、runc、namespace、挂载和实际容器链路。若前者成功而后者失败，应报告为“daemon 可用、容器运行未验证/失败”，不能据此宣称 Docker 或 1Panel 完全可用。direct 模式与嵌套 systemd 模式不能并存；`chroot stop` 会停止任一种已受 XTMOE 管理的 daemon。

direct 启动会显示三个阶段：寻找 daemon 进程（最长约 5 秒）、等待 Docker socket（最长约 15 秒）、带 15 秒超时的 `docker info` 验证。任何阶段失败都会停止等待并提示查看 `docker-direct-logs`，不会无期限卡住。

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

`chroot stop` 是统一停止入口：嵌套 systemd 运行时先停止 Docker/containerd，再正常关闭 systemd，最后卸载 cgroup 和全部绑定挂载；未运行时只清理挂载。重复执行是安全的。若提示 busy，先返回容器停止服务和后台进程，再执行 `stop`。不要跳过检查直接删除目录。

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
xtmoe chroot install --yes --accept-host-network-changes ubuntu 24.04 ubuntu
```

不安装 Docker：

```sh
xtmoe chroot install --yes --skip-docker ubuntu 24.04 ubuntu
```

明确跳过 systemd、Docker 和 Shell 切换：

```sh
xtmoe chroot install --yes --skip-systemd --skip-bash-sh ubuntu 24.04 ubuntu
```

`--yes` 接受普通默认项，但不会代替 `--accept-host-network-changes` 这一高风险确认。手机重启或 Termux 被 Android 杀死后，需要重新执行 `xtmoe chroot systemd-start ubuntu`；嵌套 systemd 不是 Android 启动服务。

更新或不备份直接重装：

```sh
xtmoe chroot update-system ubuntu
xtmoe chroot reinstall ubuntu
```

`reinstall` 会永久删除 rootfs、Docker 镜像、容器和卷，不自动备份；脚本化使用必须添加 `--yes`。

## systemd 兼容边界

systemd 必须在 PID namespace 中作为 PID 1，并使用可写 cgroup。XTMOE 会在内核允许时附加 IPC、UTS 和 cgroup namespace，但不能补造 Android 内核未编译的 controllers。缺少 pids controller 时 systemd 可能启动，但 Docker/1Panel 仍可能降级或失败。`systemd-container` 或 `systemctl` 文件存在并不代表 Android 内核已经满足运行条件。

