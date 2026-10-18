# Android 真机验收记录

## 2026-10-18：四类精简菜单、首次安装与代理兼容

本轮在同一台 Android 13 / ARM64 / KernelSU / `4.14.336-GinHalion` 设备通过 ADB 验收；保留用户现有 `ubuntu`，另建 `xtmoe-first-20261018-04`。宿主 VPN 正在使用，SELinux 为 Enforcing，未切换宿主安全模式。

- 以 Termux 应用 UID/GID 及实际附加组运行，执行 `install ubuntu 24.04 xtmoe-first-20261018-04 </dev/null`。新 rootfs 使用官方校验的缓存 Ubuntu Base，Ubuntu 基础组件与 Docker 软件包正常下载；退出 0，无手工 y、无手工 rootfs 配置、无 `repair` 或 `network-repair` 补救。
- 安装完成即验证普通 DNS 文件、固定 nameserver、NSS 和 localhost；systemd、containerd、Docker 和精确路由服务正常，hello-world 成功。
- BusyBox 默认 bridge 容器 DNS 和 HTTP 通过；手机访问 `127.0.0.1:18082` 返回测试网页正文。
- 重启测试发现旧的 Docker 重启同时重启 containerd，日志出现 `Force shutdown daemon`，应用没有正常恢复。日常重启改为保留运行中的 containerd，仅重启 Docker；安装更新运行时时先停 Docker。复测 Docker 停止/开启/重启、systemd 重启、完整停止后通过 login 自动启动，配置 unless-stopped 的测试网页均恢复可访问。
- 用仅监听回环的临时 HTTP/CONNECT 代理实测：Ubuntu curl 返回 HTTP 200，Docker 拉取 BusyBox 成功；代理日志实际记录 Docker registry/auth CONNECT。随后清除 XTMOE 测试代理配置并停止临时代理服务。
- 回到用户原有 `ubuntu`，经正常启动命令使 Docker 和已安装的 1Panel Core/Agent active；1Panel 在实际监听端口返回 HTTP 200。进一步仅在内存中读取现有安全入口并验证其 HTML/脚本页面，确认可打开应用登录页；直接访问根路径显示安全入口提示不算网络失败。没有重装用户容器、自动安装新的 1Panel、修改登录凭据或安全入口，也没有输出账号、密码或入口 URL。
- 更新手机源码与安装命令，`xtmoe doctor` 通过。精简菜单为容器、systemd、Docker、网络/DNS 四组，服务/网络分组一次选择目标后连续操作。

本轮最终模拟回归为 `244 passed, 0 failed`，16 个 Bash 文件语法检查、ShellCheck warning 级别和 `git diff --check` 通过。Git Bash 使用 `MSYS=winsymlinks:nativestrict` 支持链接夹具；直接在 Android Termux 运行全量模拟套件的尝试因 Linux `/usr/bin/env` 夹具及架构假设不适用而失败，不作为通过证据。真实设备的安装、代理、生命周期、HTTP 与备份恢复由独立脚本验收。

真机原始日志与备份仅保存在设备 `~/xtmoe-optimized-evidence-20261018-04/`，本地验收副本位于项目 `dist/validation/`，均不发布。新一轮验证不扩大到自定义 Compose 网络、IPv6、其他 Root/内核或所有 1Panel 功能；上述旧章节仍是各自历史轮次的证据。

## 2026-10-18：Android 13 / ARM64 / KernelSU

在用户授权的 Redmi Note 9 5G（M2007J22C，cannon）通过 USB ADB 实测。ZeroTermux 实际包名为 `com.termux`，使用标准 Termux 路径。内核 `4.14.336-GinHalion`，Root 为 KernelSU。以下结果只适用于该设备/内核/网络状态，不代表全部 Android 4.14 设备。

### 实际故障与修复

1. systemd 启动需显式容器身份和只读 sysfs/SELinux 视图；不通过关闭宿主 SELinux 修复。
2. nft NAT/addrtype 规则失败；内核启用 legacy NAT，但缺少 nft NAT chain/compat 配置。独立 netns 实测 legacy 后，选择 iptables/ip6tables legacy。
3. Docker 29 的 containerd OverlayFS snapshotter 在加密 F2FS 数据目录上挂载失败，内核记录 filesystem not supported。经备份后选择经典 VFS，并关闭 containerd snapshotter；保留原后端数据。
4. 默认 bridge 的转发流量被 Android/VPN 策略路由拒绝。只为其子网和入口接口增加精确规则，跟随当前宿主 VPN 路由，随 Docker 生命周期创建/清理。

### 已取得的真机证据

- 严格 `apt-get update` 返回 0，Ubuntu noble/updates/backports/security 与 Docker 官方源可访问。
- systemd 为 running，Docker/containerd 均 active。
- Docker 29.9.1、systemd cgroup v2、VFS。
- `docker run --rm hello-world` 返回 0，真实输出 `Hello from Docker!`。
- BusyBox 默认 bridge 容器内 DNS 和 Ubuntu HTTP 请求通过。
- 本机 `127.0.0.1:18081` 映射到测试容器 80 端口，请求成功，测试容器已移除。
- 重启 Docker 后 hello-world 通过；完整停止/再次启动 Chroot 后 Docker 和路由服务自动启动，hello-world 与 bridge DNS/HTTP 再次通过。
- 路由服务单独停止后，记录的精确规则和状态文件消失；重新启动服务后默认 bridge DNS/HTTP 再次通过。
- 已将修复源码同步到设备，以 Termux 普通 UID 执行安装器与 doctor，再通过公共命令 `xtmoe chroot repair --accept-host-network-changes ubuntu` 完整续跑，返回 0，实际拉取和容器运行均通过，阶段元数据由流程更新。
- 宿主 SELinux 操作前后均为 Permissive，修复未修改它；没有足够历史证据判断最初模式的来源。

### 不应推断为通过的项目

- VFS 性能、长期压力测试、全部镜像/应用、特权容器或任意 OCI 配置。
- 额外 Compose/自定义网络、IPv6 容器出站、切换 VPN 后的自动实时刷新。
- Android 手机开机自动启动、其他 Root 方案或其他设备。
- 1Panel 安装和功能：本次不自动安装 1Panel。
- 重装、备份恢复、卸载无残留的完整破坏性矩阵：没有为了验收而删除用户现有容器。

本次未禁用 SELinux、刷写内核、清空宿主防火墙或删除用户 Docker 数据。后端和路由修改有明确授权；运行时备份保存于用户设备，不上传到仓库。

## 2026-10-18：删除旧容器、重新克隆后的首次安装

同一设备上，用户另行明确授权删除 `ubuntu` 并从 GitHub 重新拉取项目。旧源码改名保留，诊断日志放在容器外；本节不是用前面已修复的 rootfs 重跑验收。

### 真实复现的首次安装缺陷

- `install: command not found`：Ubuntu 已存在 `/usr/bin/install`，但旧 compatibility 分支的非登录 chroot Shell 继承 Android/Termux PATH。修复为统一清理环境并传入 Ubuntu PATH；显式安装并验证 coreutils、util-linux 等基础工具。
- 安装初期固定 DNS 正常，`systemd-resolved` 包配置随后将 resolv.conf 换成 `127.0.0.53` stub，造成 systemd 启动后 Docker 依赖阶段解析失败。`policy-rc.d` 不能阻止配置文件变更；增加包安装后和 systemd 启动后的 DNS 恢复/实际源访问复验，Docker 依赖与系统更新也恢复 DNS。
- 普通 Chroot install/init/repair 默认执行，不再读取 y，开始前显示宿主网络影响；原确认参数保留兼容，`--skip-docker` 可选择不安装 Docker。破坏性重装/卸载仍保留确认。

### 首次安装证据

代码提交：`8c46a4e7b6783baba77c63f250be9274325260ae`，包含 PATH 修复提交 `24f4d0962cfbe60ecc1b4dd497fe2a266ba321f3`。第一次全新测试暴露 resolved 覆盖后已删除测试容器，再次从 GitHub 克隆上述修正版，使用新的空缓存与新 rootfs；未向新 rootfs 手工补配置。

正常流程为 `sh termux.sh` → `xtmoe doctor` → `xtmoe chroot install ubuntu 24.04 ubuntu </dev/null`。没有使用 --yes，也没有通过管道输入确认。安装直接返回 0，并自动完成：官方镜像重新下载与 SHA-256 校验、基础包、DNS/NSS、systemd、legacy 实测/选择、目标文件系统 OverlayFS 探测与 VFS 配置、Docker 官方源/软件包、registry 拉取、真实 hello-world 运行。安装元数据由公共流程生成 `state=ready`、`docker_state=ready`、`failed_stage` 为空。

安装后的独立验收：

- resolv.conf 为普通文件，固定 DNS 两项存在；NSS 为 `hosts: files dns`。
- install、timeout、mktemp、flock、ip、getent、systemctl 可执行；基础依赖和包状态正常。
- 严格 APT update 访问 Ubuntu 与 Docker 源成功。
- systemd 为 running，docker/containerd/路由服务 active，失败单元为 0；实际使用经典 VFS、systemd cgroup v2。
- hello-world 返回 0；BusyBox 默认 bridge 的 DNS/HTTP 和本机端口映射成功；测试容器、端口已清理。
- 默认 `xtmoe chroot update-system ubuntu </dev/null`、`xtmoe chroot repair ubuntu </dev/null` 均成功，没有再出现 PATH 或 stub DNS 故障。
- 公共 stop 清理旧 PID、挂载和精确路由；systemd-start 后 Docker 自动恢复。重启后的 APT、DNS、hello-world、bridge 网络再次通过。
- 运行时源树保持干净，安装代码来自 GitHub 克隆；未上传私有诊断日志、PROJECT_STATE.md 或 push_github.py。

补充：ADB 的简单 su 切 UID 会遗漏 Android 应用的 inet 等附加组，导致宿主 git/curl 解析失败；测试采用真实应用 UID/GID 及附加组运行安装器，而不是修改 Android DNS 或关闭 VPN。此问题与容器 DNS 覆盖缺陷分别诊断。

本轮按授权实际删除了旧容器及失败的首次测试 rootfs，保留了旧源码和外部诊断日志；不是声称完成跨设备或所有模式矩阵。前节列出的性能、IPv6、自定义网络、其他 Root/机型及 1Panel 限制仍适用。
