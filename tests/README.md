# 开发与验证

```sh
bash tests/run.sh
bash -n src/bin/xtmoe
```

完整回归使用隔离临时目录与模拟依赖，验证命令、菜单、配置、能力组合、安装阶段、Root/网络归属和失败传播。CI 运行 Bash 语法、ShellCheck、回归及空白检查。

tests/internal.sh 仅供开发调用内部库操作，不安装到手机命令路径，也不作为公开 CLI。能力深度检查在临时 namespace 中进行，不修改 Android 现有接口或防火墙策略。

Android 端可运行 tests/android-smoke.sh，先看 help。临时容器名称由脚本生成；清理只处理自身已验证的容器，失败保存日志。禁止以清空 Termux 或现有用户容器替代测试隔离。

rootfs-lifecycle.sh 使用给定的真实 Ubuntu Base 验证解压、备份、恢复和删除边界。PRoot/Chroot 真机测试与模拟回归分别报告。
