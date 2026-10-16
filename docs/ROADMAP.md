# 优化计划与验收状态

XTMOE 直接采用可测试的模块化实现，项目版本从 `0.1.0-dev` 起步。

## 已实施

- [x] 新增本地源码安装入口 `termux.sh`；拒绝在 Root shell 中安装。
- [x] 新增统一的 `xtmoe` 命令和 `doctor` 环境诊断。
- [x] PRoot 与 Chroot 命令和数据路径完全分离。
- [x] PRoot 使用 Termux 官方 `proot-distro` 后端。
- [x] PRoot 删除增加交互确认和 `--yes` 非交互门槛。
- [x] Chroot 使用 Canonical Ubuntu Base 官方发布页与 SHA-256 校验。
- [x] Chroot 仅在必要操作中调用 `tsu`/`su`，禁止整套程序在 Root HOME 中运行。
- [x] Chroot 增加固定目录、容器名称、路径越界和容器标记检查。
- [x] Chroot 删除前检查挂载；挂载配置不以 Shell 脚本执行。
- [x] 支持登录、单命令、停止、状态、绑定目录、备份、恢复和删除。
- [x] 不再自动修改 Termux 镜像、字体、颜色和键盘布局。
- [x] 重写安装、PRoot、Chroot、日常操作和故障排查文档。

## 自动验证门槛

- [x] 所有新 Shell 文件通过 `bash -n`。
- [x] 所有新 Shell 文件通过 ShellCheck warning 级别。
- [x] 模拟测试覆盖命令分发、名称校验、删除确认和 Root 路径保护。
- [x] 文档中的 XTMOE 命令均能映射到实际命令集合。
- [x] 提供 Android 真机 `doctor`、PRoot 和显式授权 Chroot 冒烟测试脚本。
- [x] 使用合成 rootfs 验证无挂载的解压、DNS、内部备份拒绝、备份、恢复和删除生命周期。

## Android 真机验收矩阵

以下项目必须在实际设备完成，不能用 Windows/Linux 主机的静态检查替代：

- [ ] Android 8–11、Android 12–14、Android 15+ 至少各一台或对应测试环境。
- [ ] `aarch64` PRoot：安装、登录、执行、停止、备份、恢复、删除。
- [ ] `aarch64` Chroot：Ubuntu 24.04 安装、SHA 校验、登录、DNS、apt、停止。
- [ ] 在 Android/Linux 文件系统运行真实 Ubuntu Base 的 `tests/rootfs-lifecycle.sh`；Windows/MSYS 因不能创建 Linux 符号链接而不作为通过证据。
- [ ] Chroot 自定义只读/读写挂载及越界拒绝测试。
- [ ] Chroot 中途下载失败、解压失败、Root 拒绝和挂载失败的恢复测试。
- [ ] Magisk、KernelSU、APatch 至少各验证一种受支持组合。
- [ ] Termux:X11 和 OpenSSH 基础流程。
- [ ] 卸载 busy 时拒绝删除，并在重启后成功清理。

## 后续优化

- [ ] 增加可签名的发布包与固定版本安装清单。
- [ ] 加入离线缓存导入/导出和断点续传状态报告。
- [ ] 根据真机结果维护明确的机型、Android、Root 方案兼容表。
- [ ] 评估 Debian RootFS 的 Chroot 支持；在完成相同校验和真机测试前不开放。
- [ ] 将桌面、音频、SSH 配置改为可重复执行的可选插件，而不是默认安装。

只有自动验证和目标 Android 真机矩阵都完成后，才能把项目状态从开发版提升为稳定版。
