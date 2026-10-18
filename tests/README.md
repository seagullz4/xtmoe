# 开发与验证

```sh
bash tests/run.sh
bash -n src/bin/xtmoe
```

完整回归使用隔离临时目录与模拟依赖，验证命令、菜单、配置、能力组合、安装阶段、Root/网络归属和失败传播。CI 运行 Bash 语法、ShellCheck、回归及空白检查。

自动端口映射用模拟地址、监听器和规则下发覆盖 Wi-Fi A/B 切换、离线恢复、多 LAN、UDP、端口冲突重试及旧网络助手升级边界。程序更新使用隔离的真实本地 Git bare/clone 仓库，验证正常更新、脏工作区拒绝、强制同步本地分叉和删除、保留忽略文件与外部数据，以及下载失败/错误远端/缺少跟踪分支时不覆盖。本地 Git 测试不连接手机或远端 GitHub，不在项目工作区执行 reset/clean。

tests/internal.sh 仅供开发调用内部库操作，不安装到手机命令路径，也不作为公开 CLI。能力深度检查在临时 namespace 中进行，不修改 Android 现有接口或防火墙策略。

Android 端可运行 tests/android-smoke.sh，先看 help。临时容器名称由脚本生成；清理只处理自身已验证的容器，失败保存日志。禁止以清空 Termux 或现有用户容器替代测试隔离。

rootfs-lifecycle.sh 使用给定的真实 Ubuntu Base 验证解压、备份、恢复和删除边界。PRoot/Chroot 真机测试与模拟回归分别报告。
