#!/data/data/com.termux/files/usr/bin/bash

chroot_help() {
    cat <<'EOF'
Chroot 模式（需要设备 Root；当前支持原生架构 Ubuntu Base 24.04）

  xtmoe chroot install [ubuntu] [24.04] [名称]
  xtmoe chroot prepare                    安装 tsu、mount-utils 等依赖
  xtmoe chroot login [名称]
  xtmoe chroot exec <名称> -- <命令>
  xtmoe chroot setup [名称]             更新 apt 并安装常用基础包
  xtmoe chroot status [名称]
  xtmoe chroot list
  xtmoe chroot stop [名称]              卸载全部绑定挂载
  xtmoe chroot bind <名称> <宿主目录> <容器目录> [ro|rw]
  xtmoe chroot unbind <名称> <容器目录>
  xtmoe chroot backup <名称> [文件]
  xtmoe chroot restore <文件> [名称]
  xtmoe chroot remove [--yes] <名称>

Chroot 与 Android 共用内核，不是安全沙箱。删除前必须先 stop。
EOF
}

chroot_base() { printf '%s/chroot' "$XTMOE_DATA_DIR"; }
chroot_config_base() { printf '%s/chroot' "$XTMOE_CONFIG_DIR"; }

chroot_helper() {
    local candidate="$XTMOE_LIB_DIR/../xtmoe-root"
    [[ -r $candidate ]] || candidate="${PREFIX:?PREFIX 未设置}/libexec/xtmoe/xtmoe-root"
    [[ -r $candidate ]] || die "缺少 Chroot 助手：$candidate"
    printf '%s' "$candidate"
}

chroot_root() {
    local helper
    helper=$(chroot_helper)
    run_root "${PREFIX:?PREFIX 未设置}/bin/bash" "$helper" "$PREFIX" "$@"
}

require_chroot() {
    require_termux
    root_available || die '设备未授予 Root，或 tsu/su 不可用；请改用 PRoot 模式。'
}

chroot_prepare() {
    require_termux
    require_command pkg '请使用官方 Termux 客户端'
    info '安装 Chroot 所需的 Termux 软件包……'
    pkg install -y tsu mount-utils coreutils curl tar
    if root_available; then
        ok 'Chroot 依赖与 Root 授权可用'
    else
        warn '依赖已安装，但未取得 Root；请检查 Magisk/KernelSU/APatch 授权。'
        return 1
    fi
}

ubuntu_arch() {
    case "$(uname -m)" in
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv8l|arm) printf 'armhf' ;;
        x86_64|amd64) printf 'amd64' ;;
        *) die "Ubuntu Base 不支持当前架构：$(uname -m)" ;;
    esac
}

android_dns_servers() {
    local property value found=0
    if command_exists getprop; then
        for property in net.dns1 net.dns2 net.dns3 net.dns4; do
            value=$(getprop "$property" 2>/dev/null || true)
            if [[ $value =~ ^[0-9A-Fa-f:.]+$ ]]; then
                printf '%s\n' "$value"
                found=1
            fi
        done
    fi
    if ((found == 0)); then
        printf '%s\n' '1.1.1.1' '8.8.8.8'
    fi
}

download_ubuntu_base() {
    local version=$1 arch index filename base_url sums archive line version_regex
    arch=$(ubuntu_arch)
    base_url="https://cdimage.ubuntu.com/ubuntu-base/releases/$version/release"
    mkdir -p "$XTMOE_CACHE_DIR/ubuntu-base/$version"
    index="$XTMOE_CACHE_DIR/ubuntu-base/$version/index.html"
    sums="$XTMOE_CACHE_DIR/ubuntu-base/$version/SHA256SUMS"

    info "读取 Ubuntu Base $version 官方发布列表……" >&2
    curl -fL --retry 3 --connect-timeout 20 -o "$index" "$base_url/"
    version_regex=${version//./[.]}
    filename=$(grep -oE "ubuntu-base-${version_regex}[.][0-9]+-base-${arch}[.]tar[.]gz" "$index" | sort -Vu | tail -n 1)
    [[ -n $filename ]] || die "没有找到 Ubuntu Base $version/$arch 镜像"
    archive="$XTMOE_CACHE_DIR/ubuntu-base/$version/$filename"

    curl -fL --retry 3 --connect-timeout 20 -o "$sums" "$base_url/SHA256SUMS"
    line=$(grep -E "[[:space:]]+[*]?$filename$" "$sums" | head -n 1 || true)
    [[ -n $line ]] || die "SHA256SUMS 中没有 $filename"

    if [[ -s $archive ]]; then
        if (cd -- "$(dirname -- "$archive")" && printf '%s\n' "$line" | sha256sum -c -) >&2; then
            printf '%s' "$archive"
            return 0
        fi
        warn "缓存镜像校验失败，将重新下载：$archive"
        rm -f -- "$archive"
    fi

    info "下载 $filename……" >&2
    curl -fL --retry 3 --connect-timeout 20 --continue-at - -o "$archive" "$base_url/$filename"
    (cd -- "$(dirname -- "$archive")" && printf '%s\n' "$line" | sha256sum -c -) >&2
    printf '%s' "$archive"
}

chroot_install() {
    local distro=${1:-ubuntu} version=${2:-24.04} name=${3:-ubuntu} archive base config_base
    local -a dns_servers=()
    [[ $distro == ubuntu ]] || die 'Chroot 当前只支持 Ubuntu Base；其他发行版请使用 PRoot。'
    [[ $version == 24.04 ]] || die '当前经过配置的是 Ubuntu 24.04 LTS。'
    require_name "$name"
    ensure_dirs
    base=$(chroot_base); config_base=$(chroot_config_base)
    mkdir -p "$base" "$config_base"
    [[ ! -e $base/$name ]] || die "Chroot 容器已存在：$name"
    archive=$(download_ubuntu_base "$version")
    mapfile -t dns_servers < <(android_dns_servers)
    info "以 Root 身份解压并初始化 Chroot：$name"
    chroot_root install "$base" "$name" "$archive" "${dns_servers[@]}"
    printf 'distro=ubuntu\nversion=%s\narch=%s\n' "$version" "$(ubuntu_arch)" >"$config_base/$name.meta"
    : >"$config_base/$name.binds"
    ok "Chroot '$name' 安装完成；执行：xtmoe chroot login $name"
}

chroot_login() {
    local name=${1:-ubuntu} base config
    require_name "$name"; base=$(chroot_base); config="$(chroot_config_base)/$name.binds"
    chroot_root login "$base" "$name" "$config"
}

chroot_exec() {
    local name=${1:?缺少容器名称} base config
    shift
    [[ ${1:-} == -- ]] && shift
    (($#)) || die '缺少要执行的命令'
    require_name "$name"; base=$(chroot_base); config="$(chroot_config_base)/$name.binds"
    chroot_root exec "$base" "$name" "$config" "$@"
}

chroot_bind() {
    local name=${1:?缺少容器名称} source_path=${2:?缺少宿主目录} target=${3:?缺少容器目录} mode=${4:-rw}
    local config
    require_name "$name"
    [[ $source_path == /* && -d $source_path ]] || die '宿主路径必须是已存在的绝对目录。'
    [[ $source_path != / && $source_path != /data ]] || die '拒绝挂载整个宿主根目录或 /data；请选择更小的明确目录。'
    [[ $target == /* && $target != / ]] || die '容器路径必须是非根目录的绝对路径。'
    [[ $source_path != *'|'* && $target != *'|'* && $source_path != *$'\n'* && $target != *$'\n'* ]] || die '路径不能包含竖线或换行。'
    [[ $mode == ro || $mode == rw ]] || die '挂载模式只能是 ro 或 rw。'
    config="$(chroot_config_base)/$name.binds"
    [[ -d $(chroot_base)/$name ]] || die "容器不存在：$name"
    mkdir -p "$(dirname -- "$config")"
    if [[ -f $config ]] && awk -F '|' -v dst="$target" '$3 == dst { found=1 } END { exit !found }' "$config"; then
        die "容器挂载点已配置：$target"
    fi
    printf '%s|%s|%s\n' "$mode" "$source_path" "$target" >>"$config"
    ok "已添加：$source_path -> $target ($mode)；下次 login 生效"
}

chroot_unbind() {
    local name=${1:?缺少容器名称} target=${2:?缺少容器目录} config tmp
    require_name "$name"; config="$(chroot_config_base)/$name.binds"
    [[ -f $config ]] || die "没有挂载配置：$name"
    tmp="$config.tmp.$$"
    awk -F '|' -v dst="$target" '$3 != dst' "$config" >"$tmp"
    mv -f -- "$tmp" "$config"
    ok "已移除配置：$target；若当前已挂载，请先执行 chroot stop"
}

chroot_backup() {
    local name=${1:?缺少容器名称} output=${2:-"$PWD/${1}-$(date +%Y%m%d-%H%M%S)-chroot.tar.gz"}
    local base
    require_name "$name"; base=$(chroot_base)
    chroot_root backup "$base" "$name" "$output" "$(id -u)" "$(id -g)"
    ok "备份已写入：$output"
}

chroot_restore() {
    local archive=${1:?缺少备份文件} name=${2:-ubuntu-restored} base config_base
    [[ -f $archive ]] || die "备份文件不存在：$archive"
    require_name "$name"; base=$(chroot_base); config_base=$(chroot_config_base)
    mkdir -p "$base" "$config_base"
    [[ ! -e $base/$name ]] || die "容器已存在：$name"
    chroot_root restore "$base" "$name" "$archive"
    : >"$config_base/$name.binds"
    printf 'restored_from=%s\n' "$archive" >"$config_base/$name.meta"
    ok "已恢复为：$name"
}

chroot_remove() {
    local yes=0 name='' base config_base
    while (($#)); do
        case "$1" in
            --yes|-y) yes=1 ;;
            *) [[ -z $name ]] || die 'remove 只接受一个容器名称'; name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || die '缺少容器名称'; require_name "$name"
    ((yes)) && export XTMOE_YES=1
    confirm "永久删除 Chroot 容器 '$name' 及其全部数据？" || { info '已取消'; return; }
    base=$(chroot_base); config_base=$(chroot_config_base)
    chroot_root remove "$base" "$name"
    rm -f -- "$config_base/$name.binds" "$config_base/$name.meta"
    ok "已删除：$name"
}

chroot_list() {
    local base name found=0
    base=$(chroot_base)
    [[ -d $base ]] || { info '没有 Chroot 容器'; return; }
    for name in "$base"/*; do
        [[ -d $name ]] || continue
        found=1
        printf '%-24s ' "$(basename -- "$name")"
        chroot_root status "$base" "$(basename -- "$name")"
    done
    ((found)) || info '没有 Chroot 容器'
}

chroot_main() {
    local action=${1:-help} name
    shift || true
    [[ $action == help || $action == -h || $action == --help ]] && { chroot_help; return; }
    [[ $action == prepare ]] && { chroot_prepare; return; }
    require_chroot
    ensure_dirs
    case "$action" in
        install|add) chroot_install "$@" ;;
        login|shell) chroot_login "$@" ;;
        exec) chroot_exec "$@" ;;
        setup)
            name=${1:-ubuntu}
            chroot_exec "$name" -- /bin/bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl locales openssh-server sudo'
            ;;
        list|ls) chroot_list ;;
        status) chroot_root status "$(chroot_base)" "${1:-ubuntu}" ;;
        stop|umount) chroot_root stop "$(chroot_base)" "${1:-ubuntu}" ;;
        bind) chroot_bind "$@" ;;
        unbind) chroot_unbind "$@" ;;
        backup) chroot_backup "$@" ;;
        restore) chroot_restore "$@" ;;
        remove|rm) chroot_remove "$@" ;;
        *) die "未知 Chroot 操作：$action" ;;
    esac
}

