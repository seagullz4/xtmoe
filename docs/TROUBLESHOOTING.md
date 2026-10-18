# 排障

先运行 `xtmoe doctor`，记录 Android API、用户空间 ABI、内核、Termux 来源和 Root 状态，再查看模式菜单中的详细诊断。分享日志前删除代理凭据、私钥及个人地址。

| 现象 | 检查方向 |
| --- | --- |
| Android 5/6 | v1.0.0 不支持，请使用 Android 7+ |
| 无 Root | 使用 PRoot；Root 管理器名称不代表授权成功 |
| 镜像不存在 | 检查当前 ABI 是否有原生镜像；不尝试跨架构模拟 |
| 基础 Ubuntu 可用但增强缺失 | 查看 systemd/Docker/network 各能力原因 |
| systemd 启动失败 | 查看日志、PID namespace、真实 cgroup；不安装其他 SELinux policy |
| Docker daemon 可用但容器失败 | 查看存储、cgroup、网络和真实容器错误 |
| HTTPS 成功但 ping 失败 | 分别检查代理、VPN、ICMP；HTTP 不代理 ping |
| 隔离模式启动失败 | 检查 veth、NAT、sysfs、权限；不能静默切换共享 |
| 更新拒绝未提交修改 | 先保存需要保留的源码；确认放弃后执行 `xtmoe update --force` 或菜单强制更新 |
| 换 Wi-Fi 后旧映射不可用 | 旧固定映射先删除，再按 `auto:端口` 添加；自动模式查看实际新 IP，断网时为 `waiting-lan` |
| 映射显示 port-occupied | 宿主同地址/通配地址已监听该协议端口；释放占用后网络助手自动重试 |
| 手机访问不了服务 | 确认服务监听、私有 IP、端口；局域网需手动映射 |
| 后台进程被终止 | 查看 Android 电池/后台限制，不能保证任何 ROM 永久在线 |

网络修复不启动已停止服务。包源访问失败返回真实错误，检查 Termux 软件源或网络；不重建整个系统来解决 DNS。恢复损坏安装优先使用诊断与修复，保留 rootfs 和阶段记录。

独立网络不是安全沙箱；共享网络中关闭接口或清空防火墙会影响手机。不要关闭 SELinux、温控、锁最高频或停止系统调度服务来掩盖错误。
