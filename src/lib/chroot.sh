#!/data/data/com.termux/files/usr/bin/bash

chroot_help() {
    cat <<'EOF'
Chroot 模式（需要设备 Root；当前支持原生架构 Ubuntu Base 24.04）

  xtmoe chroot install [--yes] [--skip-systemd] [--skip-bash-sh] [--skip-docker]
                       [--accept-host-network-changes] [ubuntu] [24.04] [名称]
  xtmoe chroot prepare                    安装 tsu、mount-utils 等依赖
  xtmoe chroot login [名称]
  xtmoe chroot exec <名称> -- <命令>
  xtmoe chroot setup [名称]             更新 apt 并安装常用基础包
  xtmoe chroot init [--skip-docker] [--skip-bash-sh] [--accept-host-network-changes] [名称]
                                        一键配置已有 Ubuntu 的网络、基础包、systemd 和 Docker
  xtmoe chroot repair [--accept-host-network-changes] [名称]
  xtmoe chroot update-system [名称]
  xtmoe chroot reinstall [--yes] [--skip-docker] [--accept-host-network-changes] [名称]
  xtmoe chroot network-check [名称]
  xtmoe chroot cgroup-check [名称]
  xtmoe chroot docker-check [名称]      只读检查 Docker/1Panel 内核条件
  xtmoe chroot docker-install [--accept-host-network-changes] [名称]
  xtmoe chroot docker-start|docker-stop|docker-restart [名称]
  xtmoe chroot docker-status|docker-logs [名称]
  xtmoe chroot docker-direct-install [--accept-host-network-changes] [名称]
  xtmoe chroot docker-direct-start|docker-direct-stop [名称]
  xtmoe chroot docker-direct-status|docker-direct-logs|docker-direct-run-test [名称]
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

chroot_meta_file() {
    require_name "$1"
    printf '%s/%s.meta' "$(chroot_config_base)" "$1"
}

chroot_meta_get() {
    local name=$1 key=$2 file
    file=$(chroot_meta_file "$name")
    [[ -r $file ]] || return 1
    awk -F= -v expected="$key" '$1 == expected { sub(/^[^=]*=/, ""); print; found=1; exit } END { exit !found }' "$file"
}

chroot_meta_set() {
    local name=$1 key=$2 value=$3 file tmp directory
    [[ $key =~ ^[a-z][a-z0-9_]*$ ]] || die '非法 Chroot 元数据键。'
    [[ $value != *$'\n'* ]] || die 'Chroot 元数据值不能包含换行。'
    file=$(chroot_meta_file "$name")
    directory=$(dirname -- "$file")
    mkdir -p "$directory"
    tmp="$file.tmp.$$"
    if [[ -r $file ]]; then
        awk -F= -v expected="$key" '$1 != expected' "$file" >"$tmp"
    else
        : >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv -f -- "$tmp" "$file"
}

chroot_meta_initialize() {
    local name=$1 version=$2 arch=$3 docker_requested=$4 file tmp
    file=$(chroot_meta_file "$name")
    tmp="$file.tmp.$$"
    mkdir -p "$(dirname -- "$file")"
    printf 'distro=ubuntu\nversion=%s\narch=%s\nstate=base-ready\ndocker_requested=%s\n' \
        "$version" "$arch" "$docker_requested" >"$tmp"
    mv -f -- "$tmp" "$file"
}

chroot_mark_partial() {
    local name=$1 stage=$2
    chroot_meta_set "$name" state partial
    chroot_meta_set "$name" failed_stage "$stage"
}

chroot_helper() {
    local candidate="$XTMOE_LIB_DIR/xtmoe-root"
    [[ -r $candidate ]] || candidate="$XTMOE_LIB_DIR/../xtmoe-root"
    [[ -r $candidate ]] || candidate="${PREFIX:?PREFIX 未设置}/libexec/xtmoe/xtmoe-root"
    [[ -r $candidate ]] || die "缺少 Chroot 助手：$candidate"
    printf '%s' "$candidate"
}

chroot_root() (
    local helper
    helper=$(chroot_helper)
    # The parent keeps its flock descriptors. A long-lived systemd/dockerd
    # descendant must not inherit them and pin initialization locks forever.
    if [[ ${CHROOT_INSTALL_LOCK_FD:-} =~ ^[0-9]+$ ]]; then exec {CHROOT_INSTALL_LOCK_FD}>&-; fi
    if [[ ${CHROOT_INIT_LOCK_FD:-} =~ ^[0-9]+$ ]]; then exec {CHROOT_INIT_LOCK_FD}>&-; fi
    run_root "${PREFIX:?PREFIX 未设置}/bin/bash" "$helper" "$PREFIX" "$@"
)

require_chroot() {
    require_termux
    root_available || die '设备未授予 Root，或 tsu/su 不可用；请改用 PRoot 模式。'
}

chroot_prepare() {
    require_arg_range 0 0 "$#" 'xtmoe chroot prepare'
    require_termux
    require_command pkg '请使用官方 Termux 客户端'
    info '安装 Chroot 所需的 Termux 软件包……'
    pkg install -y tsu mount-utils util-linux coreutils curl tar || return 1
    if root_available; then
        ok 'Chroot 依赖与 Root 授权可用'
    else
        warn '依赖已安装，但未取得 Root；请检查 Magisk/KernelSU/APatch 授权。'
        return 1
    fi
}

chroot_install_preflight() {
    local available_kb command missing=0
    require_termux
    for command in tsu mount umount unshare nsenter chroot flock curl tar sha256sum realpath df; do
        command_exists "$command" || missing=1
    done
    if ((missing)); then
        info '检测到缺少宿主依赖，先执行 Chroot 依赖准备……'
        chroot_prepare || return 1
    fi
    require_chroot || return 1
    for command in mount umount unshare nsenter chroot flock curl tar sha256sum realpath df; do
        require_command "$command" '请执行 xtmoe chroot prepare'
    done
    ubuntu_arch >/dev/null
    mkdir -p "$XTMOE_DATA_DIR" "$XTMOE_CACHE_DIR"
    for command in "$XTMOE_DATA_DIR" "$XTMOE_CACHE_DIR"; do
        available_kb=$(df -Pk "$command" | awk 'NR == 2 {print $4}')
        [[ $available_kb =~ ^[0-9]+$ && $available_kb -ge 2097152 ]] || die '安装前要求数据和缓存所在文件系统各至少有 2 GiB 可用空间。'
    done
    ok '安装前置检查通过：Root、原生架构、依赖与可用空间'
}

ubuntu_arch() {
    case "$(uname -m)" in
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv8l|arm) printf 'armhf' ;;
        x86_64|amd64) printf 'amd64' ;;
        *) die "Ubuntu Base 不支持当前架构：$(uname -m)" ;;
    esac
}

chroot_apply_dns() {
    require_arg_range 0 1 "$#" 'xtmoe chroot dns-reset [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root set-dns "$(chroot_base)" "$name" 1.1.1.1 8.8.8.8
}

download_ubuntu_base() {
    local version=$1 arch index filename base_url sums archive line version_regex
    arch=$(ubuntu_arch)
    base_url="https://cdimage.ubuntu.com/ubuntu-base/releases/$version/release"
    mkdir -p "$XTMOE_CACHE_DIR/ubuntu-base/$version"
    index="$XTMOE_CACHE_DIR/ubuntu-base/$version/index.html"
    sums="$XTMOE_CACHE_DIR/ubuntu-base/$version/SHA256SUMS"

    info "读取 Ubuntu Base $version 官方发布列表……" >&2
    curl -fL --retry 3 --connect-timeout 20 -o "$index" "$base_url/" || return 1
    version_regex=${version//./[.]}
    filename=$(grep -oE "ubuntu-base-${version_regex}[.][0-9]+-base-${arch}[.]tar[.]gz" "$index" | sort -Vu | tail -n 1)
    [[ -n $filename ]] || die "没有找到 Ubuntu Base $version/$arch 镜像"
    archive="$XTMOE_CACHE_DIR/ubuntu-base/$version/$filename"

    curl -fL --retry 3 --connect-timeout 20 -o "$sums" "$base_url/SHA256SUMS" || return 1
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
    curl -fL --retry 3 --connect-timeout 20 --continue-at - -o "$archive" "$base_url/$filename" || return 1
    (cd -- "$(dirname -- "$archive")" && printf '%s\n' "$line" | sha256sum -c -) >&2 || return 1
    printf '%s' "$archive"
}

chroot_install() (
    local yes=0 skip_systemd=0 skip_bash_sh=0 skip_docker=0 accept_network=0
    local distro version name archive base config_base docker_requested=yes result CHROOT_INSTALL_LOCK_FD
    local -a positional=()
    while (($#)); do
        case $1 in
            --yes|-y) yes=1 ;;
            --skip-systemd) skip_systemd=1 ;;
            --skip-bash-sh) skip_bash_sh=1 ;;
            --skip-docker) skip_docker=1 ;;
            --accept-host-network-changes) accept_network=1 ;;
            --) shift; positional+=("$@"); break ;;
            -*) die "未知安装选项：$1" ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    ((${#positional[@]} <= 3)) || die 'xtmoe chroot install [选项] [ubuntu] [24.04] [名称]'
    distro=${positional[0]:-ubuntu}
    version=${positional[1]:-24.04}
    name=${positional[2]:-ubuntu}
    [[ $distro == ubuntu ]] || die 'Chroot 当前只支持 Ubuntu Base；其他发行版请使用 PRoot。'
    [[ $version == 24.04 ]] || die '当前经过配置的是 Ubuntu 24.04 LTS。'
    require_name "$name"
    if ((skip_systemd)); then
        skip_docker=1
        info '已选择跳过 systemd，因此同时跳过 Docker。'
    fi
    ((skip_docker)) && docker_requested=no
    if ((skip_docker == 0 && accept_network == 0)) && [[ ! -t 0 ]]; then
        die '非交互完整安装必须添加 --accept-host-network-changes；如不安装 Docker，请使用 --skip-docker。'
    fi
    ((yes)) && export XTMOE_YES=1
    if ((skip_docker == 0 && accept_network == 0)); then
        if chroot_confirm_network_changes 0; then accept_network=1; else skip_docker=1; docker_requested=no; fi
    fi
    ensure_dirs
    base=$(chroot_base); config_base=$(chroot_config_base)
    mkdir -p "$base" "$config_base"
    chroot_install_preflight || return 1
    exec {CHROOT_INSTALL_LOCK_FD}>"$config_base/$name.install.lock"
    flock -n "$CHROOT_INSTALL_LOCK_FD" || die '该名称正在执行另一项安装；请等待后重试。'
    [[ ! -e $base/$name && ! -L $base/$name ]] || die "Chroot 容器已存在：$name"
    confirm "创建 Chroot '$name' 并下载、初始化 Ubuntu 24.04？" || { info '已取消'; return 0; }
    archive=$(download_ubuntu_base "$version") || return 1
    chroot_meta_initialize "$name" "$version" "$(ubuntu_arch)" "$docker_requested"
    chroot_meta_set "$name" systemd_requested "$((1 - skip_systemd))"
    chroot_meta_set "$name" bash_sh_requested "$((1 - skip_bash_sh))"
    chroot_meta_set "$name" state extracting
    : >"$config_base/$name.binds"
    info "以 Root 身份解压并初始化 Chroot：$name"
    if ! chroot_root install "$base" "$name" "$archive" 1.1.1.1 8.8.8.8; then
        rm -f -- "$config_base/$name.meta" "$config_base/$name.binds"
        return 1
    fi
    chroot_meta_set "$name" state base-ready

    if ((skip_systemd)); then
        chroot_basic_repair "$name"
        return $?
    fi

    local -a bootstrap_args=()
    ((skip_bash_sh)) && bootstrap_args+=(--skip-bash-sh)
    ((skip_docker)) && bootstrap_args+=(--skip-docker)
    ((accept_network)) && bootstrap_args+=(--accept-host-network-changes)
    if chroot_bootstrap "$name" "${bootstrap_args[@]}"; then
        return 0
    else
        result=$?
    fi
    return "$result"
)

chroot_stage() {
    local name=$1 stage=$2 result
    shift 2
    chroot_meta_set "$name" current_stage "$stage"
    info "初始化阶段：$stage"
    if "$@"; then
        chroot_meta_set "$name" last_completed_stage "$stage"
        return 0
    else
        result=$?
    fi
    chroot_mark_partial "$name" "$stage"
    warn "阶段 $stage 未完成；保留 rootfs，可执行：xtmoe chroot repair $name"
    return "$result"
}

chroot_bootstrap() (
    local name=${1:?缺少容器名称} skip_bash_sh=0 skip_docker=0 accept_network=0 result
    local CHROOT_INIT_LOCK_FD
    shift
    while (($#)); do
        case "$1" in
            --skip-bash-sh) skip_bash_sh=1 ;;
            --skip-docker) skip_docker=1 ;;
            --accept-host-network-changes) accept_network=1 ;;
            *) die "未知初始化选项：$1" ;;
        esac
        shift
    done
    require_name "$name"
    mkdir -p "$(chroot_config_base)"
    exec {CHROOT_INIT_LOCK_FD}>"$(chroot_config_base)/$name.init.lock"
    flock -n "$CHROOT_INIT_LOCK_FD" || { warn '该容器正在执行另一项初始化；请等待后重试。'; return 1; }
    # Save user intent before any stage can fail. Metadata is not proof that a
    # service is running; repair always revalidates network and live services.
    chroot_meta_set "$name" systemd_requested 1
    chroot_meta_set "$name" bash_sh_requested "$((1 - skip_bash_sh))"
    if ((skip_docker)); then chroot_meta_set "$name" docker_requested no; else chroot_meta_set "$name" docker_requested yes; fi

    chroot_stage "$name" dns chroot_apply_dns "$name" || return 1
    chroot_stage "$name" network chroot_network_preflight "$name" || return 1
    chroot_meta_set "$name" state network-ready

    chroot_stage "$name" packages chroot_setup "$name" || return 1
    chroot_meta_set "$name" state packages-ready

    if ((skip_bash_sh)); then
        info '已按要求保留 /bin/sh'
    else
        chroot_stage "$name" bash chroot_use_bash_sh "$name" || return 1
    fi

    chroot_stage "$name" systemd chroot_systemd_start "$name" || return 1
    chroot_stage "$name" systemd-verify chroot_systemd_verify "$name" || return 1
    chroot_meta_set "$name" state system-ready

    if ((skip_docker)); then
        chroot_meta_set "$name" docker_requested no
        chroot_meta_set "$name" docker_state skipped-by-user
        chroot_meta_set "$name" state ready
        chroot_meta_set "$name" failed_stage ''
        chroot_meta_set "$name" current_stage complete
        ok "Chroot '$name' 已完成 Ubuntu/systemd 初始化；已跳过 Docker。"
        return 0
    fi

    chroot_meta_set "$name" docker_requested yes
    chroot_meta_set "$name" current_stage docker
    local -a docker_args=("$name")
    ((accept_network)) && docker_args=(--accept-host-network-changes "$name")
    if chroot_docker_install "${docker_args[@]}"; then
        chroot_meta_set "$name" state ready
        chroot_meta_set "$name" failed_stage ''
        chroot_meta_set "$name" current_stage complete
        if [[ $(chroot_meta_get "$name" docker_state 2>/dev/null || true) == skipped-by-user ]]; then
            ok "Chroot '$name' 已完成 Ubuntu/systemd 初始化；已按用户选择跳过 Docker。"
        else
            ok "Chroot '$name' 已完成 Ubuntu、systemd 和 Docker 初始化。"
        fi
        return 0
    else
        result=$?
    fi
    chroot_mark_partial "$name" docker
    if ((result == 2)); then
        warn 'Ubuntu/systemd 已完成，但 Docker 被内核或 Root 权限条件阻断。'
        return 2
    fi
    return "$result"
)

chroot_init() {
    local name=ubuntu argument name_set=0
    local -a args=()
    for argument in "$@"; do
        case "$argument" in
            --skip-docker|--skip-bash-sh|--accept-host-network-changes) args+=("$argument") ;;
            -*) die "未知 init 参数：$argument" ;;
            *) ((name_set == 0)) || die 'init 只接受一个容器名称'; name=$argument; name_set=1 ;;
        esac
    done
    require_name "$name"
    [[ -f $(chroot_base)/$name/.xtmoe-chroot ]] || die "Chroot 容器不存在：$name"
    # Resolve bridge consent before making configuration changes, not halfway
    # through APT/systemd setup. --yes never substitutes for this consent.
    if [[ " ${args[*]} " != *' --skip-docker '* && " ${args[*]} " != *' --accept-host-network-changes '* ]]; then
        if chroot_confirm_network_changes 0; then args+=(--accept-host-network-changes); else args+=(--skip-docker); fi
    fi
    chroot_bootstrap "$name" "${args[@]}"
}

chroot_basic_repair() (
    local name=$1 CHROOT_INIT_LOCK_FD
    mkdir -p "$(chroot_config_base)"
    exec {CHROOT_INIT_LOCK_FD}>"$(chroot_config_base)/$name.init.lock"
    flock -n "$CHROOT_INIT_LOCK_FD" || { warn '该容器正在初始化，请稍后重试。'; return 1; }
    chroot_stage "$name" dns chroot_apply_dns "$name" || return 1
    chroot_stage "$name" network chroot_network_preflight "$name" || return 1
    chroot_meta_set "$name" state ready
    chroot_meta_set "$name" failed_stage ''
    chroot_meta_set "$name" current_stage complete
    ok "Chroot '$name' 基础 rootfs 和网络就绪；按原选择未配置 systemd/Docker，完整初始化可执行：xtmoe chroot init $name"
)

chroot_systemd_verify() {
    chroot_systemd_exec "$1" -- /bin/bash -lc "$(chroot_systemd_verify_script)"
}

chroot_systemd_verify_script() {
    cat <<'SYSTEMD_VERIFY'
set -uo pipefail
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
for tool in timeout systemctl date mktemp; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'systemd 验证缺少命令：%s\n' "$tool" >&2; exit 1; }
done
errors=$(mktemp /run/xtmoe-systemd-verify.XXXXXX) || exit 1
trap 'rm -f -- "$errors"' EXIT
started=$(date +%s)
deadline=$((started + 120))
state=unknown
result=0
verify_run() {
    local seconds=$1 remaining
    shift
    remaining=$((deadline - $(date +%s)))
    ((remaining > 0)) || return 124
    ((seconds <= remaining)) || seconds=$remaining
    timeout --kill-after=2 "$seconds" "$@"
}
diagnose() {
    printf 'systemd 验证未通过：state=%s，probe_exit=%s\n' "${state:-无响应}" "$result" >&2
    if [ -s "$errors" ]; then cat "$errors" >&2; fi
    printf '%s\n' '--- 未完成的启动任务（不一定属于 failed 单元）---' >&2
    timeout --kill-after=2 5 systemctl list-jobs --no-pager >&2 || true
    printf '%s\n' '--- failed units ---' >&2
    timeout --kill-after=2 5 systemctl --failed --no-pager >&2 || true
    printf '%s\n' '--- 基础服务状态 ---' >&2
    timeout --kill-after=2 5 systemctl status basic.target dbus.service systemd-journald.service --no-pager >&2 || true
    printf '%s\n' '--- 最近 systemd journal ---' >&2
    timeout --kill-after=2 5 journalctl -b -n 40 --no-pager >&2 || true
}
while true; do
    result=0
    state=$(verify_run 8 systemctl is-system-running 2>"$errors") || result=$?
    printf 'systemd: %s（探测退出码 %s，%s/120 秒）\n' "${state:-无响应}" "$result" "$(( $(date +%s) - started ))"
    case "$state:$result" in
        running:0|degraded:1) break ;;
        initializing:1|starting:1) : ;;
        :124|:137) printf 'systemctl 单次探测超时，仍在总等待时限内重试。\n' >&2 ;;
        *)
            printf 'systemctl 未返回可接受的状态；保留错误，不把空输出当成成功。\n' >&2
            diagnose; exit 1
            ;;
    esac
    remaining=$((deadline - $(date +%s)))
    if ((remaining <= 0)); then
        printf 'systemd 在 120 秒内未完成启动；保留容器，请先查看下列待完成任务。\n' >&2
        diagnose; exit 1
    fi
    if [ -s "$errors" ]; then cat "$errors" >&2; fi
    pause=5; ((pause <= remaining)) || pause=$remaining
    sleep "$pause"
done
for unit in basic.target dbus.service systemd-journald.service; do
    result=0
    verify_run 8 systemctl is-active --quiet "$unit" 2>"$errors" || result=$?
    if ((result != 0)); then
        printf '基础单元未就绪：%s\n' "$unit" >&2
        diagnose; exit 1
    fi
done
if [ "$state" = degraded ]; then
    timeout --kill-after=2 5 systemctl --failed --no-pager || true
    printf 'systemd 可操作且基础单元正常，但存在其他失败单元；未标记为 running。\n' >&2
fi
SYSTEMD_VERIFY
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

chroot_network_preflight() {
    require_arg_range 0 1 "$#" 'xtmoe chroot network-preflight [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_exec "$name" -- /bin/bash -lc '
set -e
printf "resolv.conf:\n"
cat /etc/resolv.conf
case "$(dpkg --print-architecture)" in amd64|i386) host=archive.ubuntu.com;; *) host=ports.ubuntu.com;; esac
printf "Ubuntu DNS: %s\n" "$host"
getent ahostsv4 "$host" || { printf "DNS 解析失败；停止 APT/Docker 安装，请检查 VPN、私有 DNS 或网络。\n" >&2; exit 1; }
printf "验证已配置的 APT 源（源签名及下载错误均视为失败）……\n"
timeout --kill-after=5 600 apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o APT::Update::Error-Mode=any update
'
}

chroot_network_check() {
    require_arg_range 0 1 "$#" 'xtmoe chroot network-check [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_exec "$name" -- /bin/bash -lc '
failures=0
printf "%s\n" "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>&1 || failures=$((failures + 1))
case "$(dpkg --print-architecture)" in amd64|i386) host=archive.ubuntu.com; path=ubuntu;; *) host=ports.ubuntu.com; path=ubuntu-ports;; esac
printf -- "--- DNS: %s ---\n" "$host"
getent ahostsv4 "$host" 2>&1 || failures=$((failures + 1))
printf "%s\n" "--- ping -c 2 8.8.8.8 ---"
if command -v ping >/dev/null 2>&1; then ping -c 2 -W 3 8.8.8.8 2>&1 || printf "ICMP 可能被限制；以 APT/HTTP 检查结果为准。\n"; else printf "ping 未安装\n"; fi
printf "%s\n" "--- curl IPv4 Ubuntu source ---"
if command -v curl >/dev/null 2>&1; then
    for scheme in http https; do
        curl -4 -fI --connect-timeout 10 --max-time 20 "$scheme://$host/$path/dists/noble/InRelease" 2>&1 || failures=$((failures + 1))
    done
else
    printf "curl 未安装\n"
fi
printf "%s\n" "--- proxy environment ---"
for variable in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY; do
    value=${!variable-}
    if [ -n "$value" ]; then printf "%s=set\n" "$variable"; else printf "%s=unset\n" "$variable"; fi
done
printf "Summary: failures=%s\n" "$failures"
[ "$failures" -eq 0 ]
'
}

chroot_cgroup_check() {
    require_arg_range 0 1 "$#" 'xtmoe chroot cgroup-check [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root cgroup-check "$(chroot_base)" "$name"
}

chroot_setup() {
    require_arg_range 0 1 "$#" 'xtmoe chroot setup [名称]'
    local name=${1:-ubuntu}
    chroot_exec "$name" -- /bin/bash -lc "$(chroot_apt_guard_script)
dpkg --configure -a
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y ubuntu-standard ca-certificates curl locales openssh-server sudo systemd-sysv dbus bash procps util-linux kmod mount iproute2 iptables iputils-ping
command -v systemctl
/usr/sbin/iptables --version
"
}

chroot_apt_guard_script() {
    cat <<'APT_GUARD'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
apt-get() {
    command apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o DPkg::Lock::Timeout=30 "$@"
}
# Serialize package/service-policy changes, including an already running guest.
exec 9>/run/xtmoe-apt.lock
flock -w 30 9 || { printf '另一项 APT 操作正在执行，请稍后重试。\n' >&2; exit 1; }
policy_dir=$(mktemp -d /usr/sbin/.xtmoe-policy.XXXXXX)
cleanup_policy() {
    if [ -e "$policy_dir/original" ] || [ -L "$policy_dir/original" ]; then
        mv -Tf -- "$policy_dir/original" /usr/sbin/policy-rc.d
    else
        rm -f -- /usr/sbin/policy-rc.d
    fi
    rm -f -- "$policy_dir/guard"
    rmdir -- "$policy_dir"
}
if [ -e /usr/sbin/policy-rc.d ] || [ -L /usr/sbin/policy-rc.d ]; then
    cp -a -- /usr/sbin/policy-rc.d "$policy_dir/original"
fi
trap cleanup_policy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '#!/bin/sh\nexit 101\n' >"$policy_dir/guard"
chmod 0755 "$policy_dir/guard"
mv -Tf -- "$policy_dir/guard" /usr/sbin/policy-rc.d
APT_GUARD
}

chroot_update_system() {
    require_arg_range 0 1 "$#" 'xtmoe chroot update-system [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_exec "$name" -- /bin/bash -lc "$(chroot_apt_guard_script)
apt-get -o APT::Update::Error-Mode=any update
apt-get dist-upgrade -y
if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi
"
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
    printf 'restored_from=%s\nstate=ready\ndocker_requested=no\n' "$archive" >"$config_base/$name.meta"
    ok "已恢复为：$name"
}

chroot_docker_check() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-check [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-check "$(chroot_base)" "$name"
}

chroot_confirm_network_changes() {
    local accepted=$1 answer
    ((accepted)) && return 0
    [[ -t 0 ]] || die 'Docker 标准 bridge 会修改 Android 宿主网络规则；非交互模式必须添加 --accept-host-network-changes。'
    printf 'Docker 标准 bridge 会修改 Android 宿主 iptables 和 IP 转发。继续？ [y/N] ' >&2
    IFS= read -r answer
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

chroot_docker_packages_script() {
    chroot_apt_guard_script
    cat <<'DOCKER_PACKAGES'
for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f="\${Status}" "$package" 2>/dev/null | grep -q "ok installed"; then
        printf "检测到冲突软件包：%s；请先人工确认并卸载。\n" "$package" >&2
        exit 1
    fi
done
apt-get -o APT::Update::Error-Mode=any update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl iptables iproute2
install -m 0755 -d /etc/apt/keyrings
tmp_key=/etc/apt/keyrings/docker.asc.xtmoe.tmp
trap "rm -f -- $tmp_key; cleanup_policy" EXIT
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp_key"
chmod a+r "$tmp_key"
mv -f "$tmp_key" /etc/apt/keyrings/docker.asc
. /etc/os-release
codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
[ -n "$codename" ] || { printf "无法确定 Ubuntu codename\n" >&2; exit 1; }
architecture=$(dpkg --print-architecture)
tmp_source=/etc/apt/sources.list.d/docker.sources.xtmoe.tmp
printf "Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n" "$codename" "$architecture" >"$tmp_source"
mv -f "$tmp_source" /etc/apt/sources.list.d/docker.sources
apt-get -o APT::Update::Error-Mode=any update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if ! grep -qw overlay /proc/filesystems && [ ! -e /etc/docker/daemon.json ]; then
    install -d -m 0755 /etc/docker
    printf "%s\n" "{" "  \"storage-driver\": \"vfs\"" "}" >/etc/docker/daemon.json
    printf "OverlayFS 不可用，已配置低性能 vfs 存储驱动。\n" >&2
fi
DOCKER_PACKAGES
}

chroot_docker_kernel_check() { chroot_root docker-kernel-check "$(chroot_base)" "$1"; }

chroot_docker_dependencies() {
    local name=$1 mode=${2:-systemd} packages='ca-certificates curl iptables iproute2'
    chroot_network_preflight "$name" || return 1
    [[ $mode != systemd ]] || packages+=' systemd-sysv dbus'
    info '先补齐 Docker 用户态依赖，再检查 iptables 和 systemd……'
    chroot_exec "$name" -- /bin/bash -lc "$(chroot_apt_guard_script)
dpkg --configure -a
apt-get install -y $packages
/usr/sbin/iptables --version
"
}

chroot_docker_install() {
    local accept_network=0 name=ubuntu argument result
    local -a positional=()
    for argument in "$@"; do
        case "$argument" in
            --accept-host-network-changes) accept_network=1 ;;
            -*) die "未知 docker-install 参数：$argument" ;;
            *) positional+=("$argument") ;;
        esac
    done
    ((${#positional[@]} <= 1)) || die 'xtmoe chroot docker-install [--accept-host-network-changes] [名称]'
    name=${positional[0]:-ubuntu}
    require_name "$name"
    [[ -f $(chroot_base)/$name/.xtmoe-chroot ]] || die "Chroot 容器不存在：$name"
    if ! chroot_confirm_network_changes "$accept_network"; then
        info '已取消 Docker 安装。'
        chroot_meta_set "$name" docker_requested no
        chroot_meta_set "$name" docker_state skipped-by-user
        return 0
    fi
    if chroot_docker_kernel_check "$name"; then :; else
        result=$?
        if ((result == 2)); then
            chroot_meta_set "$name" docker_state kernel-blocked
            warn 'Docker 未安装：namespace/cgroup/转发等内核或 Root 权限条件未满足。'
        else
            chroot_meta_set "$name" docker_state check-failed
            warn 'Docker 内核检查执行异常，未安装 Docker。'
        fi
        return "$result"
    fi
    if ! chroot_docker_dependencies "$name"; then
        chroot_meta_set "$name" docker_state dependencies-failed
        warn 'Docker 依赖准备失败；这是网络/APT/用户态问题，不是已确认的内核阻断。'
        return 1
    fi
    if ! chroot_systemd_start "$name" || ! chroot_systemd_verify "$name"; then
        chroot_meta_set "$name" docker_state systemd-failed
        return 1
    fi
    if chroot_docker_check "$name"; then :; else
        result=$?
        if ((result == 2)); then
            chroot_meta_set "$name" docker_state kernel-blocked
            warn 'Docker 未安装：内核/Root 权限或 iptables NAT 能力未通过；未修改宿主规则。'
        else
            chroot_meta_set "$name" docker_state prerequisites-failed
            warn 'Docker 未安装：iptables 用户态依赖或 systemd 服务检查失败，不等同于内核不支持。'
        fi
        return "$result"
    fi

    info '配置 Docker 官方 APT 仓库并安装 Docker Engine……'
    if ! chroot_systemd_exec "$name" -- /bin/bash -lc "$(chroot_docker_packages_script)"; then
        chroot_meta_set "$name" docker_state install-failed
        chroot_docker_logs "$name" || true
        return 1
    fi

    if ! chroot_systemd_exec "$name" -- /bin/bash -lc 'set -e; systemctl enable containerd.service docker.service; systemctl restart containerd.service; systemctl restart docker.service'; then
        chroot_meta_set "$name" docker_state daemon-failed
        chroot_docker_logs "$name" || true
        return 1
    fi
    if ! chroot_docker_status "$name" || ! chroot_systemd_verify "$name"; then
        chroot_meta_set "$name" docker_state daemon-failed
        chroot_docker_logs "$name" || true
        return 1
    fi
    info '运行 Docker hello-world 实际容器验收……'
    if chroot_systemd_exec "$name" -- /usr/bin/docker run --rm hello-world; then
        chroot_meta_set "$name" docker_state ready
        chroot_meta_set "$name" state docker-ready
        ok 'Docker daemon、socket、registry 和容器运行均已通过验收。'
        return 0
    else
        result=$?
    fi
    chroot_meta_set "$name" docker_state daemon-ready-registry-unverified
    warn 'Docker daemon 可响应，但 hello-world 下载或运行失败；不能标记为完全可用。'
    return "${result:-1}"
}

chroot_docker_start() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-start [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_start "$name"
    chroot_systemd_exec "$name" -- /usr/bin/systemctl start containerd.service docker.service
    chroot_docker_status "$name"
}

chroot_docker_stop() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-stop [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_exec "$name" -- /usr/bin/systemctl stop docker.service containerd.service
}

chroot_docker_restart() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-restart [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_exec "$name" -- /usr/bin/systemctl restart containerd.service docker.service
    chroot_docker_status "$name"
}

chroot_docker_status() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-status [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_exec "$name" -- /bin/bash -lc '
set -u
failures=0
systemctl is-active containerd.service || failures=$((failures + 1))
systemctl is-active docker.service || failures=$((failures + 1))
[ -S /var/run/docker.sock ] && printf "socket: ready\n" || { printf "socket: missing\n"; failures=$((failures + 1)); }
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf "daemon: ready\n"
else
    printf "daemon: unavailable\n"
    failures=$((failures + 1))
fi
systemctl is-system-running || true
[ "$failures" -eq 0 ]
'
}

chroot_docker_logs() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-logs [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_exec "$name" -- /usr/bin/journalctl -u containerd.service -u docker.service -n 200 --no-pager
}

chroot_docker_direct_install() {
    local accept_network=0 name=ubuntu argument
    local -a positional=()
    for argument in "$@"; do
        case "$argument" in
            --accept-host-network-changes) accept_network=1 ;;
            -*) die "未知 docker-direct-install 参数：$argument" ;;
            *) positional+=("$argument") ;;
        esac
    done
    ((${#positional[@]} <= 1)) || die 'xtmoe chroot docker-direct-install [--accept-host-network-changes] [名称]'
    name=${positional[0]:-ubuntu}
    require_name "$name"
    [[ -f $(chroot_base)/$name/.xtmoe-chroot ]] || die "Chroot 容器不存在：$name"
    if ! chroot_confirm_network_changes "$accept_network"; then
        info '已取消直接 dockerd 安装。'
        return 0
    fi
    if ! chroot_docker_dependencies "$name" direct; then
        chroot_meta_set "$name" docker_state dependencies-failed
        return 1
    fi
    info '安装 Docker Engine（direct dockerd 兼容模式，不依赖 systemctl）……'
    if ! chroot_exec "$name" -- /bin/bash -lc "$(chroot_docker_packages_script)"; then
        chroot_meta_set "$name" docker_state install-failed
        return 1
    fi
    chroot_systemd_stop "$name" || return 1
    chroot_docker_direct_start "$name"
}

chroot_docker_direct_start() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-direct-start [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-start "$(chroot_base)" "$name" "$(chroot_config_base)/$name.binds" || return 1
    chroot_meta_set "$name" docker_state direct-daemon-ready
    info 'direct dockerd 已通过 docker info 验证；请额外运行 xtmoe chroot docker-direct-run-test 验证实际容器。'
}

chroot_docker_direct_stop() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-direct-stop [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-stop "$(chroot_base)" "$name" || return 1
    chroot_meta_set "$name" docker_state installed-stopped
}

chroot_docker_direct_status() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-direct-status [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-status "$(chroot_base)" "$name"
}

chroot_docker_direct_logs() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-direct-logs [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-logs "$(chroot_base)" "$name"
}

chroot_docker_direct_run_test() {
    require_arg_range 0 1 "$#" 'xtmoe chroot docker-direct-run-test [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    if chroot_root docker-direct-run-test "$(chroot_base)" "$name"; then
        chroot_meta_set "$name" docker_state direct-container-ready
    else
        chroot_meta_set "$name" docker_state direct-container-unverified
        return 1
    fi
}

chroot_repair() {
    local accept_network=0 name=ubuntu argument name_set=0
    for argument in "$@"; do
        case "$argument" in
            --accept-host-network-changes) accept_network=1 ;;
            -*) die "未知 repair 参数：$argument" ;;
            *) ((name_set == 0)) || die 'repair 只接受一个容器名称'; name=$argument; name_set=1 ;;
        esac
    done
    require_name "$name"
    [[ -f $(chroot_base)/$name/.xtmoe-chroot ]] || die "Chroot 容器不存在：$name"
    if [[ $(chroot_meta_get "$name" systemd_requested 2>/dev/null || printf 1) == 0 ]]; then
        chroot_basic_repair "$name"
        return $?
    fi
    local -a args=()
    [[ $(chroot_meta_get "$name" docker_requested 2>/dev/null || printf no) == yes ]] || args+=(--skip-docker)
    [[ $(chroot_meta_get "$name" bash_sh_requested 2>/dev/null || printf 0) == 1 ]] || args+=(--skip-bash-sh)
    ((accept_network)) && args+=(--accept-host-network-changes)
    chroot_init "$name" "${args[@]}"
}

chroot_reinstall() {
    local yes=0 skip_docker=0 accept_network=0 name=ubuntu argument name_set=0 base config_base
    for argument in "$@"; do
        case "$argument" in
            --yes|-y) yes=1 ;;
            --skip-docker) skip_docker=1 ;;
            --accept-host-network-changes) accept_network=1 ;;
            -*) die "未知 reinstall 参数：$argument" ;;
            *) ((name_set == 0)) || die 'reinstall 只接受一个容器名称'; name=$argument; name_set=1 ;;
        esac
    done
    require_name "$name"
    [[ -f $(chroot_base)/$name/.xtmoe-chroot ]] || die "Chroot 容器不存在：$name"
    if ((skip_docker == 0 && accept_network == 0)) && [[ ! -t 0 ]]; then
        die '非交互重装必须添加 --accept-host-network-changes；如不安装 Docker，请使用 --skip-docker。'
    fi
    ((yes)) && export XTMOE_YES=1
    confirm "重装 Chroot 容器 '$name'？rootfs 和 Docker 数据都会永久删除且不会自动备份" || { info '已取消'; return 0; }
    chroot_install_preflight || return 1
    download_ubuntu_base 24.04 >/dev/null || return 1
    base=$(chroot_base); config_base=$(chroot_config_base)
    chroot_root stop "$base" "$name" || return 1
    chroot_root remove "$base" "$name" || return 1
    rm -f -- "$config_base/$name.binds" "$config_base/$name.meta"
    local -a install_args=()
    install_args+=(--yes)
    ((skip_docker)) && install_args+=(--skip-docker)
    ((accept_network)) && install_args+=(--accept-host-network-changes)
    chroot_install "${install_args[@]}" ubuntu 24.04 "$name"
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
    local action=${1:-help}
    shift || true
    [[ $action == help || $action == -h || $action == --help ]] && { chroot_help; return; }
    [[ $action == prepare ]] && { chroot_prepare "$@"; return; }
    if [[ $action == install || $action == add ]]; then
        require_termux
        chroot_install "$@"
        return $?
    fi
    require_chroot
    ensure_dirs
    case "$action" in
        login|shell) chroot_login "$@" ;;
        exec) chroot_exec "$@" ;;
        setup) chroot_setup "$@" ;;
        init) chroot_init "$@" ;;
        repair) chroot_repair "$@" ;;
        update-system) chroot_update_system "$@" ;;
        reinstall) chroot_reinstall "$@" ;;
        network-check) chroot_network_check "$@" ;;
        cgroup-check) chroot_cgroup_check "$@" ;;
        docker-check) chroot_docker_check "$@" ;;
        docker-install) chroot_docker_install "$@" ;;
        docker-start) chroot_docker_start "$@" ;;
        docker-stop) chroot_docker_stop "$@" ;;
        docker-restart) chroot_docker_restart "$@" ;;
        docker-status) chroot_docker_status "$@" ;;
        docker-logs) chroot_docker_logs "$@" ;;
        docker-direct-install) chroot_docker_direct_install "$@" ;;
        docker-direct-start) chroot_docker_direct_start "$@" ;;
        docker-direct-stop) chroot_docker_direct_stop "$@" ;;
        docker-direct-status) chroot_docker_direct_status "$@" ;;
        docker-direct-logs) chroot_docker_direct_logs "$@" ;;
        docker-direct-run-test) chroot_docker_direct_run_test "$@" ;;
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
