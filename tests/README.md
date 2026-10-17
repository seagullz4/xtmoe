# 测试

在 Bash 环境中运行：

```sh
bash tests/run.sh
```

测试使用临时 HOME、PREFIX、`proot-distro` 和 `tsu` 模拟器，不会创建真实容器或执行真实挂载。覆盖范围：

- 安装器复制布局；
- 主命令、统一向导、列表和模式帮助；
- PRoot 安装、执行、状态、系统更新、重装、名称校验和删除确认；
- Chroot 阶段元数据、Docker 网络确认、严格能力门控、绑定配置和路径校验；
- QEMU 架构、配置、端口、向导、Cloud Image 与生命周期参数校验；
- `tests/audit.sh` 由主测试载入，集中覆盖菜单失败中止、配置/端口注入拒绝、归档预检、Docker 部分失败与重装保留旧盘等失败路径；
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
