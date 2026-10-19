# XTMOE v1.0.0

面向 Android Termux 的 PRoot / Chroot Ubuntu 管理工具。以中文交互向导集中管理安装、容器、服务、网络、代理和数据；无需记忆大量维护命令。

## 支持范围

- Android 7.0 / API 24 或更新系统；Android 5、6 不支持。
- PRoot 无需 Root。Chroot 需要有效 Root、私有挂载能力及匹配的原生 Ubuntu Base。
- 目标覆盖 ARM32、ARM64、x86、x86_64；可用模式取决于 Termux 用户空间 ABI 和官方镜像。Ubuntu 24.04 Base 无 i386 镜像，因此 x86 仅尝试 PRoot。
- systemd、Docker、独立 IPv4 网络按能力自动启用，不能仅凭手机品牌或内核版本保证全部支持。
- 当前真机证据覆盖单台 ARM64 Android 设备；其他组合是适配目标，不是已实测承诺。

详见 [兼容性矩阵](docs/COMPATIBILITY.md)。优先使用 F-Droid 或官方 GitHub Termux；Google Play 分支按实验性环境检测。

## 安装和主要入口

```sh
pkg update
pkg install -y git
git clone https://github.com/seagullz4/xtmoe.git xtmoe
cd xtmoe
sh termux.sh
xtmoe doctor
xtmoe on
```

`xtmoe on` 包含 PRoot、Chroot、系统列表、代理设置和程序维护。按编号选择，0 返回。恢复、重装、服务、修复、网络和端口映射通过向导操作；程序更新也提供 `xtmoe update` 快捷命令。

## PRoot 快速开始

```sh
xtmoe proot install ubuntu:24.04 ubuntu
xtmoe proot login ubuntu
xtmoe proot exec ubuntu -- uname -a
xtmoe proot list
xtmoe proot ps
xtmoe proot stop ubuntu
xtmoe proot backup ubuntu "$HOME/ubuntu-backup.tar.gz"
xtmoe proot update-system ubuntu
xtmoe proot status ubuntu
xtmoe uninstall proot ubuntu
```

PRoot 使用当前 proot-distro 的原生架构能力；缺少镜像或依赖时报告失败，不自动换发行版。

新装默认PRoot Ubuntu会询问SSH端口：手动输入可用高端口，回车随机选择未使用端口；初始账号为 `root / 123456`，配置成功后启动后台SSH会话。端口和启动操作在PRoot运行管理菜单，初次登录后请用 `passwd` 改密。详见 [PRoot SSH说明](docs/PROOT.md#初始-ssh-与端口选择)。

## Chroot 快速开始

```sh
xtmoe chroot prepare
xtmoe doctor
xtmoe chroot install ubuntu 24.04 ubuntu
xtmoe chroot systemd-login ubuntu
xtmoe chroot stop ubuntu
xtmoe chroot status ubuntu
# 删除前先停止并备份：
xtmoe uninstall chroot ubuntu
```

安装默认完成基础 Ubuntu，再配置支持的 systemd、Docker 和独立网络。能力缺失会明确说明；下载、配置或启动失败仍真实报错并保留系统。快捷入口 `systemd-login` 按容器实际运行方案进入，不代表任何手机都能运行 systemd。

新建 Chroot Ubuntu 的初始 SSH 账号为 `root / 123456`，默认 systemd 方案会启动 SSH；首次登录后请用 `passwd` 修改公开初始密码。局域网连接需自行添加端口映射，旧容器不自动迁移。详见 [SSH 登录说明](docs/CHROOT.md#新容器-ssh-登录)。

## 基础命令

```sh
xtmoe on
xtmoe doctor
xtmoe list
xtmoe list --all --no-prompt
xtmoe update
xtmoe version
xtmoe help
```

程序更新支持 `xtmoe update`；确认丢弃源码本地修改和未跟踪文件时使用 `xtmoe update --force`，或在程序维护菜单选择强制更新。卸载程序和高级容器操作在向导中选择。其余旧版命令别名不提供。

## 数据与安全

配置、数据和缓存位于 Termux 用户目录的 `.config/xtmoe`、`.local/share/xtmoe`、`.cache/xtmoe`。程序更新不重建现有容器；卸载程序保留数据，删除指定容器另行确认。Root 操作可能影响手机，Chroot 不是安全沙箱。

独立网络优先，首次探测不支持时说明采用共享网络。已有明确网络设置不会被更新静默切换。端口映射默认关闭，由用户在向导中添加；填写 `auto:端口` 或只填写端口可自动跟随当前 Wi-Fi/热点/有线 LAN 私网 IPv4，断网暂停、地址改变重绑定，也支持固定 IPv4。IPv6 外网暂不提供。代理设置只管理显式代理，不控制手机 VPN。

## 文档

[安装与维护](docs/INSTALL.md) · [兼容性](docs/COMPATIBILITY.md) · [PRoot](docs/PROOT.md) · [Chroot](docs/CHROOT.md) · [代理](docs/PROXY.md) · [操作指南](docs/OPERATIONS.md) · [排障](docs/TROUBLESHOOTING.md) · [架构](docs/ARCHITECTURE.md) · [验收范围](docs/ANDROID_VALIDATION.md) · [路线图](docs/ROADMAP.md) · [变更记录](CHANGELOG.md)
