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

程序完整版本位于 `$PREFIX/libexec/xtmoe/releases/`，`current` 指向当前版本。安装器使用互斥锁、暂存校验和原子指针切换；中途失败不会逐个覆盖当前模块。已运行命令及 Root/网络助手保留原版本路径。旧版本（包括首次迁移前的旧布局）暂不自动清理，因此更新会增加少量程序文件占用；不要手动删除仍可能被助手使用的目录。SIGKILL/断电可能留下未发布暂存目录，但不会把它作为当前版本。

PRoot 安装依赖当前 proot-distro。Chroot 安装前准备 Root/挂载工具，验证用户空间架构；数据与缓存所在文件系统各至少 2 GiB，使用 Docker 时预留更多。

## 程序维护

通过 `xtmoe on → 程序维护` 选择检查、更新、版本、卸载或强制更新，也可使用：

```sh
xtmoe update
xtmoe update --force
```

普通更新使用源码目录的 `git pull --ff-only`，发现已跟踪修改或未跟踪文件时拒绝覆盖。`--force` 以当前源码分支所配置的远端跟踪分支为准，先成功 fetch 并检查远端 XTMOE 必要文件，再执行 `reset --hard` 和 `clean -fd`，丢弃源码目录中的本地提交、已跟踪修改与未跟踪文件/目录；Git 忽略文件保留，不使用 `-x`。请先另行保存需要保留的源码改动和未跟踪文件。没有远端跟踪分支或处于 detached HEAD 时拒绝强制更新，不猜测分支。

菜单中的“强制更新（丢弃源码本地修改）”执行相同行为并要求确认；命令行 `--force` 本身就是覆盖确认。远端下载/必要文件检查失败时不执行 reset/clean；安装仍使用完整版本暂存和原子切换，失败不会热覆盖正在运行的版本。容器、配置和备份保留在各自数据路径，程序源码必须放在独立仓库目录，不能把 Termux 主目录或安装目录当作源码目录。

更新结束后退出并重新运行 `xtmoe on`。运行中的容器和网络助手仍使用旧版本；要启用新的自动重绑定逻辑，需按原方式停止并重新启动对应容器，不会在更新时强行重启服务。尚未发布的新源码不会由远端更新得到。

重新运行安装器只替换程序。程序卸载保留容器、配置、缓存和备份；永久删除某个容器使用容器数据菜单或 `xtmoe uninstall`，需确认。

## 初始化与恢复

Chroot 显示能力及方案后安装基础 Ubuntu，按支持情况增强。网络/包/服务失败时保留 rootfs 和阶段记录，通过 `Chroot → 诊断与修复` 重试；不要先删除系统。

备份、恢复和重装通过各模式的数据管理菜单。重装会删除目标系统内的数据，必须先备份。程序更新不自动迁移运行中的容器方案。
