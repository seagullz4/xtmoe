# PRoot 使用指南

PRoot 无需 Root，在 Android 内核上运行用户空间；不是完整虚拟机，也不提供原生 systemd 或 Docker daemon 的保证。

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
```

安装按 Termux 用户空间 ABI 选择原生架构。上游镜像没有对应架构时失败，不安装模拟器。镜像名称可使用 proot-distro 当前支持的原生 OCI 镜像，默认 Ubuntu 24.04。

恢复、重装及其他管理操作在 `xtmoe on → PRoot 管理` 中选择。恢复名称来自备份，不能覆盖已有目标。删除前停止会话并备份：

```sh
xtmoe uninstall proot ubuntu
```

代理通过向导配置，重新进入后传给容器；不改变父 Shell 环境。PRoot 的接口可见性和权限仍受 Android 限制，不能用其统计值推断完整宿主能力。性能、后台存活和兼容性依设备实测。
