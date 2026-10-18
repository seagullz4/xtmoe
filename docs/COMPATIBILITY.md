# 兼容性与能力矩阵

本表区分产品支持条件、运行前探测和真实验收。通过某台手机的测试不代表全部安卓设备通过。

| 环境 | PRoot | Chroot |
| --- | --- | --- |
| Android 5/6 | 不支持 | 不支持 |
| Android 7+、有效 Termux 包环境 | 根据原生镜像和 PRoot 实测 | 另需 Root 与挂载能力 |
| 无 Root | 可尝试 | 不可用 |
| ARM64 / aarch64 用户空间 | 原生镜像可用时 | Ubuntu Base arm64 |
| ARM32 / arm 用户空间 | 原生镜像可用时 | Ubuntu Base armhf |
| x86_64 用户空间 | 原生镜像可用时 | Ubuntu Base amd64 |
| x86 / i686 用户空间 | 原生镜像可用时 | Ubuntu 24.04 无 i386 Base，不提供 |
| 64 位内核、32 位 Termux | 按 32 位用户空间选择 | 按 32 位用户空间选择 |

Android 下限依据 [Termux 官方安装说明](https://github.com/termux/termux-app#installation)。镜像架构依据 [Ubuntu Base 官方目录](https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/)。不做跨架构模拟；镜像不存在时清楚报告，不静默换镜像。

## 内核能力

没有适用于所有 ROM 的单一内核版本分界。厂商可裁剪功能，Root/SELinux 也可阻止本来存在的能力，因此内核版本仅作诊断。

| 功能 | 关键条件 | 缺失后的行为 |
| --- | --- | --- |
| PRoot | 可运行的 proot-distro、原生用户空间和所需系统调用 | 报告启动失败，保留数据 |
| 基础 Chroot | Root、chroot、私有 mount namespace、所需设备/文件系统访问 | 不继续安装，提示 PRoot |
| systemd | 基础能力、PID namespace、可挂载 cgroup、真实 systemd 就绪 | 前置缺失时选择基础 Chroot；实际启动错误则保留现场并失败 |
| Docker | namespace、cgroup controllers、权限、可用网络和存储后端、真实容器运行 | 前置缺失时跳过；daemon/容器失败不冒充成功 |
| 独立网络 | network namespace、veth、独立 sysfs、NAT/conntrack、转发及策略路由 | 自动方案在安装前说明共享模式；显式隔离启动失败不降级 |
| IPv6 外网 | 本版本未实现 | 明确标为未提供 |

默认自动增强。没有 systemd 但 direct Docker 条件满足时可采用 direct；两者都不支持时保留基础 Ubuntu。

## Termux 与 Root

推荐 F-Droid 或官方 GitHub，插件应来自相同签名来源。Google Play 是单独维护的实验性分支，可能有差异，不将其统一判为停更。使用当前软件包，proot-distro 需要提供 --name 和原生架构选项；不兼容旧接口。

Root 通过 tsu/su 的实际授权检测，不按管理器名称放行。不关闭 SELinux，不加载第三方 policy，不修改温控/CPU，也不替换内核来通过检查。

## 检测边界

doctor 只读展示版本、架构、Root、依赖和 namespace/cgroup 可见性。安装与诊断菜单的深度检查在临时 namespace 中真实操作后清理。发现权限错误或工具执行异常时不会将其伪装为支持。

网络环境、空间和镜像可达性是独立条件。DNS、ICMP、HTTP/HTTPS、APT、Docker 仓库应分别检查。不同 VPN 的分应用策略、厂商进程回收和电池限制无法由通用脚本保证。
