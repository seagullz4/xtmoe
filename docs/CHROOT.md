# Chroot 使用指南

Chroot 需要 Root，使用 Android 内核。读取 [兼容性矩阵](COMPATIBILITY.md) 后安装。它不构成完整安全沙箱。

```sh
xtmoe chroot prepare
xtmoe doctor
xtmoe chroot install ubuntu 24.04 ubuntu
xtmoe chroot systemd-login ubuntu
xtmoe chroot restart ubuntu
xtmoe chroot stop ubuntu
xtmoe chroot status ubuntu
```

快捷 systemd-login 按容器实际方案进入：systemd、direct Docker 或基础 Shell。运行中的服务不会因为退出 Shell 自动停止；停止容器用 stop。`xtmoe chroot restart [名称]` 会安全停止并重新创建 XTMOE 管理的嵌套 systemd 容器，不执行 Android 或内核 reboot；仅适用于 systemd 容器。

## 自动方案

基础挂载、systemd、Docker 和独立网络分别检测。基础 Ubuntu 完成后增强可用功能；不支持的增强功能显示原因，保留可用的基础系统。安装网络、包配置或启动失败返回失败，并保留阶段供向导修复。

systemd 只在独立 PID namespace 内启动，使用实际 cgroup 能力；缺失 controller 不会伪造。没有 systemd 时可按能力使用 direct Docker。Docker 分别报告包安装、daemon、仓库访问及真实容器运行结果。OverlayFS 不可用时，新数据仓库可使用 VFS，已有仓库不自动换存储驱动。

保持 Ubuntu 自定义 hostname、软件配置和用户文件；不覆盖第三方代理。保留 man/doc 还原逻辑及可中断恢复。

## 新容器 SSH 登录

新建的 Chroot Ubuntu 在初始化时设置：用户名 **root**，初始密码 **123456**，容器 SSH 端口 **22/TCP**。默认 systemd 方案会启用并启动 ssh.service，确认服务 active 后才完成该阶段。显式跳过 systemd 的基础模式也会安装/配置 SSH，但需要进入容器手动执行 `/usr/sbin/sshd`，退出基础会话后不保证服务持续运行。

初始密码属于公开弱口令，首次进入后请执行 `passwd` 更换；不要直接暴露到公网。初始化只执行一次，之后程序更新、重复初始化或修复不会把修改后的密码重置成123456。不迁移或修改旧容器的账号配置。PRoot的SSH配置与端口选择另见 [PRoot说明](PROOT.md#初始-ssh-与端口选择)。

手机本机可通过容器私网 IP 连接，如 `ssh root@10.203.0.2`（地址以状态显示为准）。电脑或其他局域网设备需要在网络菜单添加 `auto:2222 → 22/tcp`，随后运行 `ssh -p 2222 root@手机当前局域网IP`。SSH 配置本身不创建宿主端口映射。

## 向导布局

`xtmoe on → Chroot 管理`：

- 容器管理：安装、进入、停止、状态、数据。
- systemd：检查、启动、停止、安全重启容器、状态。安全重启与 `xtmoe chroot restart [名称]` 使用同一生命周期路径。
- Docker：检查、安装/修复、启动、停止、重启、日志。
- 网络与 DNS：检测/修复、实际网络状态、模式、端口映射。
- 诊断与修复：环境能力、服务检查、系统更新、修复、容器命令、目录绑定。

无法使用的动作显示实际错误，不用隐藏错误或假成功使菜单看起来可用。

## 网络

首次自动方案优先独立 IPv4 网络；探测不支持时说明使用共享网络。显式模式不因失败静默改变。修改模式须停止容器。已有配置在程序更新时保留。

独立模式中 Ubuntu 不显示手机 ccmni/wlan 接口，但保留自身 lo、eth0、内核隧道模板及 Docker 接口。地址以菜单状态为准，不能把示例 IP 当成固定地址。手机直接访问私有 IP，服务需监听该地址或 0.0.0.0。

局域网端口映射默认没有，在网络菜单添加时输入 `auto:18080`（只输入 `18080` 也可以），再填写容器端口和 TCP/UDP。`auto` 会跟随识别到的 Wi-Fi、热点、USB/有线 LAN 接口上当前有效的私网 IPv4；多条 LAN 同时连接时会分别显示每个地址。运行中的网络助手每约 5 秒检查一次，换 Wi-Fi 或 DHCP 地址变化后撤销旧地址规则，在新地址重建映射；断网时显示 `waiting-lan` 并保留配置，重新联网后恢复。VPN、蜂窝、Docker/容器虚拟接口及公网 IPv4 不用于自动绑定；无法识别的接口不会被自动选中。

为使映射连接的应答能返回局域网客户端，网络助手还会在本容器专属路由表中加入已启用映射所在 LAN 的直连网段路由；换网、删除映射或停止容器时撤销对应路由。该直连网段的容器访问走 LAN，其他目的地仍沿原有出口（包括 VPN）和不可达保护，不复制 LAN 默认路由，也不改 Android/VPN 路由表。

仍可输入 `192.168.1.123:18080` 绑定手机当前持有的固定 IPv4。原有固定 IP 配置保持固定含义；需要改成自动时，先删除原条目，再按相同端口添加 `auto:18080`。删除自动条目也输入 `auto:18080` 或 `18080`。自动映射会在后来连接的局域网上继续开放相同端口，请只映射需要开放的服务。程序升级后，旧网络助手尚在运行时会拒绝新增自动映射并提示先重启对应容器。

配置保存在容器 `.xtmoe-ports`，停止容器时撤销规则，启动后重建。每个地址单独检查端口占用，冲突显示 `port-occupied`，释放后自动重试；不同容器不能预留冲突的自动/固定映射。列表显示实际地址及 `active`、`pending`、`waiting-lan` 等状态。IP 切换后客户端须访问新地址，已有连接不保证连续。仅监听容器 `127.0.0.1` 的服务不能通过映射访问；需监听容器地址或 `0.0.0.0`。本功能仅用于独立网络。

独立网络仍需受控宿主 NAT 和转发，跟随宿主实际出口。IPv6 外网未提供。共享模式会显示手机接口，Root 网络修改同样会影响 Android，不能自行删除接口。

## 数据

数据菜单提供备份、恢复、重装及删除。备份前停止，恢复拒绝覆盖，删除检查标记、规范路径及运行状态。目录绑定仅限精确指定路径，默认只读，不绑定整个 Android 根目录。

```sh
xtmoe chroot stop ubuntu
xtmoe uninstall chroot ubuntu
```
