# 故障排查

## 先运行 doctor

```sh
xtmoe doctor
termux-info
```

反馈问题时请附上这两条命令的输出、Android 版本、CPU 架构、Root 管理器和失败命令。不要发送访问令牌、私钥或完整的个人目录列表。

## 执行安装命令后没有输出

不要使用静默的远程管道命令。先确认网络：

```sh
curl -IL --connect-timeout 15 https://github.com/seagullz4/xtmoe
```

出现 `Could not resolve host` 是 DNS 问题；`SSL certificate problem` 通常需要更新 `ca-certificates`；HTTP 403/429 可能是网络限制或服务端限流。

## GitHub 已有新命令，但本机提示未知命令

`git pull` 只更新 `$HOME/xtmoe` 源码，不会自动覆盖 Termux 中已经安装的 `$PREFIX/bin/xtmoe`。先查看实际运行位置和版本：

```sh
command -v xtmoe
xtmoe version
```

旧安装版本需要执行一次：

```sh
cd "$HOME/xtmoe"
git pull --ff-only
sh termux.sh
xtmoe doctor
```

此后可直接使用：

```sh
xtmoe update
```

`doctor` 会显示当前程序、已安装命令、源码目录以及两边版本；不一致时会明确报错。

## 出现 Command xzmore in package xz-utils

XTMOE 源码和安装流程不调用 `xzmore`，Ubuntu Base 镜像使用 `.tar.gz`，备份也使用 gzip。这个提示是 Termux 的 command-not-found 对用户输入 `xzmore` 的软件包建议，不表示 XTMOE 缺少运行依赖。除非你本人需要浏览 `.xz` 文本，否则不需要为 XTMOE 安装 `xz-utils`。

## pkg 更新失败

确认不是旧 Play 商店版 Termux，然后运行：

```sh
termux-change-repo
pkg update
pkg upgrade
```

XTMOE 不会自动改写镜像源。

## PRoot 无法安装或登录

```sh
pkg reinstall proot proot-distro
xtmoe proot raw --version
xtmoe proot raw list
```

不要在另一个 PRoot 容器中嵌套运行，也不要从 Root shell 运行 `proot-distro`。

## Chroot 提示没有 Root

```sh
xtmoe chroot prepare
tsu -c 'id -u'
```

正确输出应为 `0`。如果 Root 管理器没有弹出授权，请检查其授权记录、`su` 实现和 Termux 安装来源。

## Chroot mount 被拒绝

错误包含 `Permission denied` 或 `Operation not permitted` 时，通常由 SELinux、Root 方案或内核能力造成。检查：

```sh
tsu -c 'id; getenforce; mount --version'
```

不要为了绕过错误永久关闭 SELinux。无法满足挂载能力的设备应使用 PRoot。

## 1Panel 提示 Unsupported option: s

这是 1Panel 安装脚本的参数解析错误，不是 Docker 内核错误。1Panel v2 不接受单独的 `s` 或 `-s` 参数。先检查实际执行的命令，不要把 curl 的静默参数错误地传给 `install.sh`。

在继续安装 1Panel 之前，先运行：

```sh
xtmoe chroot docker-check ubuntu
```

如果输出存在 `[缺失]`，说明 Android 内核缺少 Docker 必需能力。仅安装 `docker`/`dockerd`/`wmdocker` 用户空间程序不能补上内核中的 namespace 或 cgroup controller。

以下输出只表示安装了 Docker 客户端，不能证明 daemon 可用：

```text
failed to connect to the docker API at unix:///var/run/docker.sock
```

必须满足：

```sh
docker info
```

能连接 daemon，且 `/var/run/docker.sock` 存在。如果 `cat /proc/1/comm` 不是 `systemd`、`systemctl is-system-running` 显示 `offline`，则 1Panel 的 systemd 服务管理分支也不可用。

## Chroot 无法卸载

先回到容器停止后台进程，然后：

```sh
xtmoe chroot stop ubuntu
xtmoe chroot status ubuntu
```

仍提示 busy 时不要删除 rootfs。关闭其他 Termux 会话和可能使用共享目录的程序后重试；最后手段是重启手机，再先执行 `status`/`stop`。

## Chroot 提示 no job control 或 Ctrl+C 退出登录

重新安装 Chroot 运行依赖和 XTMOE：

```sh
xtmoe chroot prepare
cd "$HOME/xtmoe"
git pull --ff-only
sh termux.sh
```

交互登录需要 Termux 的 `util-linux` 提供 `script` 伪终端。确认命令存在：

```sh
command -v script
xtmoe chroot login ubuntu
```

修复后 Ctrl+C 应只中断当前前台命令；应使用 `exit` 或 Ctrl+D 主动退出容器。

## apt 无法解析域名

```sh
cat /etc/resolv.conf
getent hosts archive.ubuntu.com
```

Chroot 初始化会写入公共 DNS。若当前网络阻止这些 DNS，可在容器内按网络环境更换 `/etc/resolv.conf`。

## `sudo` 提示无法解析 `localhost`

这通常不是外部 DNS 故障，而是 Chroot 的本机名称映射缺失。检查：

```sh
cat /etc/hostname
cat /etc/hosts
getent hosts localhost
```

新安装的 Chroot 应包含 `localhost` 的 IPv4 和 IPv6 映射。旧容器可以手工补充：

```sh
printf 'localhost\n' > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' > /etc/hosts
```

## 1Panel 报 `/bin/sh` 数组语法错误

这表示安装脚本声明 POSIX Shell，却使用 Bash 语法。不要修改 1Panel 脚本，可切换容器系统 Shell：

```sh
xtmoe chroot use-bash-sh ubuntu
```

随后使用嵌套 systemd 启动服务：

```sh
xtmoe chroot systemd-check ubuntu
xtmoe chroot systemd-start ubuntu
xtmoe chroot systemd-status ubuntu
```

若 `systemd-check` 报缺失，说明 Android 内核条件不满足；切换 Shell 不能修复 cgroup、PID namespace 或 systemd 缺失。

## Android 杀死后台任务

关闭 Termux 的电池优化，允许后台活动，并避免清理最近任务。部分 Android 12+ 设备还受 Phantom Process Killer 限制；具体设置随厂商和系统版本变化。

