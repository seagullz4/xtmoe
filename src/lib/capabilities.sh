#!/data/data/com.termux/files/usr/bin/bash
# Shared product policy. Hardware/Root features are verified by the Root helper.

android_supported() {
    local sdk
    command_exists getprop || { warn '无法读取 Android API；仅主机测试可跳过平台检查'; return 1; }
    sdk=$(getprop ro.build.version.sdk 2>/dev/null) || return 1
    [[ $sdk =~ ^[0-9]+$ ]] || { warn 'Android API 无效'; return 1; }
    ((10#$sdk >= 24)) || { warn 'XTMOE v1.0.0 要求 Android 7.0 / API 24 或更新系统'; return 1; }
}

native_arch() {
    local architecture
    architecture=$(dpkg --print-architecture 2>/dev/null) || return 1
    case "$architecture" in
        aarch64|arm64) printf arm64 ;;
        arm|armhf) printf armhf ;;
        x86_64|amd64) printf amd64 ;;
        i686|i386) printf i386 ;;
        *) warn "不支持的 Termux 用户空间架构：$architecture"; return 1 ;;
    esac
}

native_proot_arch() {
    case "$(native_arch)" in
        arm64) printf aarch64 ;; armhf) printf arm ;; amd64) printf x86_64 ;; i386) printf i686 ;; *) return 1 ;;
    esac
}

capability_report() {
    local architecture release sdk source root_report=''
    require_arg_range 0 0 "$#" 'xtmoe doctor'
    require_termux
    android_supported || return 1
    architecture=$(native_arch) || return 1
    release=$(getprop ro.build.version.release 2>/dev/null || true)
    sdk=$(getprop ro.build.version.sdk)
    printf 'XTMOE %s\nAndroid=%s API=%s\n用户空间=%s 内核=%s\n' "${XTMOE_VERSION:-v1.0.0}" "$release" "$sdk" "$architecture" "$(uname -r)"
    source=${TERMUX_APK_RELEASE:-${TERMUX_APP__APK_RELEASE:-unknown}}
    printf 'Termux 来源=%s\n' "$source"
    case "${source^^}" in *GOOGLE*|*PLAY*) warn 'Google Play 分支为单独维护的实验性版本；优先使用 F-Droid/官方 GitHub，仍按实际能力检测' ;; esac
    local command failures=0
    for command in bash curl tar sha256sum flock; do
        if ! command_exists "$command"; then warn "缺少基础依赖：$command"; failures=1; fi
    done
    if command_exists proot-distro; then
        printf 'PRoot=依赖已安装，原生镜像与实际启动仍需验证\n'
    else warn 'PRoot=缺少 proot-distro，请重新运行安装器'; fi
    if [[ $architecture == i386 ]]; then printf 'Chroot 镜像=Ubuntu 24.04 未提供 i386 Base\n'; fi
    if root_available; then
        printf 'Root=available\n'
        root_report=$(chroot_root capabilities-readonly) || return 1
        printf '%s\n' "$root_report"
    else
        printf 'Root=unavailable\nChroot=unsupported（不影响 PRoot）\n'
    fi
    printf '深度验证：xtmoe on → Chroot → 诊断与修复；未检测不等于已支持。\n'
    ((failures == 0))
}

public_proot() {
    local action=${1:-help}
    case "$action" in
        list|ps) require_arg_range 1 1 "$#" "xtmoe proot $action" ;;
        login|status|update-system) require_arg_range 1 2 "$#" "xtmoe proot $action [名称]" ;;
        stop) require_arg_range 2 2 "$#" 'xtmoe proot stop <名称>' ;;
        backup) require_arg_range 2 3 "$#" 'xtmoe proot backup <名称> [文件]' ;;
    esac
    case "${1:-help}" in
        help|-h|--help|install|login|exec|list|ps|stop|backup|update-system|status) proot_main "$@" ;;
        *) die '此操作请使用 xtmoe on → PRoot 管理' ;;
    esac
}

public_chroot() {
    local argument
    if [[ ${1:-} == install ]]; then
        require_arg_range 1 4 "$#" 'xtmoe chroot install [ubuntu] [24.04] [名称]'
        for argument in "${@:2}"; do [[ $argument != -* ]] || die '安装选项请通过 xtmoe on 配置'; done
    fi
    case "${1:-help}" in
        help|-h|--help|prepare|install|stop|status) chroot_main "$@" ;;
        systemd-login) shift; chroot_main login "$@" ;;
        *) die '此操作请使用 xtmoe on → Chroot 管理' ;;
    esac
}
