# 测试

在 Bash 环境中运行：

```sh
bash tests/run.sh
```

测试使用临时 HOME、PREFIX、`proot-distro` 和 `tsu` 模拟器，不会创建真实容器或执行真实挂载。覆盖范围：

- 安装器复制布局；
- 主命令和模式帮助；
- PRoot 安装、执行、名称校验和删除确认；
- Chroot 绑定配置、重复目标和路径校验；
- Root 助手拒绝任意基础目录。

测试不能替代 Android 真机上的 PRoot、Root、SELinux、挂载和网络验收，真机矩阵见 `docs/ROADMAP.md`。

## Android 真机冒烟测试

安装 XTMOE 后，在源码目录运行：

```sh
bash tests/android-smoke.sh doctor
bash tests/android-smoke.sh proot
```

Chroot 测试会执行真实 Root 挂载、备份、恢复和删除，只创建带时间戳的临时容器，并要求显式确认风险：

```sh
XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot
```

PRoot 测试覆盖 Ubuntu 安装、命令和文件读写、备份、删除、恢复；Chroot 测试额外覆盖 DNS、只读绑定、完整卸载和 Root 路径。

## Ubuntu Base 文件系统生命周期

已有 Ubuntu Base 镜像时，可以在普通 Linux/Git Bash 环境验证不涉及内核挂载的 Chroot 文件逻辑：

```sh
bash tests/rootfs-lifecycle.sh /path/to/ubuntu-base-24.04.x-base-ARCH.tar.gz
```

该测试验证真实镜像解压、DNS、内部备份路径拒绝、备份、标记保护、删除与恢复，并只操作 `mktemp` 创建的临时目录。
