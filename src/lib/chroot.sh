#!/data/data/com.termux/files/usr/bin/bash

chroot_help() {
    cat <<'EOF'
Chroot 快捷命令（Android 7+、有效 Root、原生 Ubuntu 24.04）
  xtmoe chroot prepare
  xtmoe chroot install [ubuntu] [24.04] [名称]
  xtmoe chroot systemd-login [名称]
  xtmoe chroot stop [名称]
  xtmoe chroot status [名称]

安装自动检测基础挂载、systemd、Docker 和独立网络；显示实际选择。
systemd-login 按保存的实际方案进入，无 systemd 时进入基础 Shell。
备份、恢复、修复、服务、网络和端口映射请使用 xtmoe on。

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
    local helper proxy_values assignment
    local -a proxy_args=()
    helper=$(chroot_helper)
    proxy_values=$(chroot_proxy_environment) || return 1
    if [[ -n $proxy_values ]]; then
        while IFS= read -r assignment; do proxy_args+=(--proxy-env "$assignment"); done <<<"$proxy_values"
    fi
    # The parent keeps its flock descriptors. A long-lived systemd/dockerd
    # descendant must not inherit them and pin initialization locks forever.
    if [[ ${CHROOT_INSTALL_LOCK_FD:-} =~ ^[0-9]+$ ]]; then exec {CHROOT_INSTALL_LOCK_FD}>&-; fi
    if [[ ${CHROOT_INIT_LOCK_FD:-} =~ ^[0-9]+$ ]]; then exec {CHROOT_INIT_LOCK_FD}>&-; fi
    run_root "${PREFIX:?PREFIX 未设置}/bin/bash" "$helper" "$PREFIX" "${proxy_args[@]}" "$@"
)

# Only network proxy settings cross the Root boundary, never Termux PATH or LD_PRELOAD.
chroot_proxy_environment() { proxy_environment; }

require_chroot() {
    require_termux
    root_available || die '设备未授予 Root，或 tsu/su 不可用；请改用 PRoot 模式。'
}

chroot_prepare() {
    require_arg_range 0 0 "$#" 'xtmoe chroot prepare'
    require_termux
    require_command pkg '请使用官方 Termux 客户端'
    info '安装 Chroot 所需的 Termux 软件包……'
    DEBIAN_FRONTEND=noninteractive pkg install -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        tsu mount-utils util-linux coreutils curl tar socat || return 1
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
    for command in mount umount unshare nsenter chroot flock curl tar sha256sum realpath df install timeout; do
        command_exists "$command" || missing=1
    done
    if ((missing)); then
        info '检测到缺少宿主依赖，先执行 Chroot 依赖准备……'
        chroot_prepare || return 1
    fi
    require_chroot || return 1
    for command in mount umount unshare nsenter chroot flock curl tar sha256sum realpath df install timeout; do
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
    case "$(native_arch)" in
        arm64) printf arm64 ;; armhf) printf armhf ;; amd64) printf amd64 ;;
        *) die '当前用户空间架构没有受支持的 Ubuntu 24.04 Base 原生镜像' ;;
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
    info "默认执行全新安装：Chroot '$name'，Ubuntu 24.04；不会覆盖已有同名容器。"
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
    chroot_select_capabilities "$name" || return 1

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
    warn "阶段 $stage 未完成；保留 rootfs，可执行：xtmoe on → Chroot $name"
    return "$result"
}

chroot_select_capabilities() {
    local name=$1 report feature value
    report=$(chroot_root capabilities "$(chroot_base)" "$name") || return 1
    printf '%s\n' "$report"
    grep -qx base=supported <<<"$report" || { chroot_mark_partial "$name" capability; warn 'Root/私有 mount namespace 不可用，保留 rootfs；可改用 PRoot'; return 1; }
    for feature in systemd docker network; do
        value=$(awk -F= -v key="$feature" '$1==key {print $2}' <<<"$report")
        [[ $value == supported || $value == unsupported ]] || return 1
        chroot_meta_set "$name" "${feature}_capability" "$value"
    done
    if grep -qx systemd=unsupported <<<"$report"; then
        chroot_meta_set "$name" systemd_requested 0
        warn '此设备不满足 systemd 前置条件，安装保留基础 Ubuntu'
    fi
    if grep -qx docker=unsupported <<<"$report"; then warn '此设备不满足 Docker 前置条件，不会安装 Docker'; fi
    if grep -qx network=unsupported <<<"$report"; then
        chroot_root network-mode "$(chroot_base)" "$name" shared || return 1
        warn '能力方案：共享网络（Ubuntu 可见手机接口）'
    else
        chroot_root network-mode "$(chroot_base)" "$name" isolated || return 1
        info '能力方案：独立 IPv4 网络'
    fi
}

chroot_bootstrap() (
    local name=${1:?缺少容器名称} skip_bash_sh=0 skip_docker=0 accept_network=0 result init_supported=1 docker_supported=1
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
    [[ $(chroot_meta_get "$name" systemd_capability 2>/dev/null || true) != unsupported ]] || init_supported=0
    [[ $(chroot_meta_get "$name" docker_capability 2>/dev/null || true) != unsupported ]] || docker_supported=0
    mkdir -p "$(chroot_config_base)"
    exec {CHROOT_INIT_LOCK_FD}>"$(chroot_config_base)/$name.init.lock"
    flock -n "$CHROOT_INIT_LOCK_FD" || { warn '该容器正在执行另一项初始化；请等待后重试。'; return 1; }
    # Save user intent before any stage can fail. Metadata is not proof that a
    # service is running; repair always revalidates network and live services.
    chroot_meta_set "$name" systemd_requested "$init_supported"
    chroot_meta_set "$name" bash_sh_requested "$((1 - skip_bash_sh))"
    if ((skip_docker)); then chroot_meta_set "$name" docker_requested no; else chroot_meta_set "$name" docker_requested yes; fi

    chroot_stage "$name" dns chroot_apply_dns "$name" || return 1
    chroot_stage "$name" network chroot_network_preflight "$name" || return 1
    chroot_meta_set "$name" state network-ready

    chroot_stage "$name" packages chroot_setup "$name" || return 1
    chroot_meta_set "$name" state packages-ready
    # systemd-resolved's package scripts can replace the Base image's regular
    # resolv.conf with a 127.0.0.53 stub symlink even under policy-rc.d.
    chroot_stage "$name" dns-after-packages chroot_apply_dns "$name" || return 1

    if ((init_supported == 0)); then
        if ((docker_supported && skip_docker == 0)); then
            chroot_stage "$name" docker-direct chroot_docker_direct_install "$name" || return 1
        else
            chroot_meta_set "$name" docker_state unsupported
            warn '当前能力方案：基础 Ubuntu，无 systemd/Docker；请通过向导查看阻断项'
        fi
        chroot_meta_set "$name" state ready
        chroot_meta_set "$name" failed_stage ''
        chroot_meta_set "$name" current_stage complete
        return 0
    fi

    if ((skip_bash_sh)); then
        info '已按要求保留 /bin/sh'
    else
        chroot_stage "$name" bash chroot_use_bash_sh "$name" || return 1
    fi

    chroot_stage "$name" systemd chroot_systemd_start "$name" || return 1
    chroot_stage "$name" systemd-verify chroot_systemd_verify "$name" || return 1
    chroot_stage "$name" dns-after-systemd chroot_apply_dns "$name" || return 1
    chroot_stage "$name" network-after-systemd chroot_network_preflight "$name" || return 1
    chroot_meta_set "$name" state system-ready

    if ((skip_docker || docker_supported == 0)); then
        chroot_meta_set "$name" docker_requested no
        if ((docker_supported == 0)); then chroot_meta_set "$name" docker_state unsupported
        else chroot_meta_set "$name" docker_state skipped-by-user; fi
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
    # Display the bridge scope before configuration. Defaults execute without
    # reading stdin; --skip-docker is the explicit installation opt-out.
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
    ok "Chroot '$name' 基础 rootfs 和网络就绪；按原选择未配置 systemd/Docker，完整初始化可执行：xtmoe on → Chroot $name"
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
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu} base config mode
    require_name "$name"; base=$(chroot_base); config="$(chroot_config_base)/$name.binds"
    if [[ $(chroot_meta_get "$name" systemd_requested 2>/dev/null || true) == 1 ]]; then
        mode=$(chroot_root status "$base" "$name") || return 1
        case "$mode" in
            systemd|direct-docker) ;;
            *)
                chroot_systemd_start "$name" || return 1
                chroot_systemd_verify "$name" || return 1
                ;;
        esac
    fi
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
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    chroot_root systemd-check "$(chroot_base)" "${1:-ubuntu}"
}

chroot_systemd_start() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu} config
    require_name "$name"
    config="$(chroot_config_base)/$name.binds"
    chroot_apply_dns "$name" || return 1
    chroot_exec "$name" -- /bin/bash -c "$(chroot_docker_proxy_script)" || return 1
    chroot_root systemd-start "$(chroot_base)" "$name" "$config" || return 1
    chroot_systemd_network_refresh "$name"
}

# Also used for an already-running session: services/packages may have replaced
# resolv.conf, or Android/VPN routing may have changed since the previous start.
chroot_systemd_network_refresh() {
    local name=$1 result
    chroot_root network-refresh "$(chroot_base)" "$name" || return 1
    chroot_apply_dns "$name" || return 1
    if chroot_systemd_exec "$name" -- /bin/bash -c '
systemctl daemon-reload || exit 1
command -v dockerd >/dev/null 2>&1 || exit 3
state=$(systemctl show docker.service --property=ActiveState --value) || exit 1
case "$state" in active) exit 0;; inactive|failed|activating|deactivating) exit 3;; *) exit 1;; esac
'; then
        chroot_docker_routing_setup "$name"
    else
        result=$?
        ((result == 3)) || return "$result"
    fi
}

chroot_docker_proxy_script() {
    cat <<'PROXY_CONFIG'
set -Eeuo pipefail
directory=/etc/systemd/system/docker.service.d
file=$directory/90-xtmoe-proxy.conf
apply_mode=${1:-configure}
changed=0
apply_if_changed() {
    if [ "$apply_mode" = apply ] && [ "$changed" = 1 ]; then
        systemctl daemon-reload
        if systemctl is-active --quiet docker.service; then systemctl restart docker.service; fi
    fi
}
[ ! -L "$directory" ] || { printf "拒绝符号链接形式的 Docker 代理目录。\n" >&2; exit 1; }
if [ -e "$file" ] || [ -L "$file" ]; then
    [ ! -L "$file" ] && grep -q "^# XTMOE managed:" "$file" || { printf "拒绝覆盖非 XTMOE 代理配置。\n" >&2; exit 1; }
fi
entries=()
for key in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
    value=${!key-}
    [ -n "$value" ] || continue
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || exit 1
    assignment="$key=$value"
    assignment=${assignment//\\/\\\\}
    assignment=${assignment//\"/\\\"}
    assignment=${assignment//%/%%}
    entries+=("Environment=\"$assignment\"")
done
if ((${#entries[@]} == 0)); then
    if [ -e "$file" ]; then changed=1; fi
    rm -f -- "$file"
    apply_if_changed
    exit 0
fi
install -d -m 0755 "$directory"
temporary=$(mktemp "$directory/.xtmoe-proxy.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
chmod 0600 "$temporary"
printf '%s\n' '# XTMOE managed: proxy settings from the current Termux session.' '[Service]' "${entries[@]}" >"$temporary"
if ! cmp -s -- "$temporary" "$file"; then
    mv -T -- "$temporary" "$file"
    changed=1
else
    chmod 0600 "$file"
fi
apply_if_changed
PROXY_CONFIG
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
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    chroot_root systemd-status "$(chroot_base)" "${1:-ubuntu}"
}

chroot_systemd_stop() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    chroot_root systemd-stop "$(chroot_base)" "${1:-ubuntu}"
}

chroot_systemd_restart() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_systemd_stop "$name" || return 1
    chroot_systemd_start "$name" || return 1
    chroot_systemd_verify "$name"
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
if ! timeout 15 getent ahostsv4 "$host"; then
    if [ -n "${http_proxy:-${HTTP_PROXY:-}}${https_proxy:-${HTTPS_PROXY:-}}" ]; then
        printf "本地 DNS 未通过；使用已配置代理继续实际 APT 源验证，不把代理场景误判为直连失败。\n"
    else
        printf "DNS 解析失败；停止 APT/Docker 安装，请检查 VPN、私有 DNS 或网络。\n" >&2
        exit 1
    fi
fi
printf "验证已配置的 APT 源（源签名及下载错误均视为失败）……\n"
timeout --kill-after=5 600 apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o APT::Update::Error-Mode=any update
'
}

chroot_network_check() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_exec "$name" -- /bin/bash -lc '
failures=0
http_failures=0
icmp_status=unavailable
printf "%s\n" "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>&1 || failures=$((failures + 1))
case "$(dpkg --print-architecture)" in amd64|i386) host=archive.ubuntu.com; path=ubuntu;; *) host=ports.ubuntu.com; path=ubuntu-ports;; esac
printf -- "--- DNS: %s ---\n" "$host"
dns_failed=0
timeout 15 getent ahostsv4 "$host" 2>&1 || dns_failed=1
if [ "$dns_failed" -ne 0 ]; then
    if [ -n "${http_proxy:-${HTTP_PROXY:-}}${https_proxy:-${HTTPS_PROXY:-}}${all_proxy:-${ALL_PROXY:-}}" ]; then
        printf "本地 DNS 失败；后续 HTTP 检查验证代理路径，直连 DNS 仍未通过。\n"
    else
        failures=$((failures + 1))
    fi
fi
printf "%s\n" "--- ping -c 2 8.8.8.8 ---"
printf "%s\n" "ICMP/ping 不使用 HTTP/HTTPS 代理，仍遵循 Android/VPN 路由；此处只测数字 IP，不测试 DNS。"
if command -v ping >/dev/null 2>&1; then
    if timeout 10 ping -4 -n -c 2 -W 3 8.8.8.8 2>&1; then
        icmp_status=pass
    else
        icmp_status=failed
        printf "%s\n" "ICMP 检查未通过，不等于代理不可用；请结合 HTTP 结果检查 VPN/TUN、路由或目标限制。不会自动绕过 VPN。"
    fi
else
    printf "ping 未安装\n"
fi
printf "%s\n" "--- curl IPv4 Ubuntu source ---"
if command -v curl >/dev/null 2>&1; then
    for scheme in http https; do
        if ! curl -4 -fI --connect-timeout 10 --max-time 20 "$scheme://$host/$path/dists/noble/InRelease" 2>&1; then
            http_failures=$((http_failures + 1))
            failures=$((failures + 1))
        fi
    done
else
    printf "curl 未安装\n"
    http_failures=$((http_failures + 1))
    failures=$((failures + 1))
fi
printf "%s\n" "--- proxy environment ---"
for variable in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY; do
    value=${!variable-}
    if [ -n "$value" ]; then printf "%s=set\n" "$variable"; else printf "%s=unset\n" "$variable"; fi
done
printf "%s\n" "--- IPv4 addresses / policy routing ---"
if command -v ip >/dev/null 2>&1; then
    ip -4 -brief address 2>&1 || true
    ip -4 rule show 2>&1 || true
fi
printf "%s\n" "--- TCP listening ports (current Chroot network namespace) ---"
if command -v ss >/dev/null 2>&1; then ss -lnt 2>&1 || true; fi
printf "%s\n" "--- Docker / 1Panel services (if systemd is running) ---"
if [ -d /run/systemd/system ]; then
    timeout 10 systemctl --no-pager --all --type=service list-units "docker.service" "xtmoe-docker-routing.service" "1panel*.service" 2>&1 || true
fi
if command -v docker >/dev/null 2>&1 && timeout 10 docker info >/dev/null 2>&1; then
    printf "%s\n" "--- Docker containers / published ports ---"
    timeout 10 docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 || true
    printf "%s\n" "--- Docker default bridge ---"
    timeout 10 docker network inspect bridge --format "{{json .IPAM.Config}}" 2>&1 || true
fi
printf "DNS: local_failed=%s; ICMP: %s; HTTP/HTTPS: failures=%s\n" "$dns_failed" "$icmp_status" "$http_failures"
printf "%s\n" "HTTP 检查采用当前代理环境及 NO_PROXY；HTTP 通过不表示直连 DNS 或 ICMP 已修复。"
printf "Summary: failures=%s (ICMP is informational)\n" "$failures"
[ "$failures" -eq 0 ]
'
}

chroot_network_repair() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu} mode
    require_name "$name"
    mode=$(chroot_root status "$(chroot_base)" "$name") || return 1
    case "$mode" in
        systemd) chroot_systemd_network_refresh "$name" || return 1 ;;
        direct-docker)
            chroot_root network-refresh "$(chroot_base)" "$name" || return 1
            chroot_apply_dns "$name" || return 1
            info '已刷新独立网络与 DNS；共享模式的 Docker bridge 路由服务需要 systemd。'
            ;;
        mounted|stopped)
            chroot_root network-refresh "$(chroot_base)" "$name" || return 1
            chroot_apply_dns "$name" || return 1 ;;
        *) warn "无法识别容器运行状态：$mode"; return 1 ;;
    esac
    info '修复步骤已完成；保留已停止服务的状态。开始网络检测（检测失败仍返回失败）……'
    chroot_network_check "$name"
}

chroot_cgroup_check() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root cgroup-check "$(chroot_base)" "$name"
}

chroot_setup() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu} extra_packages=''
    if [[ $(chroot_meta_get "$name" systemd_capability 2>/dev/null || true) != unsupported ]]; then extra_packages='systemd-sysv dbus'; fi
    chroot_exec "$name" -- /bin/bash -lc "$(chroot_apt_guard_script)
$(chroot_userland_prepare_script)
dpkg --configure -a
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y coreutils ca-certificates curl locales tzdata man-db manpages less nano bash-completion apt-utils openssh-server sudo bash procps util-linux kmod mount iproute2 iptables iputils-ping $extra_packages
$(chroot_userland_restore_script)
for tool in install timeout mktemp flock ip getent; do command -v \"\$tool\" || exit 1; done
/usr/sbin/iptables --version
"
}

chroot_userland_prepare_script() {
    cat <<'USERLAND_PREPARE'
# Ubuntu Base ships a dpkg filter that discards manuals/docs/translations even
# for later apt installs. Only recognize the exact official Base filter; never
# rewrite user filtering policy or move files outside the guest.
xtmoe_base_filter=/etc/dpkg/dpkg.cfg.d/excludes
xtmoe_userland_state=/var/lib/xtmoe/userland
[ ! -L /var/lib/xtmoe ] && [ ! -L "$xtmoe_userland_state" ] && [ ! -L "$xtmoe_userland_state/restore.pending" ] || { printf 'Unsafe userland state path; refusing to change files.\n' >&2; exit 1; }
if [ -e "$xtmoe_base_filter" ] || [ -L "$xtmoe_base_filter" ]; then
    [ -f "$xtmoe_base_filter" ] && [ ! -L "$xtmoe_base_filter" ] || { printf 'Ubuntu Base filter is not a regular file; refusing to change it.\n' >&2; exit 1; }
    xtmoe_filter_rules=$(sed 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "$xtmoe_base_filter" | LC_ALL=C sort)
    xtmoe_expected_rules=$(printf '%s\n' \
        'path-exclude=/usr/share/man/*' \
        'path-exclude=/usr/share/locale/*/LC_MESSAGES/*.mo' \
        'path-exclude=/usr/share/doc/*' \
        'path-include=/usr/share/doc/*/copyright' \
        'path-include=/usr/share/doc/*/changelog.*' | LC_ALL=C sort)
    if [ "$xtmoe_filter_rules" != "$xtmoe_expected_rules" ]; then
        printf 'Custom dpkg excludes detected; preserving it. Full userland restoration needs manual policy review.\n' >&2
        exit 1
    fi
    install -d -m 0700 "$xtmoe_userland_state"
    xtmoe_filter_backup=$(mktemp "$xtmoe_userland_state/base-excludes.XXXXXX")
    cp -p -- "$xtmoe_base_filter" "$xtmoe_filter_backup"
    # Keep a pending marker before removing the filter so interrupted APT can resume.
    printf 'ubuntu-base-userland-v1\n' >"$xtmoe_userland_state/restore.pending"
    rm -- "$xtmoe_base_filter"
    printf 'Ubuntu Base minimization filter backed up; manuals/docs/translations enabled.\n'
fi
USERLAND_PREPARE
}

chroot_userland_restore_script() {
    cat <<'USERLAND_RESTORE'
xtmoe_userland_state=/var/lib/xtmoe/userland
# Ubuntu Base also diverts man to an informational stub which exits 0. Restore
# only the exact known stub and local diversion, retaining a recoverable copy.
xtmoe_minimized_man=$(cat <<'XTMOE_MINIMIZED_MAN'
#!/bin/sh
echo "This system has been minimized by removing packages and content that are"
echo "not required on a system that users do not log into."
echo ""
echo "To restore this content, including manpages, you can run the 'unminimize'"
echo "command. You will still need to ensure the 'man-db' package is installed."
XTMOE_MINIMIZED_MAN
)
if [ -f /usr/bin/man ] && [ ! -L /usr/bin/man ] && grep -q '^#!/bin/sh$' /usr/bin/man && [ "$(cat /usr/bin/man)" = "$xtmoe_minimized_man" ]; then
    [ "$(dpkg-divert --truename /usr/bin/man)" = /usr/bin/man.REAL ] && [ "$(dpkg-divert --listpackage /usr/bin/man)" = LOCAL ] || { printf 'Unknown man diversion; preserving it.\n' >&2; exit 1; }
    [ -x /usr/bin/man.REAL ] && [ ! -L /usr/bin/man.REAL ] || { printf 'Real man executable is missing; restore man-db first.\n' >&2; exit 1; }
    install -d -m 0700 "$xtmoe_userland_state"
    xtmoe_man_backup=$(mktemp "$xtmoe_userland_state/man-stub.XXXXXX")
    cp -p -- /usr/bin/man "$xtmoe_man_backup"
    rm -- /usr/bin/man
    if ! dpkg-divert --local --rename --remove /usr/bin/man; then
        [ -e /usr/bin/man ] || cp -p -- "$xtmoe_man_backup" /usr/bin/man
        exit 1
    fi
    printf 'Restored man-db executable from the official minimized-image diversion.\n'
fi
if [ -f "$xtmoe_userland_state/restore.pending" ]; then
    [ ! -L "$xtmoe_userland_state/restore.pending" ] && grep -qx ubuntu-base-userland-v1 "$xtmoe_userland_state/restore.pending" || { printf 'Unknown userland restore marker; preserving it.\n' >&2; exit 1; }
    xtmoe_restore_packages=()
    xtmoe_find_missing_userland() {
      xtmoe_restore_packages=()
      for xtmoe_sums in /var/lib/dpkg/info/*.md5sums; do
        [ -f "$xtmoe_sums" ] || continue
        xtmoe_package=${xtmoe_sums##*/}; xtmoe_package=${xtmoe_package%.md5sums}
        [[ $xtmoe_package =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]] || continue
        [ "$(dpkg-query -W -f='${db:Status-Status}' "$xtmoe_package" 2>/dev/null)" = installed ] || continue
        while read -r xtmoe_checksum xtmoe_relative; do
            case "$xtmoe_relative" in
                usr/share/doc/*|usr/share/man/*|usr/share/locale/*/LC_MESSAGES/*.mo)
                    [[ $xtmoe_relative != *'/../'* ]] || continue
                    if [ ! -e "/$xtmoe_relative" ] && [ ! -L "/$xtmoe_relative" ]; then
                        xtmoe_restore_packages+=("$xtmoe_package")
                        break
                    fi
                    ;;
            esac
        done <"$xtmoe_sums"
      done
    }
    xtmoe_find_missing_userland
    if ((${#xtmoe_restore_packages[@]})); then
        printf 'Restoring official documentation/translation files for %s installed packages.\n' "${#xtmoe_restore_packages[@]}"
        apt-get install -y --reinstall "${xtmoe_restore_packages[@]}"
    fi
    xtmoe_find_missing_userland
    ((${#xtmoe_restore_packages[@]} == 0)) || { printf 'Official userland files are still missing; keeping restore.pending for retry.\n' >&2; exit 1; }
    for xtmoe_manual in bash systemctl sudo; do
        xtmoe_manpath=$(man -w "$xtmoe_manual")
        [[ $xtmoe_manpath == /usr/share/man/* ]] || { printf 'Manual lookup returned a placeholder instead of a real page.\n' >&2; exit 1; }
    done
    rm -- "$xtmoe_userland_state/restore.pending"
    printf 'Ubuntu userland documentation restored.\n'
fi
# C.UTF-8 is provided by glibc, does not require a generated locale archive,
# and remains available without overriding an administrator locale preference.
if [ ! -e /etc/default/locale ]; then printf 'LANG=C.UTF-8\n' >/etc/default/locale; fi
USERLAND_RESTORE
}

chroot_apt_guard_script() {
    cat <<'APT_GUARD'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
apt-get() {
    command apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o DPkg::Lock::Timeout=30 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
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
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_apply_dns "$name" || return 1
    chroot_exec "$name" -- /bin/bash -lc "$(chroot_apt_guard_script)
apt-get -o APT::Update::Error-Mode=any update
apt-get dist-upgrade -y
if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi
" || return 1
    chroot_apply_dns "$name"
}

chroot_use_bash_sh() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    chroot_exec "$name" -- /bin/bash -lc 'set -e; [[ -x /usr/bin/bash ]] || { echo "缺少 /usr/bin/bash" >&2; exit 1; }; if command -v debconf-set-selections >/dev/null 2>&1 && command -v dpkg-reconfigure >/dev/null 2>&1; then printf "dash dash/sh boolean false\\n" | debconf-set-selections; DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive dash; fi; ln -sfn bash /bin/sh; readlink -f /bin/sh'
}

chroot_bind() {
    require_arg_range 3 4 "$#" 'xtmoe on → Chroot <名称> <宿主目录> <容器目录> [ro|rw]'
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
    require_arg_range 2 2 "$#" 'xtmoe on → Chroot <名称> <容器目录>'
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
    require_arg_range 1 2 "$#" 'xtmoe on → Chroot <名称> [文件]'
    local name=${1:?缺少容器名称} output=${2:-"$PWD/${1}-$(date +%Y%m%d-%H%M%S)-chroot.tar.gz"}
    local base
    require_name "$name"; base=$(chroot_base)
    chroot_root backup "$base" "$name" "$output" "$(id -u)" "$(id -g)"
    ok "备份已写入：$output"
}

chroot_restore() {
    require_arg_range 1 2 "$#" 'xtmoe on → Chroot <文件> [名称]'
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
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-check "$(chroot_base)" "$name"
}

chroot_confirm_network_changes() {
    local accepted=$1
    ((accepted)) && return 0
    warn '默认执行 Docker 网络准备：标准 bridge 会影响 Android 宿主 iptables、IP 转发及默认 bridge 精确策略路由；不需要 Docker 请使用 --skip-docker。'
    return 0
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
DEBIAN_FRONTEND=noninteractive apt-get install -y coreutils ca-certificates curl iptables iproute2
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
if [ -e /etc/docker/daemon.json ]; then dockerd --validate --config-file=/etc/docker/daemon.json; fi
DOCKER_PACKAGES
}

chroot_docker_kernel_check() { chroot_root docker-kernel-check "$(chroot_base)" "$1"; }

chroot_docker_compat_prepare() {
    local name=$1 result
    if chroot_root docker-network-prepare "$(chroot_base)" "$name"; then :; else result=$?; return "$result"; fi
    chroot_root docker-storage-prepare "$(chroot_base)" "$name"
}

chroot_docker_dependencies() {
    local name=$1 mode=${2:-systemd} packages='coreutils util-linux ca-certificates curl iptables iproute2'
    chroot_apply_dns "$name" || return 1
    chroot_network_preflight "$name" || return 1
    [[ $mode != systemd ]] || packages+=' systemd-sysv dbus'
    info '先补齐 Docker 用户态依赖，再检查 iptables 和 systemd……'
    chroot_exec "$name" -- /bin/bash -lc "$(chroot_apt_guard_script)
dpkg --configure -a
apt-get install -y $packages
/usr/sbin/iptables --version
" || return 1
    chroot_apply_dns "$name"
}

chroot_docker_routing_setup() {
    local name=$1 script unit
    script=$(<"$XTMOE_LIB_DIR/xtmoe-docker-routing")
    unit=$(<"$XTMOE_LIB_DIR/xtmoe-docker-routing.service")
    chroot_systemd_exec "$name" -- /bin/bash -c '
set -Eeuo pipefail
for file in /usr/local/libexec/xtmoe-docker-routing /etc/systemd/system/xtmoe-docker-routing.service; do
    if [ -e "$file" ] || [ -L "$file" ]; then
        [ ! -L "$file" ] && grep -q "^# XTMOE managed:" "$file" || { printf "拒绝覆盖非 XTMOE 管理文件：%s\n" "$file" >&2; exit 1; }
    fi
done
install -d -m 0755 /usr/local/libexec
printf "%s\n" "$1" >/usr/local/libexec/xtmoe-docker-routing.xtmoe.tmp
chmod 0755 /usr/local/libexec/xtmoe-docker-routing.xtmoe.tmp
mv -T /usr/local/libexec/xtmoe-docker-routing.xtmoe.tmp /usr/local/libexec/xtmoe-docker-routing
printf "%s\n" "$2" >/etc/systemd/system/xtmoe-docker-routing.service.xtmoe.tmp
chmod 0644 /etc/systemd/system/xtmoe-docker-routing.service.xtmoe.tmp
mv -T /etc/systemd/system/xtmoe-docker-routing.service.xtmoe.tmp /etc/systemd/system/xtmoe-docker-routing.service
systemctl daemon-reload
systemctl enable xtmoe-docker-routing.service
# start/enable --now is a no-op for an active oneshot (RemainAfterExit).
# Restart so the current Android/VPN route is probed on every explicit refresh.
systemctl restart xtmoe-docker-routing.service
' _ "$script" "$unit"
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
    ((${#positional[@]} <= 1)) || die 'xtmoe on → Chroot [--accept-host-network-changes] [名称]'
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
    if chroot_docker_compat_prepare "$name"; then :; else
        result=$?
        chroot_meta_set "$name" docker_state compatibility-failed
        return "$result"
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

    # Docker dependencies can run package hooks after bootstrap's DNS repair.
    # Repair again BEFORE dockerd starts and reads resolver configuration.
    if ! chroot_apply_dns "$name"; then
        chroot_meta_set "$name" docker_state dns-failed
        return 1
    fi

    if ! chroot_systemd_exec "$name" -- /bin/bash -lc 'set -e; systemctl daemon-reload; systemctl enable containerd.service docker.service; systemctl stop docker.service docker.socket; systemctl restart containerd.service; systemctl start docker.service'; then
        chroot_meta_set "$name" docker_state daemon-failed
        chroot_docker_logs "$name" || true
        return 1
    fi
    if ! chroot_docker_routing_setup "$name"; then
        chroot_meta_set "$name" docker_state bridge-routing-failed
        return 1
    fi
    if ! chroot_docker_status "$name" || ! chroot_systemd_verify "$name"; then
        chroot_meta_set "$name" docker_state daemon-failed
        chroot_docker_logs "$name" || true
        return 1
    fi
    info '验证 Docker registry 并拉取 hello-world……'
    if ! chroot_systemd_exec "$name" -- /usr/bin/timeout --kill-after=5 180 /usr/bin/docker pull hello-world; then
        chroot_meta_set "$name" docker_state daemon-ready-registry-unverified
        warn 'Docker daemon 可响应，但 registry 拉取失败；尚未进行本轮容器运行验收。'
        return 1
    fi
    info '镜像已拉取，运行 hello-world 验证存储、runc、cgroup 和实际容器……'
    if chroot_systemd_exec "$name" -- /usr/bin/timeout --kill-after=5 60 /usr/bin/docker run --rm --pull=never hello-world; then
        chroot_meta_set "$name" docker_state ready
        chroot_meta_set "$name" state docker-ready
        ok 'Docker daemon、socket、registry 和容器运行均已通过验收。'
        return 0
    else
        result=$?
    fi
    chroot_meta_set "$name" docker_state daemon-ready-container-failed
    warn 'Docker daemon 和 registry 已通过，但真实容器运行失败；请检查存储/runc/cgroup，不能误报为网络失败。'
    return "${result:-1}"
}

chroot_docker_start() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_start "$name" || return 1
    chroot_systemd_exec "$name" -- /usr/bin/systemctl start containerd.service docker.service || return 1
    chroot_systemd_network_refresh "$name" || return 1
    chroot_docker_status "$name"
}

chroot_docker_stop() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_exec "$name" -- /usr/bin/systemctl stop docker.service docker.socket containerd.service
}

chroot_docker_restart() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_start "$name" || return 1
    chroot_systemd_exec "$name" -- /bin/bash -ec 'systemctl start containerd.service; systemctl restart docker.service' || return 1
    chroot_systemd_network_refresh "$name" || return 1
    chroot_docker_status "$name"
}

chroot_docker_status() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    chroot_systemd_exec "$name" -- /bin/bash -lc '
set -u
failures=0
systemctl is-active containerd.service || failures=$((failures + 1))
systemctl is-active docker.service || failures=$((failures + 1))
if [ "$(systemctl show xtmoe-docker-routing.service --property=LoadState --value 2>/dev/null)" = loaded ]; then
    printf "default bridge routing: "
    systemctl is-active xtmoe-docker-routing.service || failures=$((failures + 1))
fi
[ -S /var/run/docker.sock ] && printf "socket: ready\n" || { printf "socket: missing\n"; failures=$((failures + 1)); }
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf "daemon: ready\n"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || failures=$((failures + 1))
else
    printf "daemon: unavailable\n"
    failures=$((failures + 1))
fi
systemctl is-system-running || true
[ "$failures" -eq 0 ]
'
}

chroot_docker_logs() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
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
    ((${#positional[@]} <= 1)) || die 'xtmoe on → Chroot [--accept-host-network-changes] [名称]'
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
    chroot_docker_compat_prepare "$name" || return $?
    info '安装 Docker Engine（direct dockerd 兼容模式，不依赖 systemctl）……'
    if ! chroot_exec "$name" -- /bin/bash -lc "$(chroot_docker_packages_script)"; then
        chroot_meta_set "$name" docker_state install-failed
        return 1
    fi
    chroot_systemd_stop "$name" || return 1
    chroot_docker_direct_start "$name"
}

chroot_docker_direct_start() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-start "$(chroot_base)" "$name" "$(chroot_config_base)/$name.binds" || return 1
    chroot_meta_set "$name" docker_state direct-daemon-ready
    info 'direct dockerd 已通过 docker info 验证；请额外运行 xtmoe on → Chroot 验证实际容器。'
}

chroot_docker_direct_stop() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-stop "$(chroot_base)" "$name" || return 1
    chroot_meta_set "$name" docker_state installed-stopped
}

chroot_docker_direct_status() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-status "$(chroot_base)" "$name"
}

chroot_docker_direct_logs() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
    local name=${1:-ubuntu}
    require_name "$name"
    chroot_root docker-direct-logs "$(chroot_base)" "$name"
}

chroot_docker_direct_run_test() {
    require_arg_range 0 1 "$#" 'xtmoe on → Chroot [名称]'
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
    if [[ $action == install ]]; then
        require_termux
        chroot_install "$@"
        return $?
    fi
    require_chroot
    ensure_dirs
    case "$action" in
        network-status|network-mode|port-add|port-list|port-remove)
            (($#)) || die '缺少容器名称'
            local network_name=$1; shift; require_name "$network_name"
            chroot_root "$action" "$(chroot_base)" "$network_name" "$@"
            ;;
        login) chroot_login "$@" ;;
        exec) chroot_exec "$@" ;;
        setup) chroot_setup "$@" ;;
        init) chroot_init "$@" ;;
        repair) chroot_repair "$@" ;;
        update-system) chroot_update_system "$@" ;;
        reinstall) chroot_reinstall "$@" ;;
        network-check) chroot_network_check "$@" ;;
        network-repair) chroot_network_repair "$@" ;;
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
        systemd-restart) chroot_systemd_restart "$@" ;;
        use-bash-sh) chroot_use_bash_sh "$@" ;;
        list)
            require_arg_range 0 0 "$#" 'xtmoe on → Chroot'
            chroot_list
            ;;
        status)
            require_arg_range 0 1 "$#" 'xtmoe chroot status [名称]'
            chroot_root status "$(chroot_base)" "${1:-ubuntu}"
            ;;
        stop)
            require_arg_range 0 1 "$#" 'xtmoe chroot stop [名称]'
            chroot_root stop "$(chroot_base)" "${1:-ubuntu}"
            ;;
        bind) chroot_bind "$@" ;;
        unbind) chroot_unbind "$@" ;;
        backup) chroot_backup "$@" ;;
        restore) chroot_restore "$@" ;;
        remove) chroot_remove "$@" ;;
        *) die "未知 Chroot 操作：$action" ;;
    esac
}
