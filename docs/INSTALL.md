# 安装、更新与卸载

## 安装前检查

请使用当前的 Termux。Termux 应来自 F-Droid 或官方 GitHub Releases，同一设备上的 Termux 插件也必须来自相同来源，否则 Android 签名不同会导致插件无法协同工作。

先在 Termux 中检查基本信息：

```sh
termux-info
getprop ro.build.version.release
uname -m
df -h "$HOME"
```

推荐至少保留 1 GB 空间；安装桌面和开发工具时应预留更多。

## 从源码树安装

```sh
pkg update
pkg install -y git
git clone https://github.com/seagullz4/xtmoe.git xtmoe
cd xtmoe
sh termux.sh
```

安装器会把以下文件放入 Termux 的 `$PREFIX`：

- `$PREFIX/bin/xtmoe`：用户命令；
- `$PREFIX/libexec/xtmoe/`：模块和受控 Root 助手。

配置、数据和缓存分别位于：

```text
~/.config/xtmoe
~/.local/share/xtmoe
~/.cache/xtmoe
```

安装完成后必须先运行：

```sh
xtmoe doctor
```

只有 `doctor` 完成且未报告基础环境错误后，才开始使用 `xtmoe on`、`xtmoe list`、PRoot、Chroot 或 QEMU 管理命令。基础安装器只复制 QEMU 模块，不下载大型虚拟机依赖；使用时执行 `xtmoe qemu prepare`。

Chroot 全新安装会自动检查并补齐宿主依赖，在下载前检查 Root、原生架构及空间，默认完成网络、Ubuntu 标准组件、systemd、Bash 和严格 Docker 初始化。自动化完整安装除 `--yes` 外还必须显式确认 Docker bridge 风险：

```sh
xtmoe chroot install --yes --accept-host-network-changes ubuntu 24.04 ubuntu
```

不需要 Docker 时使用 `--skip-docker`；`--skip-systemd` 仅配置基础 rootfs/网络并同时跳过 Docker。数据/缓存文件系统各至少需要 2 GiB 可用空间，实际容器与 Docker 数据应另留余量。

已有容器使用 `xtmoe chroot init --skip-docker ubuntu` 一键补全 Ubuntu/systemd，或 `xtmoe chroot init --accept-host-network-changes ubuntu` 同时配置严格 Docker。失败后沿用历史选择继续执行 `xtmoe chroot repair ubuntu`，无需重新解压镜像。

## 更新

正常更新使用：

```sh
xtmoe update
```

该命令会检查源码目录没有未提交修改，执行 `git pull --ff-only`，然后以原子替换方式更新已安装命令和模块，并校验安装版本。单独执行 `git pull` 不会更新 `$PREFIX/bin/xtmoe`。

如果当前安装版本还没有 `update` 命令，执行一次引导更新：

```sh
cd "$HOME/xtmoe"
git pull --ff-only
sh termux.sh
xtmoe doctor
```

重新执行安装器只更新程序文件，不删除容器、配置或备份。安装器先替换库文件，最后原子替换命令入口；安装结束会比较源码版本和已安装版本。

`xtmoe update` 只更新 XTMOE 管理程序，不更新容器内软件。容器系统更新使用独立命令：

```sh
xtmoe proot update-system ubuntu
xtmoe chroot update-system ubuntu
```

## 统一向导、列表与进入

以下命令的前提是已在当前 Termux 普通用户会话成功执行 `sh termux.sh`，并已完成上方的 `xtmoe doctor`：

```sh
xtmoe on
xtmoe list
xtmoe list --all --no-prompt
xtmoe enter proot ubuntu
xtmoe enter chroot ubuntu
xtmoe enter qemu ubuntu-qemu
```

`xtmoe list` 默认只显示正在运行的系统，并在交互终端中允许输入编号进入。脚本、管道环境或 `--no-prompt` 只输出表格，不读取标准输入。

`xtmoe on` 的 PRoot 和 Chroot 子菜单会在需要操作已有容器时列出全部容器编号。输入对应数字即可选择容器；输入 `0` 取消，不再需要手工输入名称。安装和恢复操作仍会要求指定新名称。

## 切换 Termux 镜像

XTMOE 不会自动改写 `sources.list`。网络异常时使用 Termux 自带工具：

```sh
termux-change-repo
pkg update
```

这比脚本硬编码第三方镜像更可靠，也能同时处理当前启用的软件仓库。

## 卸载程序

先根据模式备份并移除容器。然后仅删除程序文件：

```sh
rm -f "$PREFIX/bin/xtmoe"
rm -rf "$PREFIX/libexec/xtmoe"
```

也可以使用内置命令：

```sh
xtmoe uninstall-app
```

非交互卸载：

```sh
xtmoe uninstall-app --yes
```

它只删除 XTMOE 程序和模块，保留所有容器、配置、缓存及备份。

配置和容器数据不会自动删除。确认已经不再需要后，用户可单独处理 `~/.config/xtmoe`、`~/.local/share/xtmoe` 和 `~/.cache/xtmoe`。不要在仍有 Chroot 挂载时删除数据目录。

卸载某个 Linux 镜像应先使用受控命令，而不是手动删除数据目录：

```sh
xtmoe uninstall proot ubuntu
xtmoe chroot stop ubuntu
xtmoe uninstall chroot ubuntu
```
