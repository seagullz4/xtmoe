# 代理与联网

通过 `xtmoe on → 代理设置` 保存 HTTP/HTTPS 代理 URL 或手机 HTTP/混合端口，可开启、关闭、查看、测试、同步和清除。

配置权限为 600，认证信息脱敏；不 source/eval 配置。只传入代理白名单变量，不继承 Termux PATH/LD_PRELOAD。配置不会修改已存在的父 Shell，旧 Shell 需要退出重进。

独立 Chroot 中手机的回环代理通过受控 TCP 转接到容器可达的宿主地址，需要 Termux socat。原保存 URL 不变，不要求代理软件改成局域网监听。转接只允许对应容器访问，关闭时回收。

systemd Docker 的托管 drop-in 只在配置实际变化且服务已运行时重启 Docker；不启动已停止容器。direct daemon 在代理变化后需要通过服务菜单重启。

## 边界

- 关闭显式代理不等于关闭 Android VPN。
- 清除配置意味着恢复继承 Termux 环境，不等于强制直连。
- HTTP 代理不承载普通 ping 的 ICMP。
- HTTP 成功不证明直连 DNS、ICMP、APT 或镜像仓库均成功。
- 不自动配置 Docker 应用内部代理。

网络检测与修复在 Chroot 网络菜单中提供。保留 VPN 和用户路由，不通过固定站点 IP、关闭温控/安全配置或忽略错误来伪造成功。
