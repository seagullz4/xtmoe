#!/data/data/com.termux/files/usr/bin/bash

proxy_help() {
    cat <<'EOF'
统一代理（保存到 Termux 用户配置，供后续 XTMOE 命令使用）

  xtmoe proxy                         查看状态
  xtmoe proxy on <URL或端口>           保存并启用 HTTP/HTTPS 代理，同步运行中的 Chroot
  xtmoe proxy on                      重新启用已保存地址；没有地址时交互输入
  xtmoe proxy set <URL或端口>          与 on 相同
  xtmoe proxy off                     关闭 XTMOE 显式代理并同步 Chroot，不关闭 Android VPN
  xtmoe proxy status                  查看状态（隐藏认证信息）
  xtmoe proxy test [HTTP/HTTPS测试URL] 验证实际代理请求，默认 https://github.com
  xtmoe proxy apply [Chroot名称]       同步指定或全部 Chroot；不启动已停止容器
  xtmoe proxy reset                   删除保存配置，恢复沿用当前 Termux 代理环境
  xtmoe proxy exec -- <命令>           在代理环境中运行 Termux 命令或子 Shell

示例：xtmoe proxy on http://127.0.0.1:7890
      xtmoe proxy on 7890
      xtmoe proxy on http://127.0.0.1:7890 --no-proxy localhost,127.0.0.1,::1

需要代理软件实际提供 HTTP/混合端口；纯 SOCKS 端口不能直接当 HTTP 代理。
支持 XTMOE 宿主下载、PRoot/Chroot 新会话和 Chroot Docker daemon 拉镜像。
不会修改父 Termux Shell，不是透明代理；QEMU 客体及 Docker 应用内部代理需单独配置。
HTTP/HTTPS 代理不承载 ping 的 ICMP；ping 失败不代表代理请求失败，请使用 proxy test。
Android VPN 是独立的全局/分应用网络层；即使 off，普通 curl 仍可能经 VPN 使用代理出口。
reset 是删除保存配置并恢复继承环境，不等于强制关闭代理。
EOF
}

proxy_config_file() { printf '%s/proxy.conf' "$XTMOE_CONFIG_DIR"; }

proxy_validate_url() {
    local url=$1 authority host port=''
    [[ $url == http://* || $url == https://* ]] || return 1
    [[ $url != *[[:space:][:cntrl:]]* ]] || return 1
    authority=${url#*://}; authority=${authority%/}
    case "$authority" in ''|*/*|*'?'*|*'#'*|*'\'*) return 1 ;; esac
    host=${authority##*@}
    [[ -n $host && ( $authority != *@* || ${authority%@*} != *'@'* && -n ${authority%@*} ) ]] || return 1
    if [[ $host == \[* ]]; then
        [[ $host =~ ^\[[0-9A-Fa-f:]+\](:([0-9]{1,5}))?$ ]] || return 1
        port=${BASH_REMATCH[2]:-}
    else
        [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:([0-9]{1,5}))?$ ]] || return 1
        port=${BASH_REMATCH[2]:-}
    fi
    [[ -z $port ]] || ((10#$port >= 1 && 10#$port <= 65535))
}

proxy_validate_bypass() {
    [[ $1 != *[[:space:][:cntrl:]]* && $1 != *'"'* && $1 != *"'"* && $1 != *'\'* ]]
}

proxy_normalize_bypass() {
    local item result=''
    local -a items=()
    local -A seen=()
    IFS=, read -r -a items <<<"$1,localhost,127.0.0.1,::1"
    for item in "${items[@]}"; do
        [[ -n $item && ! ${seen[$item]+set} ]] || continue
        seen[$item]=1
        result+="${result:+,}$item"
    done
    printf '%s' "$result"
}

proxy_read() {
    local file key value
    local -A seen=()
    XTMOE_PROXY_ENABLED=inherit
    XTMOE_PROXY_URL=''
    XTMOE_PROXY_BYPASS='localhost,127.0.0.1,::1'
    file=$(proxy_config_file)
    [[ -e $file || -L $file ]] || return 0
    [[ -f $file && ! -L $file && -O $file && -r $file ]] || { warn '代理配置不是本人可读的普通文件，拒绝加载。'; return 1; }
    while IFS='=' read -r key value || [[ -n $key ]]; do
        [[ -n $key && ! ${seen[$key]+set} ]] || { warn '代理配置存在空行或重复键。'; return 1; }
        seen[$key]=1
        case "$key" in
            version) [[ $value == 1 ]] || return 1 ;;
            enabled) [[ $value == 0 || $value == 1 ]] || return 1; XTMOE_PROXY_ENABLED=$value ;;
            url) [[ -z $value ]] || proxy_validate_url "$value" || return 1; XTMOE_PROXY_URL=$value ;;
            no_proxy) proxy_validate_bypass "$value" || return 1; XTMOE_PROXY_BYPASS=$value ;;
            *) warn '代理配置包含未知键，拒绝加载。'; return 1 ;;
        esac
    done <"$file"
    for key in version enabled url no_proxy; do [[ ${seen[$key]+set} ]] || return 1; done
    [[ $XTMOE_PROXY_ENABLED != 1 || -n $XTMOE_PROXY_URL ]]
}

proxy_clear_environment() {
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
}

proxy_load() {
    proxy_read || { warn '无法读取代理配置；可使用 xtmoe proxy off/reset 修复。'; return 1; }
    case "$XTMOE_PROXY_ENABLED" in
        1)
            proxy_clear_environment
            export http_proxy="$XTMOE_PROXY_URL" HTTP_PROXY="$XTMOE_PROXY_URL"
            export https_proxy="$XTMOE_PROXY_URL" HTTPS_PROXY="$XTMOE_PROXY_URL"
            export no_proxy="$XTMOE_PROXY_BYPASS" NO_PROXY="$XTMOE_PROXY_BYPASS"
            ;;
        0) proxy_clear_environment ;;
        inherit) ;;
    esac
}

proxy_write() (
    local enabled=$1 url=$2 bypass=$3 file temporary
    file=$(proxy_config_file)
    [[ ! -L $XTMOE_CONFIG_DIR && ! -L $file && ( ! -e $file || -f $file && -O $file ) ]] || { warn '拒绝覆盖不安全的代理配置路径。'; return 1; }
    [[ $enabled == 0 || $enabled == 1 ]] || return 1
    [[ -z $url ]] || proxy_validate_url "$url" || return 1
    [[ $enabled != 1 || -n $url ]] || return 1
    proxy_validate_bypass "$bypass" || return 1
    umask 077
    mkdir -p "$XTMOE_CONFIG_DIR" || return 1
    temporary=$(mktemp "$file.tmp.XXXXXX") || return 1
    trap 'rm -f -- "$temporary"' EXIT
    printf 'version=1\nenabled=%s\nurl=%s\nno_proxy=%s\n' "$enabled" "$url" "$bypass" >"$temporary" || return 1
    chmod 0600 "$temporary" || return 1
    mv -T -- "$temporary" "$file"
)

proxy_mask_url() {
    local scheme=${1%%://*} authority=${1#*://}
    if [[ $authority == *@* ]]; then authority="***@${authority##*@}"; fi
    printf '%s://%s' "$scheme" "$authority"
}

proxy_status() {
    proxy_load || return 1
    case "$XTMOE_PROXY_ENABLED" in
        1) printf 'XTMOE 代理：已启用（持久配置）\n地址：%s\n' "$(proxy_mask_url "$XTMOE_PROXY_URL")" ;;
        0) printf 'XTMOE 代理：已关闭（覆盖当前 XTMOE 进程继承的代理）\n' ;;
        inherit)
            printf 'XTMOE 代理：未保存配置，沿用当前 Termux 环境\n'
            local value=${http_proxy:-${HTTP_PROXY:-${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}}}
            if [[ -n $value ]]; then printf '环境地址：%s\n' "$(proxy_mask_url "$value")"; else printf '环境中未设置代理\n'; fi
            ;;
    esac
    printf '状态仅表示配置；实际连通性请运行 xtmoe proxy test。\n'
    printf 'HTTP/HTTPS 代理不承载 ICMP/ping；ping 仍遵循 Android/VPN 路由。\n'
    printf '关闭 XTMOE 显式代理不会关闭 Android VPN；普通 curl 的出口仍可能受 VPN、父 Shell 或 curl 配置影响。\n'
}

proxy_sync_chroots() {
    local name mode failures=0
    local -a names=()
    if (($#)); then
        require_name "$1"
        [[ -f $(chroot_base)/$1/.xtmoe-chroot ]] || { warn '指定的 Chroot 不存在。'; return 1; }
        names=("$1")
    else
        mapfile -t names < <(manager_chroot_names)
    fi
    ((${#names[@]})) || return 0
    root_available || { warn '配置已保存，但当前未取得 Root；Chroot 同步未完成。'; return 1; }
    for name in "${names[@]}"; do
        if ! mode=$(chroot_root status "$(chroot_base)" "$name"); then failures=1; continue; fi
        case "$mode" in
            systemd)
                if chroot_systemd_exec "$name" -- /bin/bash -c "$(chroot_docker_proxy_script)" _ apply && chroot_systemd_network_refresh "$name"; then
                    ok "$name：代理配置已同步；运行中的 Docker 仅在配置变化时重启。"
                else
                    warn "$name：配置已保存，但服务同步失败，请检查 Docker 状态。"
                    failures=1
                fi
                ;;
            direct-docker)
                warn "$name：direct daemon 需执行 docker-direct-stop/start 重启后使用新代理。"
                failures=1
                ;;
            stopped|mounted) info "$name：保持当前状态，重新进入时使用代理配置。" ;;
            *) warn "$name：无法识别运行状态，未修改服务。"; failures=1 ;;
        esac
    done
    return "$failures"
}

proxy_enable() {
    local url='' bypass='localhost,127.0.0.1,::1' argument url_set=0 bypass_set=0
    while (($#)); do
        argument=$1; shift
        case "$argument" in
            --no-proxy) (($#)) || die '--no-proxy 缺少值'; bypass=$1; bypass_set=1; shift ;;
            -*) die '未知代理参数；请查看 xtmoe proxy help。' ;;
            *) ((url_set == 0)) || die '只能指定一个代理地址。'; url=$argument; url_set=1 ;;
        esac
    done
    if ((url_set == 0)); then
        proxy_read || return 1
        url=$XTMOE_PROXY_URL
        ((bypass_set)) || bypass=$XTMOE_PROXY_BYPASS
        if [[ -z $url ]]; then
            [[ -t 0 ]] || die '尚未保存地址。请执行 xtmoe proxy on http://127.0.0.1:端口'
            printf '请输入 HTTP/混合代理地址或端口：' >&2
            IFS= read -r url || return 1
        fi
    fi
    if [[ $url =~ ^[0-9]{1,5}$ ]]; then url="http://127.0.0.1:$url"; fi
    proxy_validate_url "$url" || die '代理地址无效；需要 http:// 或 https:// 地址和有效端口，纯 SOCKS 请使用代理软件的 HTTP/混合端口。'
    proxy_validate_bypass "$bypass" || die 'NO_PROXY 不能包含空白、引号或换行。'
    bypass=$(proxy_normalize_bypass "$bypass")
    proxy_write 1 "$url" "$bypass" || return 1
    proxy_load || return 1
    ok "已保存代理：$(proxy_mask_url "$url")"
    proxy_sync_chroots
}

proxy_test() {
    local target=${1:-https://github.com} url result
    [[ $target == http://* || $target == https://* ]] && [[ $target != *[[:space:][:cntrl:]]* ]] || die '测试目标需要 HTTP/HTTPS URL。'
    proxy_load || return 1
    if [[ $target == https://* ]]; then
        url=${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}}}
    else
        url=${http_proxy:-${HTTP_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}
    fi
    [[ -n $url ]] || { warn '当前没有启用代理；请先执行 xtmoe proxy on。'; return 1; }
    require_command curl '请运行 sh termux.sh 安装依赖'
    curl --version >/dev/null 2>&1 || { warn 'curl 本身无法运行；请先修复 Termux 软件包/运行库（pkg upgrade），再测试代理。'; return 1; }
    # Never let curl print credential-bearing proxy URLs on error.
    if curl --proxy "$url" --noproxy '' --head --fail --silent --connect-timeout 10 --max-time 30 --output /dev/null "$target" 2>/dev/null; then
        ok '代理实际 HTTP/HTTPS 请求通过。'
        info '此结果验证代理请求，不代表 ICMP/ping 可用；ping 仍遵循 Android/VPN 路由。'
    else
        result=$?
        warn "代理测试失败（curl 退出码 $result）；检查代理软件、HTTP 端口和应用联网规则。"
        return "$result"
    fi
}

proxy_main() {
    local action=${1:-status} url='' file bypass='localhost,127.0.0.1,::1'
    shift || true
    [[ $action == help || $action == --help || $action == -h ]] && { proxy_help; return 0; }
    require_termux
    case "$action" in
        on|set|enable) proxy_enable "$@" ;;
        off|disable)
            require_arg_range 0 0 "$#" 'xtmoe proxy off'
            if proxy_read; then url=$XTMOE_PROXY_URL; bypass=$XTMOE_PROXY_BYPASS; fi
            proxy_write 0 "$url" "$bypass" || return 1
            proxy_load || return 1
            ok '已关闭 XTMOE 代理。'
            info '仅关闭 XTMOE 显式代理；Android VPN 需在手机代理软件中关闭，已打开的父 Shell 不会被修改。'
            proxy_sync_chroots
            ;;
        status)
            require_arg_range 0 0 "$#" 'xtmoe proxy status'
            proxy_status
            ;;
        test) require_arg_range 0 1 "$#" 'xtmoe proxy test [URL]'; proxy_test "$@" ;;
        apply) require_arg_range 0 1 "$#" 'xtmoe proxy apply [Chroot名称]'; proxy_load && proxy_sync_chroots "$@" ;;
        reset)
            require_arg_range 0 0 "$#" 'xtmoe proxy reset'
            file=$(proxy_config_file)
            [[ ! -L $file && ( ! -e $file || -f $file && -O $file ) ]] || die '拒绝删除不安全的代理配置路径。'
            rm -f -- "$file" || return 1
            proxy_load || return 1
            ok '已删除保存配置，恢复沿用当前 Termux 环境。'
            info 'reset 不等于关闭代理；若父 Shell 已设置代理或 Android VPN 仍开启，流量仍可能经过代理。'
            proxy_sync_chroots
            ;;
        exec)
            [[ ${1:-} == -- ]] && shift
            (($#)) || die '用法：xtmoe proxy exec -- <命令>'
            proxy_load || return 1
            "$@"
            ;;
        http://*|https://*|[0-9]*) proxy_enable "$action" "$@" ;;
        *) die '未知代理操作；请查看 xtmoe proxy help。' ;;
    esac
}
