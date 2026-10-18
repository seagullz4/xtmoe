# 测试

在 Bash 环境中运行：

```sh
bash tests/run.sh
```

测试使用临时 HOME、PREFIX、`proot-distro` 和 `tsu` 模拟器，不会创建真实容器或执行真实挂载。覆盖范围：

- 安装器复制布局；
- 主命令、统一向导、列表和模式帮助；
- `tests/menus.sh` 覆盖三种模式的分组、Chroot 四类精简菜单、systemd/Docker/网络选定容器后的连续操作、数字选目标、非法输入、返回/EOF、取消旧目标、参数边界、恢复无已装系统、危险操作确认保留和重复导航栈深度；均调用记录后端，不做真实删除或安装；
- PRoot 安装、执行、状态、系统更新、重装、名称校验和删除确认；
- Chroot 阶段元数据、默认安装与网络范围提示、严格能力门控、绑定配置和路径校验；
- `tests/docker-runtime.sh` 覆盖 nft 规则失败而 legacy 实测通过、两种后端失败、实际 OverlayFS 探测与经典 VFS 完整配置、保留已有配置/数据，以及精确策略路由的 native/no-op、VPN 出口、优先级冲突、回滚和重复停止；
- `tests/chroot-init.sh` 覆盖新安装预检、init/repair 阶段顺序与幂等续跑、偏好保留、失败阻断、锁冲突、重装预检保留数据、Docker 依赖顺序/错误分类、APT 服务策略恢复、NSS 修复和 alternatives 链接；不执行真实包安装或挂载；
- 启动/修复回归执行实际生成的服务探测与路由安装脚本，覆盖 Docker 最终包安装后恢复 DNS、已激活 oneshot 再次刷新、停止 Docker socket、重启前停止失败阻断、保留已停止服务、总线/网络检测错误传播和非托管文件保护；
- 代理回归覆盖大小写环境归一化、NO_PROXY 本机访问、注入换行拒绝、systemd `%` 转义、仅清理托管配置，以及代理远程解析场景仍必须通过实际 APT 验证；
- systemd 验证使用生产生成脚本与模拟时钟，覆盖 starting 转 running、探测超时重试、没有 failed 单元但存在待完成任务、D-Bus 权限错误、空输出、总等待超时和命令执行失败；不再用始终直接返回 running 的夹具代替启动阶段验证；
- systemd 启动适配覆盖清理环境后传入容器身份、拒绝宿主 mount namespace、只读保护非 cgroup sysfs 子挂载、保护失败中止、procfs 挂载失败阻断，以及 tsu 失败后 su 回退；真实挂载与宿主 SELinux 模式保持不变另由 Android 冒烟测试验收；
- QEMU 架构、配置、端口、向导、Cloud Image 与生命周期参数校验；
- `tests/audit.sh` 由主测试载入，集中覆盖菜单失败中止、配置/端口注入拒绝、归档预检、Docker 部分失败与重装保留旧盘等失败路径；
- QEMU 离线回归覆盖启动返回成功但进程未就绪、PID 无末尾换行、磁盘字段重排、PID 复用/权限受限、跟踪文件保护、SSH 与 cloud-init 阶段区分、认证失败快速退出、进程中途退出和初始化超时保留磁盘；使用进程参数夹具、模拟 SSH 与时钟，不启动真实 VM、不访问网络；
- Root 助手拒绝任意基础目录，并验证 namespaced systemd/cgroup 启动结构。

测试不能替代 Android 真机上的 PRoot、Root、SELinux、挂载和网络验收，真机矩阵见 `docs/ROADMAP.md`。

## Android 真机冒烟测试

安装 XTMOE 后，在源码目录运行：

```sh
bash tests/android-smoke.sh doctor
bash tests/android-smoke.sh proot
```

Chroot 测试会执行真实 Root 挂载、备份、恢复和删除，只创建带时间戳的临时容器，并要求显式确认风险：

```sh
XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot
```

QEMU 测试会下载约 600 MiB 的 Ubuntu Cloud Image、创建虚拟机并运行 Docker，必须显式确认：

```sh
XTMOE_SMOKE_ACCEPT_QEMU_COST=YES bash tests/android-smoke.sh qemu
```

PRoot 测试覆盖 Ubuntu 安装、命令和文件读写、备份、删除、恢复；Chroot 测试额外覆盖固定 DNS、Ubuntu 源、统一列表、cgroup 检查、Docker 严格门控、只读绑定、完整卸载和 Root 路径。在内核能力完整的设备上必须通过 `docker info`；能力不足时允许初始化返回状态 `2`，但必须验证没有把未安装或不可运行的 dockerd 伪装成可用。

## Ubuntu Base 文件系统生命周期

已有 Ubuntu Base 镜像时，可以在普通 Linux/Git Bash 环境验证不涉及内核挂载的 Chroot 文件逻辑：

```sh
bash tests/rootfs-lifecycle.sh /path/to/ubuntu-base-24.04.x-base-ARCH.tar.gz
```

该测试验证真实镜像解压、DNS、内部备份路径拒绝、备份、标记保护、删除与恢复，并只操作 `mktemp` 创建的临时目录。
