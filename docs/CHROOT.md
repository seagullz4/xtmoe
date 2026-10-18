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

`prepare` 安装 `tsu`、`mount-utils`、`util-linux`、`coreutils`、`curl` 和 `tar`。全新 `install` 也会自动检测并补齐缺少的宿主依赖，在下载前检查 Root、架构、必需命令，以及数据/缓存所在文件系统是否各至少有 2 GiB 可用空间；如果二者在同一文件系统，此检查不是合计 4 GiB 保证，实际应为 Ubuntu 标准组件和 Docker 数据预留更多空间。Root 授权仍由 Magisk、KernelSU 或 APatch 等外部方案提供。

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

1. 检查宿主依赖、Root 和空间，根据 `uname -m` 选择 `arm64`、`armhf` 或 `amd64`；
2. 从 Canonical Ubuntu Base 24.04 发布页寻找最新的 24.04.x 镜像；
3. 下载官方 `SHA256SUMS`；
4. 校验镜像；
5. 以 Root 保留原始 UID/GID 解压；
6. 初始化 hostname、hosts、运行目录和普通文件形式的 resolv.conf，固定 DNS 为 `1.1.1.1`、`8.8.8.8`，修正 `hosts: files dns`；
7. 按原生架构解析 Ubuntu 官方源域名，并执行严格的 APT update，实际验证配置源的下载和签名，不把“DNS 能解析”当作网络验收通过；基础包安装后重新写入普通 DNS 文件，防止 systemd-resolved 包脚本改为 127.0.0.53 stub；systemd 启动后再次修复并实际验证 APT；
8. 安装 Ubuntu 标准组件、systemd、D-Bus 和网络工具，默认切换 `/bin/sh` 到 Bash，启动并验证嵌套 systemd 及基础服务；使用 `--skip-bash-sh` 保留原 Shell；
9. Docker 先做内核/权限检查，再补齐用户态依赖；在临时网络 namespace 中实际创建 addrtype/NAT、bridge/veth；当前后端不兼容且 legacy 实测通过时，备份 alternatives 后切换；同时探测目标数据文件系统的 OverlayFS 挂载；
10. 启用 `containerd`/`docker`，并通过 `docker info` 和 `hello-world` 实际验收。

全新安装及 init/repair 默认执行，不再读取 y；安装前显示 Docker 对宿主网络的影响。不需要 Docker 使用 `--skip-docker`，原 `--yes` 和 `--accept-host-network-changes` 参数仍兼容。重装和卸载仍保留破坏性确认。`--skip-systemd` 则仅准备基础 rootfs 与网络，同时跳过 Docker；后续可使用 `init` 补全。

阶段状态包括 `extracting`、`base-ready`、`network-ready`、`packages-ready`、`system-ready`、`docker-ready`、`ready` 和 `partial`。元数据还保存 `current_stage`、`last_completed_stage`、`failed_stage` 与 systemd/Bash/Docker 安装选择。网络、APT、systemd 或 Docker 中途失败时保留 rootfs，修复外部条件后继续：

```sh
xtmoe chroot repair ubuntu
```

已有自动化命令仍可显式标记宿主网络范围（也可直接执行 repair）：

```sh
xtmoe chroot repair --accept-host-network-changes ubuntu
```

`repair` 重新验证实时网络/服务，幂等补齐软件包，不重新下载解压 rootfs；保留之前选择的跳过 Bash/Docker 设置。仅基础 rootfs 的安装不会因修复而静默启用 systemd。初始化有容器级锁，重复并发执行会拒绝；APT 和临时服务策略修改另行串行化。

## 已有 Ubuntu 一键配置

已有容器、旧版初始化不完整，或希望主动补全 systemd/Docker 时，无需重装：

```sh
xtmoe chroot init ubuntu
# 不安装 Docker，仍完整配置网络、Ubuntu 基础组件和 systemd：
xtmoe chroot init --skip-docker ubuntu
# 自动化完整配置；兼容原网络范围参数：
xtmoe chroot init --accept-host-network-changes ubuntu
# 不改变原 /bin/sh：
xtmoe chroot init --skip-docker --skip-bash-sh ubuntu
```

在 `xtmoe on` → Chroot → 容器管理中，全新系统选择“创建 Ubuntu 容器”，输入名称后自动初始化。已有系统可用上面的 `init` 命令补全；`init` 默认启用 systemd、Bash 和严格 Docker 流程；`repair` 是沿用历史选择的续跑入口。

Chroot 首屏为“容器管理”“systemd 服务管理（systemctl）”“Docker 服务管理”“网络与 DNS”四类。容器页面提供依赖、创建、进入、删除、备份、恢复和状态；systemd 与 Docker 页面均提供前置检查、开启、停止、重启和状态，Docker 另有安装修复和日志。服务和网络页面先选一次目标容器，之后连续操作；所有原直接命令保留，direct 兼容模式只通过直接命令显式选择。

目前不支持跨架构 Chroot。需要跨架构时请使用 PRoot 加 QEMU。

## 登录、命令和初始化

全新安装默认已经完成组件和 systemd/Bash 初始化。交互进入嵌套 systemd：

```sh
xtmoe chroot systemd-login ubuntu
xtmoe chroot systemd-exec ubuntu -- uname -a
```

`chroot login` 会为已配置 systemd 的容器自动启动并验证 systemd，再进入同一会话，使已启用的 Docker/1Panel 服务随之启动；启动失败会报告错误，不静默进入缺少服务的普通 Shell。显式跳过 systemd 的基础环境、未记录 systemd 偏好的旧备份仍使用普通 Chroot Shell；已运行的 direct 模式保持原模式。普通模式仍可用于修复或维护：

```sh
xtmoe chroot login ubuntu
xtmoe chroot setup ubuntu
```

`setup` 仅负责基础包，不等于完整初始化；一键操作请使用 `init`。基础包包括 `ubuntu-standard`、CA 证书、curl、locale、OpenSSH Server、sudo、systemd、D-Bus、Bash、procps、util-linux、kmod、mount、iproute2、iptables 和 iputils-ping。安装时先配置未完成的 dpkg，再执行严格 APT update。临时 `policy-rc.d` 阻止包脚本自动启动服务，成功或失败时恢复原策略（包含原符号链接），之后由嵌套 systemd 管理服务。不会自动安装或启动 1Panel，也不会设置 SSH 密码；Ubuntu 服务启用情况会影响宿主共享网络上的监听端口，需按 [日常操作](OPERATIONS.md#ssh) 检查 SSH 配置与访问范围。

完整网络诊断会打印 DNS、域名解析、数字 IP Ping、Ubuntu 源 HTTP 访问和代理变量是否设置：

```sh
xtmoe chroot network-check ubuntu
xtmoe chroot network-repair ubuntu
```

`network-check` 同时显示共享网络的 IPv4 地址、策略路由、TCP 监听端口、已安装的 Docker/1Panel 服务状态和 Docker 容器端口映射，便于区分 DNS、服务未启动与端口监听问题。`network-repair` 恢复普通 DNS 文件及 hosts/NSS；在 systemd 模式中，仅在 Docker 已运行时安装或刷新 XTMOE 默认 bridge 精确路由服务，然后运行网络检测。不安装软件、不启动已停止的 Docker，也不重启 1Panel；检测失败时仍返回失败。direct 模式只修复 DNS，不接管 systemd 路由服务。

普通 systemd 启动会在前后恢复 DNS，并为已运行的 Docker 刷新默认 bridge 路由；Docker 软件包装完后、首次启动前也会再次恢复 DNS。Docker 开启和重启复用相同修复步骤，避免首次安装完成后仍需手工执行初始化修复。已有激活的路由 oneshot 服务使用 `restart` 重新探测当前网络/VPN，不能依靠 `enable --now` 刷新。

### VPN 与显式代理

推荐先在普通 Termux 使用 `xtmoe proxy on 10808`（换成实际 HTTP/混合端口）保存代理。后续进入、安装依赖和 Docker 拉镜像自动采用；`xtmoe proxy off` 关闭，`xtmoe proxy test` 验证连通性。命令会同步运行中的 systemd Chroot，配置变化时重启运行中的 Docker，不启动已停止容器。详细范围见 [统一代理](PROXY.md)。下面的临时环境变量方式仍兼容。

Android VPN 继续由宿主管理，XTMOE 跟随当前宿主出口。若使用本机 HTTP 代理，在普通 Termux 中先设置代理，再安装或重启 Docker，例如：

```sh
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
xtmoe chroot docker-restart ubuntu
```

XTMOE 仅将 HTTP/HTTPS/ALL_PROXY 及对应大小写变量传入 Chroot 命令和交互 Shell，并补充本机 `NO_PROXY`；不会继承 Termux 的 `LD_PRELOAD` 或工具搜索路径。systemd 启动时同步 `/etc/systemd/system/docker.service.d/90-xtmoe-proxy.conf`，使 Docker daemon 拉镜像也能使用 HTTP/HTTPS 代理，文件权限为 0600；不覆盖其他来源的代理文件。变更代理后用 `docker-restart` 让 daemon 重新读取。取消当前代理时，先在 Termux `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY`，再重启 Docker，只移除 XTMOE 自己生成的代理文件。`all_proxy=socks5h://127.0.0.1:7890` 可供支持 SOCKS 的 curl 等客户端使用；APT 和 Docker daemon 的代理能力仍以各自支持的协议为准。

Chroot 与 Android 共用回环地址，所以这里的 `127.0.0.1:7890` 可以指向手机上的代理。Docker bridge 应用容器有自己的回环地址，不能直接照搬；XTMOE 不覆盖应用自己的代理或 DNS 配置。诊断只显示代理变量是否设置，不打印代理凭据。本地 DNS 失败但明确配置 HTTP/HTTPS 代理时，安装会继续实际验证 APT 源；代理访问失败仍中止，不能仅凭代理变量存在就判定网络可用。

初始化会保留镜像中已有的其他主机映射，并确保 `localhost` 同时映射到 `127.0.0.1` 和 `::1`。每次 `login`、`exec` 或 `setup` 还会自动补齐已有容器缺失的本机名称配置，这可以避免 `sudo: unable to resolve host localhost` 一类的错误。

## 嵌套 systemd

Chroot 不会成为 Android 的 PID 1，因此这里提供的是独立 PID namespace 中的嵌套 systemd。先检查并启动：

```sh
xtmoe chroot systemd-check ubuntu
xtmoe chroot systemd-start ubuntu
xtmoe chroot systemd-status ubuntu
xtmoe chroot systemd-restart ubuntu
xtmoe chroot systemd-login ubuntu
```

上述命令均在普通 Termux 中执行。`/sbin/init` 是容器内的路径，不要把文档或日志里出现的 `exec /sbin/init ...` 复制到 Termux 宿主运行。

启动器按 [systemd 容器接口](https://systemd.io/CONTAINER_INTERFACE/) 清理继承环境并向容器 PID 1 传入 `container=xtmoe`，同时写入容器自己的 `/run/host/container-manager`。容器 `/proc` 必须在新 PID namespace 内成功挂载，失败则停止，不静默沿用 Android 的 procfs。

在私有 mount namespace 中，容器 `/sys` 及其非 cgroup 子挂载（含 SELinux 接口）执行只读 bind remount，cgroup 挂载单独保留；保护失败则拒绝继续启动。这里不执行宿主 `setenforce`，不加载 policy，不通过修改 Ubuntu SELinux 配置来关闭宿主 SELinux。该保护不是安全沙箱或完整内核隔离承诺：Chroot 仍共享内核和高权限，标准 Docker bridge 仍可能改变已明确同意的宿主网络设置。

`.xtmoe-systemd.log` 按启动次数追加记录，每次有时间、namespace 与宿主 SELinux enforce 读数；不会因为重试覆盖上一轮日志。若看见 `SELinux: Could not open policy file ...`，先查看 [SELinux 与提权排障](TROUBLESHOOTING.md#systemd-启动日志出现-selinux-policy-缺失)，不要安装其他发行版 policy 或改变宿主安全模式。

在 systemd 会话中可以直接使用 `systemctl`、`journalctl` 等命令。结束时执行：

```sh
xtmoe chroot systemd-stop ubuntu
```

“已启动并就绪”表示嵌套 PID 与 manager socket 就绪，并不等于全部开机任务完成。完整初始化的 `systemd-verify` 会在最多 120 秒内轮询 `systemctl is-system-running`，逐次显示 `starting`/`initializing` 等真实状态，每次查询也有单独超时。只有 `running`，或基础单元正常的 `degraded` 才能继续；不会把空输出或超时当作成功。

验证失败时显示探测退出码、原始错误、`list-jobs`、failed units、基础服务和最近 journal。`0 loaded units listed` 若来自 `--failed`，只说明没有已失败单元；仍可能有未完成的启动任务。先检查任务和日志，不要重装、批量屏蔽服务或将 `starting` 伪报成 `running`，详见 [systemd 验证排障](TROUBLESHOOTING.md#systemd-verify-显示空状态或一直等待)。

嵌套 systemd 不等于 Android 原生启动服务，也不会绕过缺少 pids cgroup 等内核限制。只要 `systemd-check` 出现 `[缺失]`，就不应继续安装 Docker 或 1Panel。

查看 cgroup v1/v2、挂载点、controller 和 cgroup namespace 能力：

```sh
xtmoe chroot cgroup-check ubuntu
```

XTMOE 只挂载内核真实提供的 cgroup 文件系统。缺少的 `pids`、`devices` 或 namespace 不能通过用户空间脚本补造。

## Bash 作为 `/bin/sh`

完整安装及 `init` 默认把 `/bin/sh` 切换为 Bash，以兼容声明 `#!/bin/sh` 却使用 Bash 数组的第三方脚本。也可以随时显式执行：

```sh
xtmoe chroot use-bash-sh ubuntu
```

该命令通过 dash 的包配置切换默认 Shell，并把 `/bin/sh` 以相对链接指向 Bash。原生 Ubuntu 默认使用 dash；XTMOE 专用容器默认选择 Bash，以兼容部分第三方安装器。拒绝切换时使用 `--skip-bash-sh`；修复会保留记录的选择，旧版未记录此项的容器默认不改动 Shell。

## Docker 生命周期

在安装 Docker 或部署 1Panel 前运行只读内核检查：

```sh
xtmoe chroot docker-check ubuntu
```

它实际尝试创建 mount、PID、network、IPC 和 UTS namespace，并检查 cgroup hierarchy、`pids`、v1 `devices`、OverlayFS、IPv4 转发、iptables 和嵌套 systemd。iptables 的绝对路径/alternatives 链接按容器根目录解析，不会错误解析到 Android 的 `/etc`。仅列出 NAT 表可能漏报不支持 addrtype/NAT 规则的内核，因此检查现在在独立临时网络 namespace 中真正创建并测试规则、bridge/veth，namespace 退出后全部消失。`docker-check` 不修改宿主规则，也不切换后端；安装会提前显示网络风险，再备份并选择实测可用的 legacy。两个后端都失败则停止，不能通过关闭 iptables 伪报可用。

全新且无已有数据/daemon.json 时，会在目标数据文件系统创建临时 lower/upper/work 目录，并在私有 mount namespace 实测 OverlayFS。不能挂载时写入经典 VFS 配置，同时关闭 Docker 29 默认的 containerd snapshotter。VFS 较慢、占用更多空间；不会覆盖用户已有 JSON，也不会自动切换已有数据仓库，以免隐藏原镜像/容器。已有配置仍以实际容器运行验收为准。

Docker 启动后会安装受其生命周期管理的 `xtmoe-docker-routing.service`。若默认 IPv4 bridge 已有转发路由，不增加任何规则；若 Android 策略路由阻止转发，则只为默认 bridge 子网增加精确的出站/返回路由，跟随宿主当前（可能是 VPN）的路由表，不强制绕过 VPN、不改全局默认路由。预留优先级冲突时拒绝覆盖；停止 Docker 时删除本服务记录的精确规则，重启时重新探测。当前不自动接管额外 Compose/自定义网络或 IPv6 出站；更换 VPN/网络后可显式刷新默认 bridge：

```sh
xtmoe chroot systemd-exec ubuntu -- systemctl restart xtmoe-docker-routing.service
```

退出状态 `1` 表示软件/服务或操作异常，`2` 表示内核/权限阻断，不能混报。设备实测记录见 [Android 验收](ANDROID_VALIDATION.md)。

检查通过后安装 Docker 官方仓库版本：

```sh
xtmoe chroot docker-install ubuntu
```

Docker 标准 bridge 会影响 Android 宿主共享网络 namespace 中的 iptables 和 IP forwarding，安装默认执行并提前提示；不希望修改网络应使用 --skip-docker。旧自动化参数仍可使用：

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

安装成功后 `docker.service` 与 `containerd.service` 会被 enable，每次 `xtmoe chroot systemd-start ubuntu` 后由嵌套 systemd 自动拉起。这不等于 Android 开机自启。Docker 停止同时停止 `docker.socket`，防止随后的 Docker 客户端请求通过 socket activation 意外拉起 daemon；开启与重启会刷新默认 bridge 路由。

Docker 有四种必须区分的结果：完全通过；systemd 可用但内核阻断；daemon 可用但 registry/`hello-world` 未验证；软件已安装但 daemon 启动失败。XTMOE 不会把后三者显示为完全可用，也不会自动安装 1Panel。

### 不依赖 systemd 的 direct dockerd 兼容模式

部分 Android 内核无法让嵌套 systemd 完整运行，但仍可能允许 `dockerd` 直接响应。此时不要把它当成严格模式或 1Panel 支持，而是显式选择 direct 兼容模式：

```sh
xtmoe chroot docker-direct-install ubuntu
```

该命令会提前提示 Docker bridge 对 Android 宿主 iptables/IP forwarding 的影响并默认执行，安装 Docker 官方仓库版本，停止已有的嵌套 systemd 会话，然后在独立 mount namespace 内按等价于下列逻辑启动：

```sh
dockerd --iptables=true --host=unix:///var/run/docker.sock
```

XTMOE 将 daemon 的 PID 和日志纳入生命周期管理，因此不要自己在普通 `chroot login` Shell 中后台运行 `dockerd`。直接登录退出后普通 Chroot 会清理挂载，手动后台 daemon 容易遗留 busy 挂载或被会话信号停止。

direct 模式使用独立 PID/mount namespace 托管 daemon，支持重复状态检查。它启动后，`xtmoe chroot login` 与 `exec` 自动进入同一会话；`status` 显示 `direct-docker`。退出登录只退出 Shell，daemon 由 `docker-direct-stop` 或统一 `chroot stop` 管理。严格 systemd 与 direct 模式共用 Docker 包安装脚本，避免两套软件源与依赖配置漂移。

统一列表的 `daemon-ready` 或 `direct-daemon-ready` 仅表示 Docker API 可响应；实际容器运行仍以 hello-world 测试结果为准。

direct 模式命令：

```sh
xtmoe chroot docker-direct-start ubuntu
xtmoe chroot docker-direct-status ubuntu
xtmoe chroot docker-direct-logs ubuntu
xtmoe chroot docker-direct-run-test ubuntu
xtmoe chroot docker-direct-stop ubuntu
```

`docker-direct-status` 等价验证 `docker info`，只说明 daemon API 可用；`docker-direct-run-test` 运行 `docker run --rm hello-world`，才验证 containerd、runc、namespace、挂载和实际容器链路。若前者成功而后者失败，应报告为“daemon 可用、容器运行未验证/失败”，不能据此宣称 Docker 或 1Panel 完全可用。direct 模式与嵌套 systemd 模式不能并存；`chroot stop` 会停止任一种已受 XTMOE 管理的 daemon。

direct 启动显示三个阶段：寻找 daemon 进程（50 次轮询，间隔 0.1 秒，另加进程扫描开销）、等待 Docker socket（约 15 秒）、带 15 秒超时的 `docker info` 验证。失败提示查看 `docker-direct-logs`。只有实际容器测试通过后，元数据才记录 `direct-container-ready`。

每次登录会受控挂载 rootfs 自身、`/proc`、`/sys`、`/dev` 和 `/run`。Shell 正常退出后会尝试卸载；如果容器中留下后台进程，卸载可能失败。

交互登录通过 Termux `util-linux` 提供的 `script` 创建独立伪终端。Ctrl+C 只中断容器内当前前台命令并返回提示符，不会退出容器；使用 `exit` 或 Ctrl+D 才结束登录。`xtmoe chroot exec` 保持非交互模式，不分配伪终端。

systemd/direct 会话的交互登录在进入目标 PID namespace 后，用 Ubuntu 的 `script` 创建控制终端，避免沿用 Android 终端中在容器 PID 视图不可见的前台进程组。这样 `sudo -i`、作业控制和 Ctrl+C 使用容器内一致的终端会话；仅在标准输入和输出都为终端时分配，管道和 `exec` 不改变。已经打开的旧会话需要退出后重新 login。

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

普通安装现已默认执行，原 `--yes` 和 `--accept-host-network-changes` 保留兼容；破坏性删除/重装的 --yes 仍只用于显式确认。手机重启或 Termux 被 Android 杀死后，需要重新执行 `xtmoe chroot systemd-start ubuntu`；嵌套 systemd 不是 Android 启动服务。

更新或不备份直接重装：

```sh
xtmoe chroot update-system ubuntu
xtmoe chroot reinstall ubuntu
```

`reinstall` 会永久删除 rootfs、Docker 镜像、容器和卷，不自动备份；脚本化使用必须添加 `--yes`。

## systemd 兼容边界

systemd 必须在 PID namespace 中作为 PID 1，并使用可写 cgroup。XTMOE 会在内核允许时附加 IPC、UTS 和 cgroup namespace，但不能补造 Android 内核未编译的 controllers。缺少 pids controller 时 systemd 可能启动，但 Docker/1Panel 仍可能降级或失败。`systemd-container` 或 `systemctl` 文件存在并不代表 Android 内核已经满足运行条件。
