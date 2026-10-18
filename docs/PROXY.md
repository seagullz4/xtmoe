# 统一代理

`xtmoe proxy` 保存 Termux 用户级代理配置，使后续 XTMOE 下载、PRoot/Chroot 会话和 Chroot Docker daemon 使用同一代理。需要先在手机代理软件中启用 HTTP 或混合代理端口；该命令本身不启动代理服务器，也不修改 Android VPN 设置。

## 设置一次，跨会话使用

交互入口为 `xtmoe on` → `6）代理配置`。页面提供设置并开启、开启已保存代理、关闭、状态、连通测试、同步 Chroot 与清除配置；设置时输入 HTTP/混合端口或完整 URL，再输入直连域名/IP。`0` 或回车返回。设置变化后，同一轮向导后续进入/安装操作立即读取新配置，不需要退出向导；清除配置恢复原 Termux 环境。已有 Shell 仍需重新进入。

在普通 Termux 中执行，端口换成代理软件实际配置的端口：

```sh
xtmoe proxy on http://127.0.0.1:10808
# 仅输入端口也可以，等价于上面的本机 HTTP 地址：
xtmoe proxy on 10808
xtmoe proxy status
xtmoe proxy test
```

地址支持 `http://` 和 `https://`，支持 IPv6 与 URL 编码的代理认证信息。这里的协议是代理服务器提供的协议；即使访问 HTTPS 网站，常用的本机混合代理地址仍然是 `http://127.0.0.1:端口`。纯 SOCKS 端口请先在代理软件启用 HTTP/混合监听，不能直接当作 HTTP 地址使用。

配置写入 `~/.config/xtmoe/proxy.conf`，权限 0600；按数据解析，不执行配置内容。状态和测试错误隐藏认证信息。配置状态不代表代理软件已经启动或外网连通，`test` 才会强制通过代理发出实际 HTTP/HTTPS 请求，并保留失败退出码。

也可以指定需要直连的域名/IP，自动补充 localhost、127.0.0.1 和 ::1：

```sh
xtmoe proxy on http://127.0.0.1:10808 --no-proxy example.internal,192.168.0.0/16
```

## 容器如何生效

```sh
xtmoe chroot login ubuntu
xtmoe chroot exec ubuntu -- curl -I https://github.com
xtmoe proot login ubuntu
xtmoe proot exec ubuntu -- curl -I https://github.com
```

PRoot 用 proot-distro 的 `--env` 显式传递代理，Chroot 通过受控 Root 助手只传入代理变量，不继承 Termux PATH/LD_PRELOAD。新建、安装依赖及后续命令自动加载保存配置，不需要每次 export。

启用和关闭时同步已有 Chroot：

- systemd 正在运行：更新 XTMOE 托管的 Docker drop-in；只有配置实际变化且 Docker 已运行时才重启 Docker。保留 containerd，随后刷新默认 bridge 路由。
- Docker 已停止：只更新托管配置，不启动 Docker。
- Chroot 已停止或处于普通挂载会话：保持状态；新进入的会话使用新代理，已经打开的 Shell 需退出重新进入。
- direct dockerd：保存配置，但提示需显式 stop/start daemon；同步返回失败表示尚未完成，不把保存成功说成 daemon 已应用。

重试同步全部或一个 Chroot：

```sh
xtmoe proxy apply
xtmoe proxy apply ubuntu
```

这些命令不重新安装容器、软件包或 1Panel。Docker 的代理配置负责 daemon 拉镜像等请求；`daemon.json`/启动参数中由用户设置的代理优先于环境变量，XTMOE 不覆盖这些自定义配置。不要用 daemon 能拉镜像推断 Docker 应用内已经设置代理。

## 关闭、重新启用与恢复环境配置

```sh
xtmoe proxy off
# 保留原地址，之后可以直接重新启用：
xtmoe proxy on
# 删除保存配置，恢复沿用调用 XTMOE 的 Termux 环境：
xtmoe proxy reset
```

`off` 清除 XTMOE 进程使用的代理变量，并清理其托管的 Docker 代理文件；不修改父 Termux Shell 或第三方 Docker 配置。配置已保存但 Root 不可用、服务同步失败时会返回非零，保存设置仍保留，解决条件后再执行 apply。

## 在 Termux 中使用

一个子进程不能直接修改已经运行的父 Shell。需要让普通 Termux 命令使用保存的代理时，用：

```sh
xtmoe proxy exec -- curl -I https://github.com
# 也可以打开一个带代理环境的子 Shell，退出后回到原会话：
xtmoe proxy exec -- bash
```

这不是全流量透明代理。仅支持代理环境变量的软件会采用这些设置，UDP、任意应用/systemd 服务不自动接管；原生 Android 应用继续由代理软件自身规则管理。

### 开启代理后 ping 不通

`ping` 发送 ICMP，不读取 `http_proxy`/`https_proxy`；保存 HTTP 代理不会让 ICMP 经过 HTTP 端口。手机的 VPN/TUN 仍可能影响 ping，包括数字 IP。因此不能用 `ping google.com` 判断 HTTP 代理是否成功，也不能用 HTTP 成功声称 ping 已修复。

分别验证实际需求（在普通 Termux 执行）：

```sh
xtmoe proxy status
xtmoe proxy test https://www.baidu.com
xtmoe proxy test https://www.google.com
xtmoe chroot exec ubuntu -- curl -I --connect-timeout 10 --max-time 20 https://www.google.com
xtmoe chroot network-check ubuntu
```

状态显示“未保存配置，环境中未设置代理”时，新进程没有可用的代理设置；先用实际 HTTP/混合端口执行 `xtmoe proxy on 端口`，再退出并重新进入旧容器 Shell。新配置不反向修改已经打开的 Shell。

`network-check` 将本地 DNS、数字 IP ICMP、当前环境下的 HTTP/HTTPS 分开显示，DNS 最多等待 15 秒。代理可代为解析目标时，本地 DNS 失败但 HTTP 成功是可能的；这不代表本地 DNS 已正常。数字 IP ping 同样失败时，先检查 VPN/TUN、策略路由、目标 ICMP 限制，而不是反复改 hosts 或重装 Ubuntu。工具不自动修改全局 VPN、添加绕行路由、改写 ping 或固定公共网站 IP。

Docker bridge 应用与 QEMU VM 有自己的回环网络，里面的 `127.0.0.1` 不指向手机代理。它们需单独安排可达的宿主地址/受控转发及应用代理配置；本命令不会自动暴露手机代理端口，也不会配置 Docker 客户端向新应用容器批量注入宿主回环地址。
