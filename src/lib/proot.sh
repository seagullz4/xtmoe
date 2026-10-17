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
  xtmoe proot update-system [名称]    更新容器内软件包
  xtmoe proot reinstall [--yes] [名称] 按原镜像重装（删除容器数据）
  xtmoe proot status [名称]           查看安装和活动会话状态
  xtmoe proot remove [--yes] <名称>   永久删除
  xtmoe proot raw <参数...>           直接调用 proot-distro
EOF
}

require_proot() {
    require_termux
    require_command proot-distro '执行 pkg install proot-distro'
}

proot_container_dir() {
    local name=$1 directory
    for directory in \
        "${PREFIX:?PREFIX 未设置}/var/lib/proot-distro/containers/$name" \
        "$PREFIX/var/lib/proot-distro/installed-rootfs/$name"; do
        [[ -d $directory/rootfs ]] && { printf '%s' "$directory"; return 0; }
    done
    return 1
}

proot_exists() {
    proot_container_dir "$1" >/dev/null 2>&1
}

proot_session_count() {
    local name=$1
    proot-distro ps 2>/dev/null | awk -v expected="$name" '
        NR == 1 && $1 == "PID" { next }
        $1 ~ /^[0-9]+$/ && $2 == expected { count++ }
        END { print count + 0 }
    '
}

proot_install() {
    require_arg_range 0 2 "$#" 'xtmoe proot install [镜像] [名称]'
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
    require_arg_range 1 2 "$#" 'xtmoe proot backup <名称> [文件]'
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

proot_update_system() {
    require_arg_range 0 1 "$#" 'xtmoe proot update-system [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    proot_exists "$name" || die "PRoot 容器不存在：$name"
    proot-distro login "$name" -- /bin/sh -lc '
set -eu
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
elif command -v dnf >/dev/null 2>&1; then
    dnf -y upgrade
elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm
elif command -v apk >/dev/null 2>&1; then
    apk update
    apk upgrade
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive update
else
    printf "XTMOE: 无法识别容器包管理器。\n" >&2
    exit 1
fi'
}

proot_reinstall() {
    local yes=0 name=ubuntu name_set=0
    while (($#)); do
        case "$1" in
            --yes|-y) yes=1 ;;
            -*) die "未知 reinstall 参数：$1" ;;
            *) ((name_set == 0)) || die 'reinstall 只接受一个容器名称'; name=$1; name_set=1 ;;
        esac
        shift
    done
    require_name "$name"
    proot_exists "$name" || die "PRoot 容器不存在：$name"
    ((yes)) && export XTMOE_YES=1
    confirm "重装 PRoot 容器 '$name'？容器内全部数据都会永久删除且不会自动备份" || { info '已取消'; return 0; }
    if ! proot-distro help 2>&1 | grep -Eq '(^|[[:space:]])reset([[:space:]]|$)'; then
        die '当前 proot-distro 不支持安全 reset；请先在 Termux 中更新 proot-distro。'
    fi
    proot-distro reset "$name"
    ok "PRoot 容器已按原镜像重装：$name"
}

proot_status() {
    require_arg_range 0 1 "$#" 'xtmoe proot status [名称]'
    local name=${1:-ubuntu} count
    require_name "$name"
    if ! proot_exists "$name"; then
        printf 'not-installed\n'
        return 1
    fi
    count=$(proot_session_count "$name")
    if ((count > 0)); then
        printf 'running sessions=%s\n' "$count"
    else
        printf 'stopped\n'
    fi
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
        stop|kill)
            require_arg_range 1 1 "$#" 'xtmoe proot stop <名称>'
            proot-distro kill "$1"
            ;;
        backup) proot_backup "$@" ;;
        restore) proot_restore "$@" ;;
        update-system) proot_update_system "$@" ;;
        reinstall) proot_reinstall "$@" ;;
        status) proot_status "$@" ;;
        remove|rm) proot_remove "$@" ;;
        raw) proot-distro "$@" ;;
        *) die "未知 PRoot 操作：$action" ;;
    esac
}
