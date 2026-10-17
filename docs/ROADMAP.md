# 优化计划与验收状态

XTMOE 直接采用可测试的模块化实现；当前开发版本为 `0.4.0-dev`。

## 已实施

- [x] 新增本地源码安装入口 `termux.sh`；拒绝在 Root shell 中安装。
- [x] 新增统一的 `xtmoe` 命令和 `doctor` 环境诊断。
- [x] PRoot、Chroot 与 QEMU 命令和数据路径完全分离。
- [x] PRoot 使用 Termux 官方 `proot-distro` 后端。
- [x] PRoot 删除增加交互确认和 `--yes` 非交互门槛。
- [x] Chroot 使用 Canonical Ubuntu Base 官方发布页与 SHA-256 校验。
- [x] Chroot 仅在必要操作中调用 `tsu`/`su`，禁止整套程序在 Root HOME 中运行。
- [x] Chroot 增加固定目录、容器名称、路径越界和容器标记检查。
- [x] Chroot 删除前检查挂载；挂载配置不以 Shell 脚本执行。
- [x] 支持登录、单命令、停止、状态、绑定目录、备份、恢复和删除。
- [x] 不再自动修改 Termux 镜像、字体、颜色和键盘布局。
- [x] 重写安装、PRoot、Chroot、QEMU、日常操作和故障排查文档。
- [x] 增加 `xtmoe on` 完整管理向导，以及统一 `list`/`enter`。
- [x] PRoot 增加状态、系统更新和确认后重装。
- [x] Chroot 增加阶段元数据、`repair`、系统更新和确认后重装。
- [x] 新增 Chroot `init` 一键配置已有系统；全新安装在下载前自动准备依赖并检查 Root/空间。
- [x] DNS/NSS 修复、真实严格 APT 源验证、包安装服务策略恢复、阶段失败记录及初始化并发拒绝。
- [x] Docker 内核/权限预检与用户态依赖拆分；alternatives 多层链接按容器根解析，临时网络 namespace 中探测 NAT。
- [x] Chroot 固定公共 DNS，并提供可复现的网络诊断。
- [x] 修复 non-login chroot 继承 Android PATH 导致 install 缺失，以及 systemd-resolved 包配置覆盖固定 DNS；包安装/服务启动后复验网络。
- [x] 普通 Chroot 安装默认无 y 确认，保留 skip 选项及重装/卸载破坏性确认；已在授权设备上删除旧容器、重新克隆并完成空缓存首次安装、更新/修复与重启验收，详见实测记录。
- [x] 增加 cgroup v1/v2 检查和 Chroot cgroup 挂载尝试。
- [x] 增加 Docker 官方源安装、systemd 自动启动、服务管理、日志和 `hello-world` 验收。
- [x] Docker 安装前严格检查 namespace、cgroup、iptables 和 IP forwarding；硬阻断返回状态 2。
- [x] Docker 在临时 namespace 实测 NAT/addrtype/bridge，测试通过后选择兼容后端；全新目标数据目录实测 OverlayFS，必要时配置经典 VFS。
- [x] Android 默认 IPv4 Docker bridge 精确策略路由辅助服务，随 Docker 启停、跟随宿主当前出口；不自动接管自定义网络。
- [x] 新增 ARM64/x86_64 QEMU 完整虚拟机模式、Cloud Image 校验、cloud-init、SSH、端口和生命周期管理。
- [x] QEMU 默认在独立 Ubuntu 内核中安装并分别验证 systemd、Docker daemon 和 hello-world。
- [x] 生命周期复核：菜单失败中止、共享 Docker 安装脚本、direct 会话复用、QEMU 配置重校验及归档预检。
- [x] QEMU 探测带超时，Docker 部分失败返回非零，重装失败保留旧盘和配置。

## 自动验证门槛

- [x] 所有新 Shell 文件通过 `bash -n`。
- [x] 所有新 Shell 文件通过 ShellCheck warning 级别。
- [x] 模拟测试覆盖命令分发、名称校验、删除确认和 Root 路径保护。
- [x] 文档中的 XTMOE 命令均能映射到实际命令集合。
- [x] 提供 Android 真机 `doctor`、PRoot 和显式授权 Chroot 冒烟测试脚本。
- [x] 使用合成 rootfs 验证无挂载的解压、DNS、内部备份拒绝、备份、恢复和删除生命周期。

## Android 真机验收矩阵

以下项目必须在实际设备完成，不能用 Windows/Linux 主机的静态检查替代：

2026-10-18 已取得一台 Android 13 / KernelSU / 4.14.336 / ARM64 设备上的 Ubuntu/systemd、APT、Docker hello-world、默认 bridge DNS/HTTP、本机端口映射和完整 Chroot 重启证据，见 [实测记录](ANDROID_VALIDATION.md)。这不等于下列跨设备矩阵全部通过。

- [ ] Android 8–11、Android 12–14、Android 15+ 至少各一台或对应测试环境。
- [ ] `aarch64` PRoot：安装、登录、执行、停止、备份、恢复、删除。
- [ ] `aarch64` Chroot：Ubuntu 24.04 安装、SHA 校验、登录、DNS、apt、停止。
- [ ] 有完整 namespace/cgroup 能力的设备：Docker 官方源安装、重启自动拉起、`docker info`、`hello-world`。
- [ ] 缺少 pids/devices/IPC 能力的设备：Docker 严格跳过，Ubuntu/systemd 仍保持可用。
- [ ] cgroup v1、v2 和 hybrid 设备分别验证挂载、停止清理和重复启动。
- [ ] 在 Android/Linux 文件系统运行真实 Ubuntu Base 的 `tests/rootfs-lifecycle.sh`；Windows/MSYS 因不能创建 Linux 符号链接而不作为通过证据。
- [ ] Chroot 自定义只读/读写挂载及越界拒绝测试。
- [ ] Chroot 中途下载失败、解压失败、Root 拒绝和挂载失败的恢复测试。
- [ ] Magisk、KernelSU、APatch 至少各验证一种受支持组合。
- [ ] Termux:X11 和 OpenSSH 基础流程。
- [ ] 卸载 busy 时拒绝删除，并在重启后成功清理。
- [ ] ARM64 与 x86_64 Android 分别验证 QEMU TCG；具备 `/dev/kvm` 的设备额外验证 KVM。
- [ ] QEMU Cloud Image、SSH、端口、Docker、停止、备份、恢复和重装完整真机生命周期。

## 后续优化

- [ ] 增加可签名的发布包与固定版本安装清单。
- [ ] 加入离线缓存导入/导出和断点续传状态报告。
- [ ] 根据真机结果维护明确的机型、Android、Root 方案兼容表。
- [ ] 评估 Debian RootFS 的 Chroot 支持；在完成相同校验和真机测试前不开放。
- [ ] 将桌面、音频、SSH 配置改为可重复执行的可选插件，而不是默认安装。

只有自动验证和目标 Android 真机矩阵都完成后，才能把项目状态从开发版提升为稳定版。
