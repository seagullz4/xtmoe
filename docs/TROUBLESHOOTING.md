# 故障排查

## 先运行 doctor

```sh
tmoe doctor
termux-info
```

反馈问题时请附上这两条命令的输出、Android 版本、CPU 架构、Root 管理器和失败命令。不要发送访问令牌、私钥或完整的个人目录列表。

## 执行安装命令后没有输出

不要使用静默的远程管道命令。先确认网络：

```sh
curl -IL --connect-timeout 15 https://github.com/seagullz4/xtmoe
```

出现 `Could not resolve host` 是 DNS 问题；`SSL certificate problem` 通常需要更新 `ca-certificates`；HTTP 403/429 可能是网络限制或服务端限流。

## pkg 更新失败

确认不是旧 Play 商店版 Termux，然后运行：

```sh
termux-change-repo
pkg update
pkg upgrade
```

新版 TMOE 不会自动改写镜像源。

## PRoot 无法安装或登录

```sh
pkg reinstall proot proot-distro
tmoe proot raw --version
tmoe proot raw list
```

不要在另一个 PRoot 容器中嵌套运行，也不要从 Root shell 运行 `proot-distro`。

## Chroot 提示没有 Root

```sh
tmoe chroot prepare
tsu -c 'id -u'
```

正确输出应为 `0`。如果 Root 管理器没有弹出授权，请检查其授权记录、`su` 实现和 Termux 安装来源。

## Chroot mount 被拒绝

错误包含 `Permission denied` 或 `Operation not permitted` 时，通常由 SELinux、Root 方案或内核能力造成。检查：

```sh
tsu -c 'id; getenforce; mount --version'
```

不要为了绕过错误永久关闭 SELinux。无法满足挂载能力的设备应使用 PRoot。

## Chroot 无法卸载

先回到容器停止后台进程，然后：

```sh
tmoe chroot stop ubuntu
tmoe chroot status ubuntu
```

仍提示 busy 时不要删除 rootfs。关闭其他 Termux 会话和可能使用共享目录的程序后重试；最后手段是重启手机，再先执行 `status`/`stop`。

## apt 无法解析域名

```sh
cat /etc/resolv.conf
getent hosts archive.ubuntu.com
```

Chroot 初始化会写入公共 DNS。若当前网络阻止这些 DNS，可在容器内按网络环境更换 `/etc/resolv.conf`。

## Android 杀死后台任务

关闭 Termux 的电池优化，允许后台活动，并避免清理最近任务。部分 Android 12+ 设备还受 Phantom Process Killer 限制；具体设置随厂商和系统版本变化。

## 恢复旧版数据

旧版容器目录和新版不同。不要手动把旧 rootfs 直接移动进 `~/.local/share/tmoe-termux/chroot`。先用旧版工具生成备份，确认其中没有活动绑定挂载，再在隔离目录解包和迁移数据。

