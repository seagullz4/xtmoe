# 常用操作

## 文件交换

PRoot 可以在登录时添加绑定：

```sh
tmoe proot login ubuntu --bind "$HOME/storage/downloads:/mnt/download"
```

Chroot 使用持久挂载配置：

```sh
tmoe chroot bind ubuntu "$HOME/storage/downloads" /mnt/download rw
tmoe chroot login ubuntu
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
tmoe proot login ubuntu --shared-x11
```

Chroot 添加 socket 挂载：

```sh
tmoe chroot bind ubuntu "$PREFIX/tmp/.X11-unix" /tmp/.X11-unix rw
tmoe chroot login ubuntu
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

1. 容器备份：通过 `tmoe ... backup` 创建；
2. 项目与个人数据：从共享目录单独同步；
3. 配置备份：保存 `~/.config/tmoe-termux`。

备份完成后运行 `sha256sum` 并把校验值与备份文件放在不同介质：

```sh
sha256sum ubuntu-backup.tar.gz > ubuntu-backup.tar.gz.sha256
```

## 空间检查和清理

```sh
df -h "$HOME"
du -sh ~/.local/share/tmoe-termux ~/.cache/tmoe-termux 2>/dev/null
tmoe proot list
tmoe chroot list
```

Ubuntu Base 下载缓存位于 `~/.cache/tmoe-termux/ubuntu-base`。只有在没有安装任务运行时才应清理缓存。

