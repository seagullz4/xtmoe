#!/data/data/com.termux/files/usr/bin/bash

proot_help() {
    cat <<'EOF'
PRoot 模式（无需 Root）

  xtmoe proot install [镜像] [名称]   默认：ubuntu:24.04 / ubuntu
  xtmoe proot login [名称]            进入交互式 shell
  xtmoe proot exec <名称> -- <命令>   执行单条命令
  xtmoe proot list                    列出容器
  xtmoe proot ps                      列出活动会话
  xtmoe proot stop <名称>             停止容器会话
  xtmoe proot backup <名称> [文件]    备份
  xtmoe proot restore <文件>          恢复（名称保存在备份中）
  xtmoe proot remove [--yes] <名称>   永久删除
  xtmoe proot raw <参数...>           直接调用 proot-distro
EOF
}

require_proot() {
    require_termux
    require_command proot-distro '执行 pkg install proot-distro'
}

proot_install() {
    local image=${1:-ubuntu:24.04} name=${2:-ubuntu}
    require_name "$name"
    info "安装 PRoot 容器：$name（$image）"
    if proot-distro install --help 2>&1 | grep -q -- '--name'; then
        proot-distro install --name "$name" "$image"
    else
        proot-distro install --override-alias "$name" "$image"
    fi
}

proot_backup() {
    local name=${1:?缺少容器名称} output=${2:-"$PWD/${1}-$(date +%Y%m%d-%H%M%S).tar.gz"}
    require_name "$name"
    proot-distro backup "$name" --output "$output"
    ok "备份已写入：$output"
}

proot_restore() {
    local archive=${1:?缺少备份文件}
    [[ -f $archive ]] || die "备份文件不存在：$archive"
    (($# == 1)) || die 'PRoot 备份内已经包含容器名称；restore 不接受新名称。恢复后可用 raw rename 改名。'
    proot-distro restore "$archive"
}

proot_remove() {
    local yes=0 name=''
    while (($#)); do
        case "$1" in
            --yes|-y) yes=1 ;;
            *) [[ -z $name ]] || die 'remove 只接受一个容器名称'; name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || die '缺少容器名称'
    require_name "$name"
    if ((yes)); then export XTMOE_YES=1; fi
    confirm "永久删除 PRoot 容器 '$name' 及其全部数据？" || { info '已取消'; return 0; }
    proot-distro remove "$name"
}

proot_main() {
    local action=${1:-help}
    shift || true
    [[ $action == help || $action == -h || $action == --help ]] && { proot_help; return; }
    require_proot
    case "$action" in
        install|add) proot_install "$@" ;;
        login|shell)
            local name=${1:-ubuntu}
            (($# == 0)) || shift
            proot-distro login "$name" "$@"
            ;;
        exec)
            local name=${1:?缺少容器名称}; shift
            [[ ${1:-} == -- ]] && shift
            (($#)) || die '缺少要执行的命令'
            proot-distro login "$name" -- "$@"
            ;;
        list|ls) proot-distro list "$@" ;;
        ps) proot-distro ps "$@" ;;
        stop|kill) proot-distro kill "${1:?缺少容器名称}" ;;
        backup) proot_backup "$@" ;;
        restore) proot_restore "$@" ;;
        remove|rm) proot_remove "$@" ;;
        raw) proot-distro "$@" ;;
        *) die "未知 PRoot 操作：$action" ;;
    esac
}
