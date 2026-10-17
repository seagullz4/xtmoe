# XTMOE

XTMOE 0.4.0-dev 是一个从零设计的 Android Termux Linux 环境管理工具，使用可诊断、可测试的命令式实现，并明确分离 **PRoot**、**Chroot** 和 **QEMU** 三种模式。既可以使用 `xtmoe on` 交互向导，也可以使用完整子命令进行自动化。

项目只实现当前架构。安装入口从已经下载的源码树安装，并且不会自动修改 Termux 软件源、字体、键盘布局或颜色主题。

## 选择运行模式

| 项目 | PRoot | Chroot | QEMU |
| --- | --- | --- | --- |
| 需要手机 Root | 否 | 是 | 否 |
| 推荐人群 | 绝大多数用户 | 熟悉 Root 和挂载的用户 | 需要独立内核、完整 Docker 的用户 |
| 安装来源 | Termux `proot-distro` | Canonical Ubuntu Base | Ubuntu 24.04 Cloud Image |
| 性能 | 有转换开销 | 接近原生用户空间 | 无 KVM 时 TCG 较慢 |
| 内核 | 共用 Android 内核 | 共用 Android 内核 | 独立 Linux 客体内核 |
| systemd | 通常不可用 | 嵌套运行、取决于内核 | 客体内原生运行 |
| Docker | 通常不可用 | 取决于 Android 内核 | 默认安装并实际验证 |
| 删除风险 | 较低 | 必须先卸载绑定挂载 | 必须先正常关闭 VM |

普通 Linux 环境请选择 **PRoot**；追求 Chroot 性能且设备已 Root 可选 **Chroot**；需要独立内核和完整 Docker 时选择 **QEMU**。

## 要求

- 从 [F-Droid](https://f-droid.org/packages/com.termux/) 或 [Termux GitHub Releases](https://github.com/termux/termux-app/releases) 安装的当前 Termux；不要使用已经停止维护的旧 Play 商店构建。
- Android 7 或更高版本。
- 至少约 1 GB 可用空间；桌面环境通常需要 3–6 GB。
- Chroot 额外要求 Magisk、KernelSU 或 APatch 等可工作的 Root 方案。
- QEMU 建议至少 2 GiB 可用内存和 10 GiB 可用存储；Cloud Image 下载约 600 MiB。

## 安装

在 Termux 普通用户会话中运行：

```sh
pkg update
pkg install -y git
git clone https://github.com/seagullz4/xtmoe.git xtmoe
cd xtmoe
sh termux.sh
xtmoe doctor
```

不要先执行 `su` 或 `tsu`。XTMOE 仅在 Chroot 的必要步骤中单独申请 Root。

只有 `sh termux.sh` 已成功完成且 `xtmoe doctor` 未报告基础环境错误后，才可以执行后续的 `xtmoe on`、`xtmoe list`、PRoot、Chroot 或 QEMU 管理命令。

## 统一管理向导

完成安装和环境检查后，推荐直接运行：

```sh
xtmoe on
```

向导会先选择 PRoot、Chroot 或 QEMU，再提供安装、进入、停止、更新系统、重装、备份、恢复、卸载和状态检查。菜单中的每项操作都对应可单独执行的公共子命令。

当操作需要已存在的容器时，向导会列出该模式全部容器，例如 `1) ubuntu`、`2) debian`；输入数字即可选择目标容器，无需手工输入名称。输入 `0` 会取消本次操作。新装和恢复仍会要求输入新容器名称。

查看当前正在运行的系统并选择进入：

```sh
xtmoe list
```

查看全部已安装系统但不进入交互选择：

```sh
xtmoe list --all --no-prompt
xtmoe enter chroot ubuntu
```

以后更新只需执行：

```sh
xtmoe update
```

`git pull` 只更新源码目录，不会自动替换 `$PREFIX/bin/xtmoe`；请优先使用 `xtmoe update`。如果当前安装版本还没有该命令，先执行一次：

```sh
cd "$HOME/xtmoe"
git pull --ff-only
sh termux.sh
```

## PRoot 快速开始

```sh
xtmoe proot install ubuntu:24.04 ubuntu
xtmoe proot login ubuntu
```

执行单条命令：

```sh
xtmoe proot exec ubuntu -- uname -a
```

查看、停止和备份：

```sh
xtmoe proot list
xtmoe proot ps
xtmoe proot stop ubuntu
xtmoe proot backup ubuntu "$HOME/ubuntu-backup.tar.gz"
xtmoe proot update-system ubuntu
xtmoe proot status ubuntu
```

卸载 PRoot 镜像及其全部数据：

```sh
xtmoe uninstall proot ubuntu
```

完整说明见 [PRoot 使用指南](docs/PROOT.md)。

## Chroot 快速开始

先阅读 [Chroot 使用指南](docs/CHROOT.md) 中的风险说明，然后运行：

```sh
xtmoe chroot prepare
xtmoe doctor
xtmoe chroot install ubuntu 24.04 ubuntu
xtmoe chroot systemd-login ubuntu
```

退出后确认挂载已经释放：

```sh
xtmoe chroot stop ubuntu
xtmoe chroot status ubuntu
```

停止后卸载 Chroot 镜像及其全部数据：

```sh
xtmoe chroot stop ubuntu
xtmoe uninstall chroot ubuntu
```

安装过程从 Ubuntu 官方发布页选择最新的 24.04.x Ubuntu Base 原生架构镜像，并使用官方 `SHA256SUMS` 校验后才解压。全新交互安装默认初始化 Ubuntu 标准组件、嵌套 systemd、Bash `/bin/sh`，并在内核严格检查通过后安装 Docker Engine。Docker 标准 bridge 会修改 Android 宿主网络规则，因此自动化完整安装必须同时使用：

```sh
xtmoe chroot install --yes --accept-host-network-changes ubuntu 24.04 ubuntu
```

不需要 Docker 时应明确使用：

```sh
xtmoe chroot install --yes --skip-docker ubuntu 24.04 ubuntu
```

若缺少 namespace、pids/devices cgroup controller 等内核能力，命令返回状态 `2`：Ubuntu 和 systemd 保持可用，但 XTMOE 不安装、不启动 Docker，也不会把它报告为可用。修复中断的 APT、systemd 或 Docker 初始化可执行 `xtmoe chroot repair ubuntu`。

如果严格模式被内核阻断，但希望试用不依赖 `systemctl` 的 daemon，可在 Chroot 中显式选择 direct dockerd 兼容模式：

```sh
xtmoe chroot docker-direct-install ubuntu
xtmoe chroot docker-direct-status ubuntu
xtmoe chroot docker-direct-run-test ubuntu
```

它通过 `dockerd --iptables=true` 启动并验证 `docker info`；只有运行测试成功才表示实际容器可运行。该模式不代表 Docker bridge、Compose 或 1Panel 已可靠支持。

## QEMU 快速开始

QEMU 创建拥有独立 Linux 内核的 Ubuntu 24.04 完整虚拟机，不需要手机 Root：

```sh
xtmoe qemu prepare
xtmoe qemu install ubuntu-qemu
```

安装会询问 CPU、内存、磁盘和 SSH 端口，随后下载并校验官方 Cloud Image，通过 cloud-init 配置专用 SSH 密钥和 Docker。进入、验证和停止：

```sh
xtmoe qemu ssh ubuntu-qemu
xtmoe qemu docker-status ubuntu-qemu
xtmoe qemu docker-test ubuntu-qemu
xtmoe qemu stop ubuntu-qemu
```

没有 KVM 时会自动使用 TCG，功能完整但性能明显低于 PRoot/Chroot。完整说明见 [QEMU 使用指南](docs/QEMU.md)。

## 文档

- [安装与升级](docs/INSTALL.md)
- [PRoot 模式](docs/PROOT.md)
- [Chroot 模式](docs/CHROOT.md)
- [QEMU 完整虚拟机](docs/QEMU.md)
- [存储、SSH、桌面、备份等操作](docs/OPERATIONS.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [优化计划与验收状态](docs/ROADMAP.md)
- [项目结构与维护约定](docs/ARCHITECTURE.md)

## Android 真机验收

安装后先运行只读检查，再运行 PRoot 生命周期测试：

```sh
bash tests/android-smoke.sh doctor
bash tests/android-smoke.sh proot
```

Chroot 冒烟测试会实际申请 Root、挂载、备份、恢复并删除名称带时间戳的测试容器，因此要求显式确认：

```sh
XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot
```

QEMU 冒烟测试会下载大型镜像并创建临时 VM，必须单独确认：

```sh
XTMOE_SMOKE_ACCEPT_QEMU_COST=YES bash tests/android-smoke.sh qemu
```

测试范围和剩余机型矩阵见 [测试说明](tests/README.md) 与 [ROADMAP](docs/ROADMAP.md)。

## 安全边界

- PRoot、Chroot 和本工具默认配置的 QEMU 都不应当作为运行不可信程序的安全边界。
- Chroot 中的 root 与 Android 共用内核；把宿主目录挂入容器后，容器可以修改该目录。
- 删除逻辑只接受 XTMOE 自己的数据目录和带 `.xtmoe-chroot` 标记的容器，并拒绝删除仍有挂载的容器。
- 不要把整个 `/data`、`/` 或 Termux `$HOME` 以可写方式挂入 Chroot。
- 删除前先备份，并执行 `xtmoe chroot stop <名称>`。
- QEMU 默认只在 `127.0.0.1` 转发端口；备份包含 VM 数据和 SSH 私钥，必须安全保存。

## 项目状态

PRoot 以 Termux 官方 `proot-distro` 为后端，Chroot 使用受控 Root 助手，QEMU 使用同架构 Ubuntu Cloud Image 和独立客体内核。Windows 开发环境只能完成静态与模拟测试；Android 上的挂载、KVM/TCG、Cloud Image 启动、网络和 Docker 必须真机验收。当前进度记录在 [ROADMAP](docs/ROADMAP.md)。

## 许可证

项目使用 Apache License 2.0；上游著作权来源见 `Copyright`。
