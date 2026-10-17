# 项目结构与维护约定

XTMOE 的公共入口是 `src/bin/xtmoe`，三个后端共享参数、确认与诊断工具；交互菜单只选择目标和参数，安装与生命周期逻辑由后端执行。

```text
termux.sh                  从源码安装模块，最后替换命令入口
src/bin/xtmoe              命令路由、doctor、自更新、程序卸载
src/lib/common.sh          名称、参数、确认、Termux 与 Root 调用
src/lib/manager.sh         on 向导、编号选择、统一 list/enter
src/lib/proot.sh           proot-distro 适配及软件包更新
src/lib/chroot.sh          Chroot 用户侧编排、阶段元数据、Docker 安装
src/lib/xtmoe-root         提权后的受控挂载、namespace、PID 与清理
src/lib/xtmoe-docker-routing 默认 bridge 的精确 IPv4 策略路由与清理
src/lib/xtmoe-docker-routing.service 随嵌套 Docker 启停，不是 Android 开机服务
src/lib/qemu.sh            Cloud Image、VM、SSH、端口、备份恢复
tests/run.sh               主模拟测试入口
tests/audit.sh             失败路径回归，由 run.sh 载入
tests/chroot-init.sh       Chroot 初始化、续跑、依赖与策略恢复回归
tests/docker-runtime.sh    nft/legacy、目标 OverlayFS 和 Android 路由回归
tests/android-smoke.sh     显式确认后在 Android 执行真实生命周期
docs/                     使用、排障、架构和验收状态
```

## 状态与失败处理

- PRoot 状态来自后端已安装目录和活动会话。
- Chroot 实时状态来自容器标记、受校验的 PID 和挂载；阶段元数据只说明初始化进展。
- Chroot `install` 负责下载/解压后调用共享初始化流水线；`init` 用于主动补全已有系统，`repair` 沿用历史选择重验并续跑，`setup` 只负责基础包。菜单不复制这些逻辑。
- Docker 分为内核/权限预检、用户态依赖、iptables/NAT 与 systemd 完整门控，再执行官方源安装和真实容器验收。软件/服务错误返回 1，明确的能力阻断返回 2。
- QEMU 实时状态来自 QEMU PID 和精确磁盘参数；初始化和 Docker 验证结果独立保存在配置中。
- 菜单操作在独立 Shell 中执行；任一步失败会中止本次操作，并返回菜单。不能把安装函数放进会关闭 Bash `errexit` 的条件中，再依赖隐式退出。
- 破坏性动作先验证目标与停止状态。Docker API、真实容器执行、systemd 和网络分别验收。
- SSH 与 daemon 探测设置超时。需要等待的流程展示阶段或进度，失败保留日志供排查。

## 数据与配置

PRoot 由 Termux 官方后端管理。XTMOE 的 Chroot 与 QEMU 使用分离的配置、数据和缓存目录。配置按数据解析，不作为 Shell 代码执行；QEMU 配置在启动和恢复前重新校验，拒绝未知键、重复键、非法资源和端口。

QEMU 备份只包含恢复所需文件。恢复前检查整个目录清单，拒绝链接、设备、重复成员和非预期路径。Chroot 备份保留 Linux rootfs 符号链接，因此采用独立的 rootfs 生命周期逻辑，不能直接复用 QEMU 归档规则。

## 测试与发布

本地和 CI 应逐文件执行 `bash -n`、运行 ShellCheck warning 级别，然后执行 `bash tests/run.sh`。模拟测试不能作为 Android 挂载、KVM/TCG 或真实 Docker 容器已通过的证据；设备矩阵见 [ROADMAP](ROADMAP.md)。

发布使用项目根目录本地 `push_github.py`：先 `--dry-run` 核对清单，再镜像提交到 GitHub `main`，保留远端历史。`PROJECT_STATE.md`、`push_github.py` 和旧 share/tmoe 文件不属于交付内容。
