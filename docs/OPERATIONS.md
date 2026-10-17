# 常用操作

## Chroot 一键初始化与续跑

先在源码目录执行 `sh termux.sh`，再运行 `xtmoe doctor`，通过后进入 `xtmoe on` → Chroot。全新系统选择“一键安装”；已有系统选择“一键配置已有 Ubuntu”，按数字选择目标。

直接命令：

```sh
xtmoe chroot init --skip-docker ubuntu
xtmoe chroot init --accept-host-network-changes ubuntu
xtmoe chroot repair ubuntu
```

前两条是不同选择：第一条只配置 Ubuntu、网络和 systemd；第二条还接受 Docker 对宿主网络规则的影响并尝试安装。网络/APT 失败会停止后续阶段；`repair` 保留已有安装选择并重验实时条件。缺少 iptables 会先安装用户态依赖，不能直接归因于 Android 内核。

## 文件交换

PRoot 可以在登录时添加绑定：

```sh
xtmoe proot login ubuntu --bind "$HOME/storage/downloads:/mnt/download"
```

Chroot 使用持久挂载配置：

```sh
xtmoe chroot bind ubuntu "$HOME/storage/downloads" /mnt/download rw
xtmoe chroot login ubuntu
```

重要数据应保存在明确的共享目录并单独备份。不要把唯一副本只放在容器 rootfs 中。

## SSH

容器内安装并配置 OpenSSH：

```sh
apt-get update
apt-get install -y openssh-server
mkdir -p /run/sshd
passwd
```

修改 `/etc/ssh/sshd_config`，建议使用大于 1024 的端口，例如：

```text
Port 2022
PermitRootLogin prohibit-password
PasswordAuthentication yes
```

测试配置并以前台方式启动：

```sh
/usr/sbin/sshd -t
/usr/sbin/sshd -D -e
```

同一局域网设备连接前，先在 Termux 宿主查看手机地址：

```sh
ip addr
```

Android 可能限制后台进程；长期运行应关闭 Termux 电池优化，并使用 Termux:Boot 或受监督的前台会话。不要直接把 SSH 端口暴露到公网。

## Docker 与 1Panel 前置检查

Chroot 共用 Android 内核，安装 Docker 软件包不能补上缺失的 namespace、cgroup 或网络模块。先执行：

```sh
xtmoe chroot docker-check ubuntu
xtmoe chroot cgroup-check ubuntu
```

检查没有 `[缺失]` 后，可以显式安装并确认标准 bridge 对 Android 宿主 iptables/IP forwarding 的影响：

```sh
xtmoe chroot docker-install ubuntu
xtmoe chroot docker-status ubuntu
```

Docker 客户端存在不等于 daemon 可用；只有 socket、`docker info` 和实际 `hello-world` 都通过才是完全可用。daemon 正常但 registry 访问失败时应标记为“daemon 可用、registry 未验证”。普通 Chroot 的 PID 1 通常是 Android `init`；XTMOE 必须进入嵌套 systemd namespace。`systemctl is-system-running` 显示 `offline` 时，1Panel 的 systemd 服务管理路径不可用。

XTMOE 不自动执行 1Panel 第三方安装脚本。只有 Docker 完整验收通过后，才应按 1Panel 官方文档人工安装。

如果设备无法满足嵌套 systemd 的严格条件，但希望尝试不依赖 `systemctl` 的 Docker daemon，可使用 direct dockerd 兼容模式：

```sh
xtmoe chroot docker-direct-install ubuntu
xtmoe chroot docker-direct-status ubuntu
xtmoe chroot docker-direct-run-test ubuntu
```

状态命令通过 `docker info` 验证 API；运行测试才验证实际容器。该兼容模式不会被标记为 1Panel 已支持。

如果 Chroot 的 Android 内核能力始终不足，可使用拥有独立客体内核的 QEMU 模式：

```sh
xtmoe qemu install ubuntu-qemu
xtmoe qemu docker-status ubuntu-qemu
xtmoe qemu docker-test ubuntu-qemu
```

QEMU 不需要手机 Root，但无 KVM 时速度较慢。服务端口必须通过 `xtmoe qemu port-add` 显式转发。

## Python 和编译环境

Ubuntu/Debian 容器内：

```sh
apt-get update
apt-get install -y python3 python3-pip python3-venv build-essential git
python3 -m venv /opt/venvs/default
. /opt/venvs/default/bin/activate
```

## Termux:X11 桌面

先安装与当前 Termux 来源匹配的 Termux:X11 应用，然后在 Termux 中安装客户端包：

```sh
pkg install -y x11-repo
pkg install -y termux-x11-nightly
termux-x11 :1 &
```

PRoot 登录时共享 X11 socket：

```sh
xtmoe proot login ubuntu --shared-x11
```

Chroot 添加 socket 挂载：

```sh
xtmoe chroot bind ubuntu "$PREFIX/tmp/.X11-unix" /tmp/.X11-unix rw
xtmoe chroot login ubuntu
```

然后在容器内安装桌面并启动：

```sh
apt-get update
apt-get install -y xfce4 dbus-x11
export DISPLAY=:1
dbus-launch --exit-with-session startxfce4
```

不同版本的 Termux:X11 参数可能变化，应以其官方 README 和设备上的命令帮助为准。

## 备份策略

建议保留三类备份：

1. 容器备份：通过 `xtmoe ... backup` 创建；
2. 项目与个人数据：从共享目录单独同步；
3. 配置备份：保存 `~/.config/xtmoe`。

备份完成后运行 `sha256sum` 并把校验值与备份文件放在不同介质：

```sh
sha256sum ubuntu-backup.tar.gz > ubuntu-backup.tar.gz.sha256
```

## 空间检查和清理

```sh
df -h "$HOME"
du -sh ~/.local/share/xtmoe ~/.cache/xtmoe 2>/dev/null
xtmoe proot list
xtmoe chroot list
```

Ubuntu Base 下载缓存位于 `~/.cache/xtmoe/ubuntu-base`。只有在没有安装任务运行时才应清理缓存。
