# XTMOE Termux v2

TMOE 是 Android Termux 上的 Linux 环境管理工具。本分支正在把旧版大型交互脚本重构为可诊断、可测试的命令式实现，并明确分离 **PRoot** 和 **Chroot** 两种模式。

本仓库只保留重制版代码，不包含旧版 `share` 脚本树。安装入口只从已经下载的源码树安装，并且不会自动修改 Termux 软件源、字体、键盘布局或颜色主题。

## 选择运行模式

| 项目 | PRoot | Chroot |
| --- | --- | --- |
| 需要手机 Root | 否 | 是 |
| 推荐人群 | 绝大多数用户 | 熟悉 Root、挂载和系统恢复的用户 |
| 安装来源 | Termux 官方 `proot-distro` | Canonical Ubuntu Base 官方镜像 |
| 性能 | 有系统调用转换开销 | 接近原生用户空间性能 |
| 隔离性 | 不是强安全沙箱 | 不是安全沙箱，与 Android 共用内核 |
| systemd | 通常不可用 | 取决于 Android 内核；本项目不承诺支持 |
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
tmoe doctor
```

不要先执行 `su` 或 `tsu`。TMOE 仅在 Chroot 的必要步骤中单独申请 Root。

## PRoot 快速开始

```sh
tmoe proot install ubuntu:24.04 ubuntu
tmoe proot login ubuntu
```

执行单条命令：

```sh
tmoe proot exec ubuntu -- uname -a
```

查看、停止和备份：

```sh
tmoe proot list
tmoe proot ps
tmoe proot stop ubuntu
tmoe proot backup ubuntu "$HOME/ubuntu-backup.tar.gz"
```

完整说明见 [PRoot 使用指南](docs/PROOT.md)。

## Chroot 快速开始

先阅读 [Chroot 使用指南](docs/CHROOT.md) 中的风险说明，然后运行：

```sh
tmoe chroot prepare
tmoe doctor
tmoe chroot install ubuntu 24.04 ubuntu
tmoe chroot login ubuntu
```

退出后确认挂载已经释放：

```sh
tmoe chroot stop ubuntu
tmoe chroot status ubuntu
```

安装过程从 Ubuntu 官方发布页选择最新的 24.04.x Ubuntu Base 原生架构镜像，并使用官方 `SHA256SUMS` 校验后才解压。

## 文档

- [安装与升级](docs/INSTALL.md)
- [PRoot 模式](docs/PROOT.md)
- [Chroot 模式](docs/CHROOT.md)
- [存储、SSH、桌面、备份等操作](docs/OPERATIONS.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [旧版容器迁移](docs/MIGRATION.md)
- [优化计划与验收状态](docs/ROADMAP.md)

## Android 真机验收

安装后先运行只读检查，再运行 PRoot 生命周期测试：

```sh
bash tests/android-smoke.sh doctor
bash tests/android-smoke.sh proot
```

Chroot 冒烟测试会实际申请 Root、挂载、备份、恢复并删除名称带时间戳的测试容器，因此要求显式确认：

```sh
TMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot
```

测试范围和剩余机型矩阵见 [测试说明](tests/README.md) 与 [ROADMAP](docs/ROADMAP.md)。

## 安全边界

- PRoot 和 Chroot 都不应当作为运行不可信程序的强隔离沙箱。
- Chroot 中的 root 与 Android 共用内核；把宿主目录挂入容器后，容器可以修改该目录。
- 新版删除逻辑只接受 TMOE 自己的数据目录和带 `.tmoe-chroot` 标记的容器，并拒绝删除仍有挂载的容器。
- 不要把整个 `/data`、`/` 或 Termux `$HOME` 以可写方式挂入 Chroot。
- 删除前先备份，并执行 `tmoe chroot stop <名称>`。

## 项目状态

新的 PRoot 路径以 Termux 官方 `proot-distro` 为运行后端；Chroot 路径为独立的新实现。Windows 开发环境可以完成静态检查和模拟测试，但挂载、SELinux、Root 授权与 Android 厂商内核差异必须在真实设备上完成最终验收。当前进度记录在 [ROADMAP](docs/ROADMAP.md)。

## 许可证

项目主体使用 Apache License 2.0；个别继承的第三方文件使用其各自许可证，详见 `Copyright`。
