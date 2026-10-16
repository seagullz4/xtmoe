#!/data/data/com.termux/files/usr/bin/bash

chroot_help() {
    cat <<'EOF'
Chroot 模式（需要设备 Root；当前支持原生架构 Ubuntu Base 24.04）

  xtmoe chroot install [--yes] [--skip-systemd] [--skip-bash-sh] [ubuntu] [24.04] [名称]
  xtmoe chroot prepare                    安装 tsu、mount-utils 等依赖
  xtmoe chroot login [名称]
  xtmoe chroot exec <名称> -- <命令>
  xtmoe chroot setup [名称]             更新 apt 并安装常用基础包
  xtmoe chroot docker-check [名称]      只读检查 Docker/1Panel 内核条件
  xtmoe chroot systemd-check [名称]     检查嵌套 systemd 启动条件
  xtmoe chroot systemd-start [名称]     在 PID namespace 中启动 systemd
  xtmoe chroot systemd-login [名称]     进入 systemd 会话 Shell
  xtmoe chroot systemd-exec <名称> -- <命令>
  xtmoe chroot systemd-status [名称]
  xtmoe chroot systemd-stop [名称]      停止嵌套 systemd 并卸载
  xtmoe chroot use-bash-sh [名称]       将 /bin/sh 切换为 Bash
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
    local candidate="$XTMOE_LIB_DIR/xtmoe-root"
    [[ -r $candidate ]] || candidate="$XTMOE_LIB_DIR/../xtmoe-root"
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
    pkg install -y tsu mount-utils util-linux coreutils curl tar
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
    line=$(awk -v expected="$filename" '$2 == expected || $2 == "*" expected { print; exit }' "$sums")
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
    local yes=0 skip_systemd=0 skip_bash_sh=0 distro version name archive base config_base
    local bootstrap_systemd=0
    local -a positional=() dns_servers=()
    while (($#)); do
        case $1 in
            --yes|-y) yes=1 ;;
            --skip-systemd) skip_systemd=1 ;;
            --skip-bash-sh) skip_bash_sh=1 ;;
            --) shift; positional+=("$@"); break ;;
            -*) die "未知安装选项：$1" ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    ((${#positional[@]} <= 3)) || die 'xtmoe chroot install [--yes] [--skip-systemd] [--skip-bash-sh] [ubuntu] [24.04] [名称]'
    distro=${positional[0]:-ubuntu}
    version=${positional[1]:-24.04}
    name=${positional[2]:-ubuntu}
    [[ $distro == ubuntu ]] || die 'Chroot 当前只支持 Ubuntu Base；其他发行版请使用 PRoot。'
    [[ $version == 24.04 ]] || die '当前经过配置的是 Ubuntu 24.04 LTS。'
    require_name "$name"
    ((yes)) && export XTMOE_YES=1
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

    if ((skip_systemd)); then
        info '已按要求跳过 systemd/Ubuntu 标准组件初始化'
    elif confirm_default_yes "默认安装完整 Ubuntu 标准组件和 systemd，并启动嵌套 systemd？"; then
        bootstrap_systemd=1
        chroot_setup "$name"
    else
        info '已跳过 systemd 初始化'
    fi

    if ((skip_bash_sh)); then
        info '已按要求保留 /bin/sh'
    elif confirm_default_yes "将容器内 /bin/sh 切换为 Bash？"; then
        chroot_use_bash_sh "$name"
    else
        info '已保留默认 Shell'
    fi

    if ((bootstrap_systemd)); then
        chroot_systemd_start "$name"
        ok "Chroot '$name' 已完成 systemd/Bash 初始化；执行：xtmoe chroot systemd-login $name"
    else
        ok "Chroot '$name' 安装完成；执行：xtmoe chroot login $name"
    fi
}
chroot_login() {
    require_arg_range 0 1 "$#" 'xtmoe chroot login [名称]'
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

chroot_systemd_check() {
    require_arg_range 0 1 "$#" 'xtmoe chroot systemd-check [名称]'
    chroot_root systemd-check "$(chroot_base)" "${1:-ubuntu}"
}

chroot_systemd_start() {
    require_arg_range 0 1 "$#" 'xtmoe chroot systemd-start [名称]'
    local name=${1:-ubuntu} config
    config="$(chroot_config_base)/$name.binds"
    chroot_root systemd-start "$(chroot_base)" "$name" "$config"
}

chroot_systemd_login() {
    require_arg_range 0 1 "$#" 'xtmoe chroot systemd-login [名称]'
    chroot_root systemd-login "$(chroot_base)" "${1:-ubuntu}"
}

chroot_systemd_exec() {
    local name=${1:?缺少容器名称}
    shift
    [[ ${1:-} == -- ]] && shift
    (($#)) || die '缺少命令'
    chroot_root systemd-exec "$(chroot_base)" "$name" "$@"
}

chroot_systemd_status() {
    require_arg_range 0 1 "$#" 'xtmoe chroot systemd-status [名称]'
    chroot_root systemd-status "$(chroot_base)" "${1:-ubuntu}"
}

chroot_systemd_stop() {
    require_arg_range 0 1 "$#" 'xtmoe chroot systemd-stop [名称]'
    chroot_root systemd-stop "$(chroot_base)" "${1:-ubuntu}"
}

chroot_use_bash_sh() {
    require_arg_range 0 1 "$#" 'xtmoe chroot use-bash-sh [名称]'
    local name=${1:-ubuntu}
    chroot_exec "$name" -- /bin/bash -lc 'set -e; [[ -x /usr/bin/bash ]] || { echo "缺少 /usr/bin/bash" >&2; exit 1; }; if command -v debconf-set-selections >/dev/null 2>&1 && command -v dpkg-reconfigure >/dev/null 2>&1; then printf "dash dash/sh boolean false\\n" | debconf-set-selections; DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive dash; fi; ln -sfn bash /bin/sh; readlink -f /bin/sh'
}

chroot_bind() {
    require_arg_range 3 4 "$#" 'xtmoe chroot bind <名称> <宿主目录> <容器目录> [ro|rw]'
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
    ok "已添加：$source_path -> $target ($mode)；下次 login 或 systemd-start 生效"
}

chroot_unbind() {
    require_arg_range 2 2 "$#" 'xtmoe chroot unbind <名称> <容器目录>'
    local name=${1:?缺少容器名称} target=${2:?缺少容器目录} config tmp
    require_name "$name"
    [[ $target == /* && $target != / && $target != *'|'* && $target != *$'\n'* ]] || die '容器路径必须是有效的非根绝对路径。'
    config="$(chroot_config_base)/$name.binds"
    [[ -f $config ]] || die "没有挂载配置：$name"
    tmp="$config.tmp.$$"
    awk -F '|' -v dst="$target" '$3 != dst' "$config" >"$tmp"
    mv -f -- "$tmp" "$config"
    ok "已移除配置：$target；若当前已挂载，请先执行 chroot stop"
}

chroot_backup() {
    require_arg_range 1 2 "$#" 'xtmoe chroot backup <名称> [文件]'
    local name=${1:?缺少容器名称} output=${2:-"$PWD/${1}-$(date +%Y%m%d-%H%M%S)-chroot.tar.gz"}
    local base
    require_name "$name"; base=$(chroot_base)
    chroot_root backup "$base" "$name" "$output" "$(id -u)" "$(id -g)"
    ok "备份已写入：$output"
}

chroot_restore() {
    require_arg_range 1 2 "$#" 'xtmoe chroot restore <文件> [名称]'
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

chroot_docker_check() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-check [名称]'
    local name=${1:-ubuntu} check_script
    require_name "$name"
    check_script=$(cat <<'DOCKER_CHECK'
failures=0
warnings=0
good() { printf '[OK] %s\n' "$*"; }
bad() { printf '[缺失] %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '[警告] %s\n' "$*"; warnings=$((warnings + 1)); }

printf 'Kernel: %s\n' "$(uname -r)"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'PID 1: %s\n' "$(cat /proc/1/comm 2>/dev/null || printf unknown)"

for ns in mnt pid net uts ipc; do
    if [ -e "/proc/self/ns/$ns" ]; then good "namespace: $ns"; else bad "namespace: $ns"; fi
done
[ -e /proc/self/ns/user ] && good 'namespace: user（可选）' || note 'namespace: user 不存在（rootful Docker 可选）'

if grep -Eq ' cgroup2? ' /proc/mounts; then
    good 'cgroup 文件系统已挂载'
else
    bad '没有 cgroup/cgroup2 挂载'
fi

controllers="$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || true)"
if grep -qw pids /proc/cgroups 2>/dev/null || printf '%s\n' "$controllers" | grep -qw pids; then
    good 'pids cgroup controller'
else
    bad 'pids cgroup controller'
fi
if grep -qw devices /proc/cgroups 2>/dev/null; then
    good 'devices cgroup v1 controller'
elif [ -n "$controllers" ]; then
    note 'cgroup v2 不列出 devices；仍需 dockerd/runc 实际验证 BPF devices 支持'
else
    bad 'devices cgroup controller'
fi

grep -qw overlay /proc/filesystems && good 'OverlayFS' || note 'OverlayFS 缺失，只能尝试低性能 vfs 存储驱动'
[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 0)" = 1 ] && good 'IPv4 forwarding' || note 'IPv4 forwarding 当前未启用'
command -v iptables >/dev/null 2>&1 && good "iptables: $(iptables --version 2>/dev/null | head -n 1)" || note 'iptables 命令未安装'
command -v dockerd >/dev/null 2>&1 && good "dockerd: $(dockerd --version 2>/dev/null)" || note 'dockerd 未安装'

if [ -S /var/run/docker.sock ]; then
    good 'Docker socket 存在'
    docker info >/dev/null 2>&1 && good 'Docker daemon 可响应' || bad 'Docker socket 存在但 daemon 不可响应'
else
    note 'Docker socket 不存在，daemon 未运行'
fi

if [ "$(cat /proc/1/comm 2>/dev/null)" = systemd ]; then
    good 'systemd 是 PID 1'
else
    note 'systemd 不是 PID 1；1Panel 的 systemctl 服务路径不可用'
fi

printf 'Summary: failures=%s warnings=%s\n' "$failures" "$warnings"
[ "$failures" -eq 0 ]
DOCKER_CHECK
)
    chroot_exec "$name" -- /bin/bash -lc "$check_script"
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
            require_arg_range 0 1 "$#" 'xtmoe chroot setup [名称]'
            name=${1:-ubuntu}
            chroot_exec "$name" -- /bin/bash -lc 'set -Eeuo pipefail; policy_created=0; cleanup_policy() { if [ "$policy_created" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi; }; trap cleanup_policy EXIT; if [ ! -e /usr/sbin/policy-rc.d ]; then printf "#!/bin/sh\\nexit 101\\n" > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d; policy_created=1; fi; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-standard ca-certificates curl locales openssh-server sudo systemd-sysv dbus bash procps util-linux kmod mount'
            ;;
        docker-check) chroot_docker_check "$@" ;;
        systemd-check) chroot_systemd_check "$@" ;;
        systemd-start) chroot_systemd_start "$@" ;;
        systemd-login) chroot_systemd_login "$@" ;;
        systemd-exec) chroot_systemd_exec "$@" ;;
        systemd-status) chroot_systemd_status "$@" ;;
        systemd-stop) chroot_systemd_stop "$@" ;;
        use-bash-sh) chroot_use_bash_sh "$@" ;;
        list|ls)
            require_arg_range 0 0 "$#" 'xtmoe chroot list'
            chroot_list
            ;;
        status)
            require_arg_range 0 1 "$#" 'xtmoe chroot status [名称]'
            chroot_root status "$(chroot_base)" "${1:-ubuntu}"
            ;;
        stop|umount)
            require_arg_range 0 1 "$#" 'xtmoe chroot stop [名称]'
            chroot_root stop "$(chroot_base)" "${1:-ubuntu}"
            ;;
        bind) chroot_bind "$@" ;;
        unbind) chroot_unbind "$@" ;;
        backup) chroot_backup "$@" ;;
        restore) chroot_restore "$@" ;;
        remove|rm) chroot_remove "$@" ;;
        *) die "未知 Chroot 操作：$action" ;;
    esac
}

