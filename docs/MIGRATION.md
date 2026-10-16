# 从旧版 TMOE 迁移

旧版和 Termux v2 使用不同的数据结构，不要直接把旧容器目录移动到新版目录，也不要在仍有 Chroot 挂载时删除旧目录。

## 旧版常见路径

旧版代码可能使用：

```text
~/.local/share/tmoe-linux/containers/proot
~/.local/share/tmoe-linux/containers/chroot
~/.config/tmoe-linux
~/storage/downloads/backup/containers
/sdcard/Download/backup/containers
```

新版使用：

```text
~/.local/share/tmoe-termux
~/.config/tmoe-termux
~/.cache/tmoe-termux
```

两个版本的目录可以暂时共存。

可以先运行只读扫描：

```sh
tmoe migrate scan
```

扫描只列出旧 PRoot、旧 Chroot、配置和常见备份目录；如果 `/proc/mounts` 中仍存在旧 Chroot 路径，会显示“禁止移动或删除”。该命令不会修改、复制或删除任何文件。

## 迁移前检查

先退出所有旧版容器会话。对于旧 Chroot，在旧管理器仍可运行的情况下先使用旧管理器卸载 `/dev`、`/proc`、`/sys`、SD 卡和 Termux HOME 等绑定挂载。

检查残留挂载：

```sh
cat /proc/mounts | grep -E 'tmoe-linux|/containers/chroot' || true
```

只要还有输出，就不要移动或删除旧 Chroot 目录。停止相关服务和进程后再次用旧管理器卸载；必要时重启手机，再重新检查。

## PRoot 数据迁移

推荐把旧 PRoot 当作数据源，而不是把整个 rootfs 强行改造成新版容器：

1. 用旧版工具启动旧容器；
2. 把项目、数据库导出、SSH 公钥和用户配置复制到共享目录；
3. 用 `tmoe proot install` 创建新的干净容器；
4. 在新容器安装所需软件；
5. 导入项目和数据库；
6. 验证完成后再备份并移除旧容器。

不要复制 `/proc`、`/sys`、`/dev`、`/run`、`/tmp`，也不要直接覆盖新容器的 `/etc`。

## Chroot 数据迁移

Chroot 必须先确认没有任何残留挂载。推荐迁移应用数据而不是整个 rootfs：

- 网站和项目目录；
- 数据库的逻辑导出文件；
- `/etc` 中经过人工筛选的服务配置；
- 用户 HOME 中的代码、密钥公钥和 dotfiles；
- 软件包清单，例如 `dpkg-query -W` 输出。

旧 Chroot 的启动脚本、挂载配置和 systemd-nspawn 设置不要直接复制到 v2。

## 备份优先

在删除任何旧数据前，至少保留一份不包含活动挂载的归档，并记录 SHA-256：

```sh
sha256sum old-container-backup.tar.gz > old-container-backup.tar.gz.sha256
```

新版暂不提供自动导入旧 rootfs 的命令，因为旧版目录可能包含活动绑定挂载、不同的 PRoot 链接表示方式或设备相关配置。未经验证的自动迁移比重新安装后导入数据风险更高。
