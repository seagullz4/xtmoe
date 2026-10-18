# 安装、更新与卸载

要求 Android 7+、Termux 普通用户会话。先确认来源、架构、网络和可用空间，见 [兼容性](COMPATIBILITY.md)。容器放在 Termux 私有存储，不放在不能保留 Unix 权限的共享存储。

```sh
pkg update
pkg install -y git
git clone https://github.com/seagullz4/xtmoe.git xtmoe
cd xtmoe
sh termux.sh
xtmoe doctor
xtmoe on
```

安装器复制程序到 $PREFIX/bin 和 $PREFIX/libexec/xtmoe；不会删除已有容器。依赖按需要准备，不自动切换 Termux 软件源。网络异常可使用 Termux 自带 termux-change-repo。

PRoot 安装依赖当前 proot-distro。Chroot 安装前准备 Root/挂载工具，验证用户空间架构；数据与缓存所在文件系统各至少 2 GiB，使用 Docker 时预留更多。

## 程序维护

通过 `xtmoe on → 程序维护` 选择检查、更新、版本或卸载。更新使用源码目录的 git pull --ff-only；发现未提交修改就拒绝覆盖。更新结束退出向导，再重新运行 xtmoe on。尚未发布的新源码不会由远端更新得到。

重新运行安装器只替换程序。程序卸载保留容器、配置、缓存和备份；永久删除某个容器使用容器数据菜单或 `xtmoe uninstall`，需确认。

## 初始化与恢复

Chroot 显示能力及方案后安装基础 Ubuntu，按支持情况增强。网络/包/服务失败时保留 rootfs 和阶段记录，通过 `Chroot → 诊断与修复` 重试；不要先删除系统。

备份、恢复和重装通过各模式的数据管理菜单。重装会删除目标系统内的数据，必须先备份。程序更新不自动迁移运行中的容器方案。
