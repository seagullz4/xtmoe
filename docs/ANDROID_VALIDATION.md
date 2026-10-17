# Android 真机验收记录

## 2026-10-18：Android 13 / ARM64 / KernelSU

在用户授权的 Redmi Note 9 5G（M2007J22C，cannon）通过 USB ADB 实测。ZeroTermux 实际包名为 `com.termux`，使用标准 Termux 路径。内核 `4.14.336-GinHalion`，Root 为 KernelSU。以下结果只适用于该设备/内核/网络状态，不代表全部 Android 4.14 设备。

### 实际故障与修复

1. systemd 启动需显式容器身份和只读 sysfs/SELinux 视图；不通过关闭宿主 SELinux 修复。
2. nft NAT/addrtype 规则失败；内核启用 legacy NAT，但缺少 nft NAT chain/compat 配置。独立 netns 实测 legacy 后，选择 iptables/ip6tables legacy。
3. Docker 29 的 containerd OverlayFS snapshotter 在加密 F2FS 数据目录上挂载失败，内核记录 filesystem not supported。经备份后选择经典 VFS，并关闭 containerd snapshotter；保留原后端数据。
4. 默认 bridge 的转发流量被 Android/VPN 策略路由拒绝。只为其子网和入口接口增加精确规则，跟随当前宿主 VPN 路由，随 Docker 生命周期创建/清理。

### 已取得的真机证据

- 严格 `apt-get update` 返回 0，Ubuntu noble/updates/backports/security 与 Docker 官方源可访问。
- systemd 为 running，Docker/containerd 均 active。
- Docker 29.9.1、systemd cgroup v2、VFS。
- `docker run --rm hello-world` 返回 0，真实输出 `Hello from Docker!`。
- BusyBox 默认 bridge 容器内 DNS 和 Ubuntu HTTP 请求通过。
- 本机 `127.0.0.1:18081` 映射到测试容器 80 端口，请求成功，测试容器已移除。
- 重启 Docker 后 hello-world 通过；完整停止/再次启动 Chroot 后 Docker 和路由服务自动启动，hello-world 与 bridge DNS/HTTP 再次通过。
- 路由服务单独停止后，记录的精确规则和状态文件消失；重新启动服务后默认 bridge DNS/HTTP 再次通过。
- 已将修复源码同步到设备，以 Termux 普通 UID 执行安装器与 doctor，再通过公共命令 `xtmoe chroot repair --accept-host-network-changes ubuntu` 完整续跑，返回 0，实际拉取和容器运行均通过，阶段元数据由流程更新。
- 宿主 SELinux 操作前后均为 Permissive，修复未修改它；没有足够历史证据判断最初模式的来源。

### 不应推断为通过的项目

- VFS 性能、长期压力测试、全部镜像/应用、特权容器或任意 OCI 配置。
- 额外 Compose/自定义网络、IPv6 容器出站、切换 VPN 后的自动实时刷新。
- Android 手机开机自动启动、其他 Root 方案或其他设备。
- 1Panel 安装和功能：本次不自动安装 1Panel。
- 重装、备份恢复、卸载无残留的完整破坏性矩阵：没有为了验收而删除用户现有容器。

本次未禁用 SELinux、刷写内核、清空宿主防火墙或删除用户 Docker 数据。后端和路由修改有明确授权；运行时备份保存于用户设备，不上传到仓库。
