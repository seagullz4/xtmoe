# QEMU 完整虚拟机

QEMU 模式运行拥有独立 Linux 内核的 Ubuntu 24.04 VM，适合 Android Chroot 内核缺少 cgroup/namespace、但又需要原生 systemd、Docker 和 Compose 的场景。首版支持 ARM64 和 x86_64 同架构虚拟机，不支持 ARM32、Windows、任意 ISO 或跨架构 VM。

## 准备与安装

交互入口 `xtmoe on` → QEMU 分为安装与准备、虚拟机运行管理、备份恢复与删除、端口转发、Docker 验收五类。SSH 与串口控制台在运行管理，端口增删在端口转发；已有 VM 按数字选择，每页 `0` 或回车返回。所有直接命令保持不变。

先完成 XTMOE 安装和环境检查：

```sh
sh termux.sh
xtmoe doctor
xtmoe qemu prepare
xtmoe qemu install ubuntu-qemu
```

安装时会询问 CPU、内存、磁盘和 SSH 端口，建议值为 2 核、2048 MiB、20 GiB、首个可用的 2222–2299 端口。它会下载约 600 MiB 的 Ubuntu 发布版 Cloud Image，验证官方 SHA-256，创建独立 qcow2 磁盘和每台 VM 独立的 Ed25519 密钥。

非交互安装必须显式提供资源：

```sh
xtmoe qemu install --yes --cpus 2 --memory 2048 --disk-size 20 --ssh-port 2222 ubuntu-qemu
```

cloud-init 创建 `xtmoe` 用户、关闭密码 SSH、配置免密 sudo，并从 Docker 官方仓库安装 Docker Engine、Buildx 和 Compose。初始化默认等待 30 分钟，SSH 探测、API 和容器测试都有超时；每轮探测后报告进度，超时保留 VM。`docker info` 或 `hello-world` 验证失败会返回非零退出码。

## 启动、登录与控制台

```sh
xtmoe qemu start ubuntu-qemu
xtmoe qemu wait-ready ubuntu-qemu
xtmoe qemu ssh ubuntu-qemu
xtmoe qemu exec ubuntu-qemu -- uname -a
xtmoe qemu console ubuntu-qemu
```

`ssh` 使用 VM 专用私钥和 known_hosts。`console` 连接启动串口，按 Ctrl+] 断开；Ctrl+C 会传给客体前台程序。默认未设置控制台密码，进入系统以 SSH 为准。

QEMU 自动检查 `/dev/kvm`。可访问且 QEMU 支持时使用 KVM；否则使用多线程 TCG。同架构 TCG 不需要跨 ISA 模拟，但仍明显慢于 PRoot/Chroot，尤其是首次 APT、Docker 安装和镜像解压。

## Docker 验收

```sh
xtmoe qemu docker-status ubuntu-qemu
xtmoe qemu docker-test ubuntu-qemu
```

`docker-status` 执行 `docker info`，验证 daemon API；`docker-test` 执行 `docker run --rm hello-world`，验证镜像拉取、containerd、runc、cgroup 和实际容器运行。daemon 成功而 hello-world 失败时不能宣称 Docker 完全可用。

XTMOE 不自动安装 1Panel。只有 systemd、Docker daemon 和真实容器均通过后，才应按 1Panel 官方说明人工安装。

## 端口转发

QEMU 使用 user-mode NAT。默认仅监听本机：

```text
127.0.0.1:<SSH宿主端口> → VM:22
```

查看、添加和删除映射：

```sh
xtmoe qemu ports ubuntu-qemu
xtmoe qemu stop ubuntu-qemu
xtmoe qemu port-add ubuntu-qemu 8080 80 tcp
xtmoe qemu port-remove ubuntu-qemu 8080 tcp
xtmoe qemu start ubuntu-qemu
```

修改端口前必须停止 VM。宿主端口只绑定 `127.0.0.1`，不会自动暴露到局域网。XTMOE 拒绝重复、占用中或与 SSH 冲突的端口。

## 状态与停止

```sh
xtmoe qemu status ubuntu-qemu
xtmoe qemu list
xtmoe list --all --no-prompt
xtmoe qemu stop ubuntu-qemu
```

正常停止先通过 SSH 请求 `poweroff`，失败时再向 QEMU monitor 发送 ACPI 关机并等待 30 秒。只有确认普通停止无效后才使用：

```sh
xtmoe qemu stop --force ubuntu-qemu
```

状态区分 `initializing`、`ready`、`stopped`、`stale-pid`、`unverified-pid` 和失败状态。PID 校验同时检查进程类型和独立的 `-drive` 磁盘参数，避免误操作复用 PID；PID 文件末尾没有换行、磁盘参数字段顺序变化不影响识别。

`stale-pid` 表示保存的 PID 已经退出；`unverified-pid` 表示权限不足、PID 文件异常或进程身份不匹配，不能据此认定 VM 已停止。`status` 会在标准错误中显示具体检查原因和日志尾部。遇到无法验证的进程时，`start` 和 `stop` 都保留跟踪文件并拒绝操作，不会向身份不明的进程发送信号。

## 等待初始化与离线诊断

启动会等待 PID、进程身份及串口/monitor socket 就绪，然后才报告成功。`wait-ready` 每轮只发起一次初始化阶段探测，区分：

- 等待 SSH：客体尚未启动到 SSH，或转发端口尚不可达，同时显示最近的 SSH 错误。
- SSH 已连通、等待 cloud-init：系统正在执行初始化或软件安装。
- SSH 认证/主机密钥失败：立即报错，不消耗完整等待时长。
- QEMU 进程退出：立即停止等待并展示日志，不再误报为 cloud-init 慢。

出现 `stale-pid` 时，先运行状态检查，不要删除系统盘或重新安装：

```sh
xtmoe qemu status ubuntu-qemu
tail -n 60 "$HOME/.local/share/xtmoe/qemu/ubuntu-qemu/startup.log"
tail -n 60 "$HOME/.local/share/xtmoe/qemu/ubuntu-qemu/serial.log"
```

`startup.log` 保存 QEMU 启动标准错误；`serial.log` 保存客体启动串口输出，即使未连接控制台也可追查；`qemu.log` 是 QEMU 调试日志，不等同于启动错误日志。`readiness.log` 保存最近一次 SSH/初始化阶段探测的错误。旧版本创建的 VM 在使用新版重新启动后开始记录新日志。

确认状态是 `stale-pid`、日志无须先修复的问题后，可以尝试 `xtmoe qemu start ubuntu-qemu`，再执行 `xtmoe qemu wait-ready --timeout 1800 ubuntu-qemu`。超时保留 VM 和磁盘，可通过 `console` 继续查看。仅凭 `stale-pid` 无法判断是启动参数错误、Android 杀进程还是内存压力，必须结合日志和设备系统记录。

## 更新、备份、恢复和重装

```sh
xtmoe qemu update-system ubuntu-qemu
xtmoe qemu stop ubuntu-qemu
xtmoe qemu backup ubuntu-qemu "$HOME/storage/downloads/ubuntu-qemu.tar.gz"
xtmoe qemu restore "$HOME/storage/downloads/ubuntu-qemu.tar.gz" ubuntu-qemu-copy
xtmoe qemu reinstall ubuntu-qemu
xtmoe qemu remove ubuntu-qemu
```

备份要求 VM 停止，只包含系统盘、seed、配置、端口、固件变量和 SSH 身份；运行 PID、socket 与临时文件不打包。备份包含私钥，文件权限为 `0600`，必须安全保存。恢复会先检查归档目录，拒绝链接、特殊文件、重复或非预期路径，再校验配置资源与端口。ARM64 固件 code 路径会改为本机安装位置。

重装先下载并校验新镜像，再暂存旧系统盘、端口和 SSH 身份，成功后清理旧盘。如果新 VM 初始化失败，旧盘与 `previous.conf`、`previous.ports` 会保留在错误消息所示的 `.名称.reinstall.进程号` 目录，避免失败时丢失原系统。删除要求 VM 已停止，并只接受有效标记、资源配置和受控目录。

## 数据位置

```text
~/.config/xtmoe/qemu
~/.local/share/xtmoe/qemu
~/.cache/xtmoe/qemu/ubuntu/24.04
```

缓存镜像可以重新下载；VM 数据目录和专用 SSH 私钥不能通过重新下载恢复。
