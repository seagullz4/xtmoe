# XTMOE

XTMOE 0.3.0-dev 是一个从零设计的 Android Termux Linux 环境管理工具，使用可诊断、可测试的命令式实现，并明确分离 **PRoot** 和 **Chroot** 两种模式。既可以使用 `xtmoe on` 交互向导，也可以使用完整子命令进行自动化。

项目只实现当前架构。安装入口从已经下载的源码树安装，并且不会自动修改 Termux 软件源、字体、键盘布局或颜色主题。

## 选择运行模式

| 项目 | PRoot | Chroot |
| --- | --- | --- |
| 需要手机 Root | 否 | 是 |
| 推荐人群 | 绝大多数用户 | 熟悉 Root、挂载和系统恢复的用户 |
| 安装来源 | Termux 官方 `proot-distro` | Canonical Ubuntu Base 官方镜像 |
| 性能 | 有系统调用转换开销 | 接近原生用户空间性能 |
| 隔离性 | 不是强安全沙箱 | 不是安全沙箱，与 Android 共用内核 |
| systemd | 通常不可用 | 默认尝试嵌套 systemd；能力取决于 Android 内核 |
| Docker | 不支持 Docker daemon | 通过严格内核门控后可安装；不保证所有 Android 内核可用 |
| 删除风险 | 较低 | 必须先卸载绑定挂载 |

不确定时请选择 **PRoot**。

## 要求

- 从 [F-Droid](https://f-droid.org/packages/com.termux/) 或 [Termux GitHub Releases](https://github.com/termux/termux-app/releases) 安装的当前 Termux；不要使用已经停止维护的旧 Play 商店构建。
- Android 7 或更高版本。
- 至少约 1 GB 可用空间；桌面环境通常需要 3–6 GB。
- Chroot 额外要求 Magisk、KernelSU 或 APatch 等可工作的 Root 方案。

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

只有 `sh termux.sh` 已成功完成且 `xtmoe doctor` 未报告基础环境错误后，才可以执行后续的 `xtmoe on`、`xtmoe list`、PRoot 或 Chroot 管理命令。

## 统一管理向导

完成安装和环境检查后，推荐直接运行：

```sh
xtmoe on
```

向导会先选择 PRoot 或 Chroot，再提供安装、进入、停止、更新系统、重装、备份、恢复、卸载和状态检查。菜单中的每项操作都对应可单独执行的公共子命令。

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

## 文档

- [安装与升级](docs/INSTALL.md)
- [PRoot 模式](docs/PROOT.md)
- [Chroot 模式](docs/CHROOT.md)
- [存储、SSH、桌面、备份等操作](docs/OPERATIONS.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [优化计划与验收状态](docs/ROADMAP.md)

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

测试范围和剩余机型矩阵见 [测试说明](tests/README.md) 与 [ROADMAP](docs/ROADMAP.md)。

## 安全边界

- PRoot 和 Chroot 都不应当作为运行不可信程序的强隔离沙箱。
- Chroot 中的 root 与 Android 共用内核；把宿主目录挂入容器后，容器可以修改该目录。
- 删除逻辑只接受 XTMOE 自己的数据目录和带 `.xtmoe-chroot` 标记的容器，并拒绝删除仍有挂载的容器。
- 不要把整个 `/data`、`/` 或 Termux `$HOME` 以可写方式挂入 Chroot。
- 删除前先备份，并执行 `xtmoe chroot stop <名称>`。

## 项目状态

PRoot 以 Termux 官方 `proot-distro` 为运行后端；Chroot 使用独立的受控实现。Windows 开发环境可以完成静态检查和模拟测试，但挂载、SELinux、Root 授权与 Android 厂商内核差异必须在真实设备上完成最终验收。当前进度记录在 [ROADMAP](docs/ROADMAP.md)。

## 许可证

项目使用 Apache License 2.0；上游著作权来源见 `Copyright`。
