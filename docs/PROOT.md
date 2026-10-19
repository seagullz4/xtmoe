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

## 初始 SSH 与端口选择

新装默认 Ubuntu 时会询问 SSH 端口。可以输入1024至65535的可用TCP端口；直接回车则随机分配未占用的高端口，同时避开其他已配置PRoot容器预留的端口。初始账号为 `root`，密码为 `123456`，首次登录后请执行 `passwd` 修改。非交互安装默认自动选择，也可明确指定：

```sh
xtmoe proot install ubuntu:24.04 ubuntu --ssh-port auto
xtmoe proot install ubuntu:24.04 work --ssh-port 22222
```

安装完成会配置OpenSSH并启动独立的proot-distro后台会话，退出安装向导不停止该SSH会话。此功能要求当前proot-distro支持 `login --detach`；SSH自动安装目前面向Ubuntu/Debian apt镜像，其他镜像或依赖安装失败时会明确报错并保留基础容器。

`xtmoe on → PRoot管理 → 容器运行管理` 提供启动SSH、查看端口/状态和重新配置端口。`xtmoe proot status 名称` 也会显示端口。停止活动会话（或 `xtmoe proot stop 名称`）会停止该容器的所有会话，包括SSH；重新选择启动SSH即可恢复。更改端口前先停止该容器活动会话。重复配置保留已修改的密码；重装会按删除系统数据的原有语义重新设置初始密码。

PRoot共享手机网络，不使用Chroot的私网IP和NAT映射。从同一局域网设备使用 `ssh -p 实际端口 root@手机当前IP`，手机本机可使用127.0.0.1。服务监听IPv4通配地址，换网后客户端改用手机新IP；不提供公网穿透。端口选择与最终绑定之间若被其他程序抢占，启动会报错，可在菜单重选，不能保证永久占用。

SSH启动会检查所属会话和实际SSH协议响应，不把仅有配置文件视为运行成功。Android终止Termux后后台会话可能消失，不承诺开机自启或永久在线。容器内日志位于 `/var/log/xtmoe-ssh.log`。

恢复、重装及其他管理操作在 `xtmoe on → PRoot 管理` 中选择。恢复名称来自备份，不能覆盖已有目标。删除前停止会话并备份：

```sh
xtmoe uninstall proot ubuntu
```

代理通过向导配置，重新进入后传给容器；不改变父 Shell 环境。PRoot 的接口可见性和权限仍受 Android 限制，不能用其统计值推断完整宿主能力。性能、后台存活和兼容性依设备实测。
