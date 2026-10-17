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
xtmoe chroot docker-status ubuntu
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
xtmoe chroot network-check ubuntu
```

Chroot 初始化固定写入 `1.1.1.1` 和 `8.8.8.8`。`network-check` 会完整打印 resolv.conf、`ports.ubuntu.com` 解析、数字 IP Ping、Ubuntu 源 HTTP 访问和代理变量状态。若当前 VPN、私有 DNS 或运营商阻止公共 DNS，初始化会停止并把容器标记为 `partial`；修正网络后执行：

```sh
xtmoe chroot repair ubuntu
```

不要在 DNS 仍失败时反复安装 Docker；APT 网络失败和 Docker 内核阻断是两类独立问题。

## Docker 安装返回状态 2

状态 `2` 表示 Ubuntu 和嵌套 systemd 已完成，但 Docker 因 Android 内核硬阻断被严格跳过。查看详细原因：

```sh
xtmoe chroot cgroup-check ubuntu
xtmoe chroot docker-check ubuntu
```

常见阻断包括无法创建 IPC/network namespace、缺少 `pids` controller、cgroup v1 缺少 `devices`、IP forwarding 不可写或容器内缺少 iptables。安装 `dockerd` 用户空间程序不能修复这些内核能力。

## Docker 已安装但服务失败

```sh
xtmoe chroot docker-status ubuntu
xtmoe chroot docker-logs ubuntu
xtmoe chroot systemd-status ubuntu
```

`docker-status` 只有在 containerd、docker.service、socket 和 `docker info` 都正常时才成功。若 daemon 可响应但 `hello-world` 失败，优先检查 registry DNS、HTTPS、VPN 和代理，不要把它误判为 daemon 已崩溃。

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

这表示安装脚本声明 POSIX Shell，却使用 Bash 语法。全新安装默认会切换容器系统 Shell；旧容器可执行：

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

## systemd-verify 显示空状态或一直等待

旧版验证使用 `timeout 60 systemctl is-system-running --wait`，同时丢弃标准错误和退出码。`--wait` 在开机任务完成之前可能不输出状态，超时或命令失败就会留下空白的 `systemd:`。空白不是有效的 manager 状态，不能据此判断 systemd 已损坏或已经 running。

新验证改成不带 `--wait` 的有界轮询，总等待最多 120 秒，输出状态和退出码，失败时保留原始错误并列出待完成任务和 journal。进程与 manager socket 就绪只表示可以尝试管理服务，不保证开机任务全部完成。

不需要重装。先在普通 Termux 中对实际容器执行这些只读命令（示例名称 `ubuntu`）：

```sh
xtmoe chroot systemd-exec ubuntu -- timeout --kill-after=2 10 systemctl is-system-running
xtmoe chroot systemd-exec ubuntu -- timeout --kill-after=2 10 systemctl list-jobs --no-pager
xtmoe chroot systemd-exec ubuntu -- timeout --kill-after=2 10 systemctl --failed --no-pager
xtmoe chroot systemd-exec ubuntu -- timeout --kill-after=2 10 journalctl -b -n 60 --no-pager
```

`--failed` 显示 `0 loaded units listed` 并不排除 `starting`：还在运行的启动任务尚未失败。根据 `list-jobs`/journal 排查具体任务；不要未经判断就禁用 wait-online、udev 或其他系统服务。若显示 `Failed to connect to bus`，按原始错误检查 namespace、socket 或权限；若状态查询本身超时，先诊断 manager 响应，不继续 Docker 安装。确认外部条件解决、已安装修正版命令后，再执行 `xtmoe chroot repair ubuntu`。

## systemd 启动日志出现 SELinux policy 缺失

例如 `Could not open policy file <= /etc/selinux/targeted/policy/policy.33`。这说明启动过程中发生了发行版 SELinux policy 加载尝试，但单行日志不等同于已确认的退出原因；不要据此安装 `selinux-policy-*`、执行 `load_policy`，也不要为了 Chroot 修改宿主 enforcing 状态。

启动器需要明确设置容器 PID 1 的 `container=xtmoe` 并保护容器视图中的 sysfs/SELinux 接口。systemd 的容器路径与宿主启动路径不同，缺少标识会使环境探测依赖回退启发式，可能走错宿主级初始化逻辑。新版已显式设置标识并要求只读保护成功，仍需在真实设备确认 PID 存活、systemd 状态和宿主模式未改变，不能只用离线测试宣称成功。

若 `systemd-exec` 已报告进程退出，先读宿主侧日志，不能依赖已退出的 manager 运行 journalctl。若 `tsu -c` 报 `/system/bin/sh ... unknown option`，说明该次提权命令尚未执行目标操作；可先检查 `su -c 'id'`，确认 Root 后使用绝对命令路径：

```sh
su -c '/data/data/com.termux/files/usr/bin/tail -n 160 /data/data/com.termux/files/home/.local/share/xtmoe/chroot/ubuntu/.xtmoe-systemd.log'
su -c '/system/bin/getenforce'
su -c '/system/bin/dmesg' | grep -iE 'avc:.*denied|systemd|unshare|killed process|out of memory|oom' | tail -n 80
```

替换示例中的实际容器名称。管道无输出只表示没有匹配行，不足以排除所有错误。`Permissive` 只说明当前宿主模式；没有启动前读数时，不能断定是 XTMOE、Root 模块或原始系统设置造成，也不要在不了解设备依赖时盲目切换为 Enforcing。修复代码不会自动恢复或改变未知的历史安全设置。

`exec /sbin/init --unit=multi-user.target` 不是 Termux 修复命令，只应由容器启动器在正确的 namespace、rootfs 和环境中执行；在 Termux 报文件不存在不代表 Ubuntu 缺少 systemd。

## Docker 检查报告缺少 iptables

先区分软件包缺失、alternatives 多层绝对链接被旧版误判，以及内核 NAT/权限受限。不要直接清空宿主规则、切换 legacy/nft 后端或关闭 iptables。升级已安装命令后，已有容器可以执行：

```sh
xtmoe chroot init --skip-docker ubuntu
xtmoe chroot docker-check ubuntu
xtmoe chroot docker-install ubuntu
```

第一步补齐网络、基础包、systemd 及 iptables；第三步仍需单独接受 Docker bridge 风险。新版 Docker 安装先做内核预检，再补用户态依赖、检查 iptables 执行和临时 network namespace 的 NAT 查询，最后才添加 Docker 源。缺包/APT/服务异常返回 `1`，内核/Root 权限失败返回 `2`，两者分别记录而非一概提示“内核缺失”。

如果 NAT 查询失败，保留检查的原始错误；可能是后端不受支持、内核模块或权限受限。安装 iptables 软件包不能保证内核 netfilter 可用，只有 daemon 和真实容器测试通过才算 Docker 完全可用。

## Android 杀死后台任务

关闭 Termux 的电池优化，允许后台活动，并避免清理最近任务。部分 Android 12+ 设备还受 Phantom Process Killer 限制；具体设置随厂商和系统版本变化。

## QEMU 启动慢或初始化超时

```sh
xtmoe qemu status ubuntu-qemu
xtmoe qemu console ubuntu-qemu
xtmoe qemu wait-ready --timeout 1800 ubuntu-qemu
```

没有 `/dev/kvm` 时 QEMU 使用 TCG，首次 cloud-init、APT 和 Docker 安装可能需要较长时间。超时不会删除 VM。新版等待提示区分“等待 SSH”和“SSH 已连通、等待 cloud-init”；SSH 认证失败或进程退出时立即报错。

如果状态是 `stale-pid`，说明保存的进程已退出，此时 `exec` 无法进入客体，继续等待 cloud-init 无效。先查看 `status` 输出的原因和 VM 目录中的 `startup.log`（启动标准错误）、`serial.log`（客体串口）、`qemu.log`（调试日志）。`unverified-pid` 则表示权限或身份校验问题，不等于停止，禁止直接删除 PID/socket 后重新启动。不要仅据 `stale-pid` 判断是内存不足，也不要先重装系统盘。

SSH 可用后，再检查 `/var/log/cloud-init-output.log` 和 `/var/log/xtmoe-firstboot.log`；最近一次探测错误保存在 VM 目录的 `readiness.log`。更多说明见 [QEMU 初始化诊断](QEMU.md#等待初始化与离线诊断)。

## QEMU SSH 端口冲突

停止 VM 后选择未占用端口重新创建，或检查：

```sh
ss -ltn
xtmoe qemu ports ubuntu-qemu
```

所有转发默认绑定 `127.0.0.1`。端口映射只在下一次启动时生效，因此运行中的 VM 不允许修改映射。
