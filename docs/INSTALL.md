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

安装完成后必须运行：

```sh
xtmoe doctor
```

## 更新

在原源码目录更新后重新安装：

```sh
cd "$HOME/xtmoe"
git pull --ff-only
sh termux.sh
xtmoe doctor
```

重新执行安装器只更新程序文件，不删除容器、配置或备份。

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

配置和容器数据不会自动删除。确认已经不再需要后，用户可单独处理 `~/.config/xtmoe`、`~/.local/share/xtmoe` 和 `~/.cache/xtmoe`。不要在仍有 Chroot 挂载时删除数据目录。

