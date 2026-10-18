#!/data/data/com.termux/files/usr/bin/bash

manager_proot_names() {
    local directory entry
    for directory in \
        "${PREFIX:?PREFIX 未设置}/var/lib/proot-distro/containers" \
        "$PREFIX/var/lib/proot-distro/installed-rootfs"; do
        [[ -d $directory ]] || continue
        for entry in "$directory"/*; do
            [[ -d $entry/rootfs ]] || continue
            basename -- "$entry"
        done
    done | sort -u
}

manager_proot_sessions() {
    command_exists proot-distro || return 0
    proot-distro ps 2>/dev/null | awk '
        NR == 1 && $1 == "PID" { next }
        $1 ~ /^[0-9]+$/ && NF >= 2 { count[$2]++ }
        END { for (name in count) print name, count[name] }
    ' | sort
}

manager_chroot_names() {
    local base entry
    base=$(chroot_base)
    [[ -d $base ]] || return 0
    for entry in "$base"/*; do
        [[ -d $entry/rootfs && -f $entry/.xtmoe-chroot ]] || continue
        basename -- "$entry"
    done | sort
}

manager_docker_state() {
    local name=$1 base state
    base=$(chroot_base)
    state=$(chroot_root docker-state "$base" "$name" 2>/dev/null || true)
    printf '%s' "${state:-unknown}"
}

manager_collect_rows() {
    local include_all=$1 name state init_state docker_state count root_state=0
    local -A proot_counts=()
    local -a sessions=() chroot_names=()

    XTMOE_LIST_MODES=()
    XTMOE_LIST_NAMES=()
    XTMOE_LIST_STATES=()
    XTMOE_LIST_INIT=()
    XTMOE_LIST_DOCKER=()

    mapfile -t sessions < <(manager_proot_sessions)
    for state in "${sessions[@]}"; do
        [[ -n $state ]] || continue
        name=${state% *}
        count=${state##* }
        proot_counts["$name"]=$count
    done

    while IFS= read -r name; do
        [[ -n $name ]] || continue
        count=${proot_counts[$name]:-0}
        ((include_all || count > 0)) || continue
        if ((count > 0)); then
            state="running($count)"
        else
            state='stopped'
        fi
        XTMOE_LIST_MODES+=(proot)
        XTMOE_LIST_NAMES+=("$name")
        XTMOE_LIST_STATES+=("$state")
        XTMOE_LIST_INIT+=(ready)
        XTMOE_LIST_DOCKER+=('unsupported')
    done < <(manager_proot_names)

    mapfile -t chroot_names < <(manager_chroot_names)
    if ((${#chroot_names[@]} > 0)) && root_available; then
        root_state=1
    fi
    for name in "${chroot_names[@]}"; do
        [[ -n $name ]] || continue
        if ((root_state)); then
            if ! state=$(chroot_root status "$(chroot_base)" "$name" 2>/dev/null); then
                state=unknown
            fi
        else
            state=unknown
        fi
        [[ $state != stopped || $include_all == 1 ]] || continue
        [[ $state != unknown || $include_all == 1 ]] || continue
        init_state=$(chroot_meta_get "$name" state 2>/dev/null || true)
        if [[ $state == unknown ]]; then
            docker_state=unknown
        else
            docker_state=$(manager_docker_state "$name")
        fi
        XTMOE_LIST_MODES+=(chroot)
        XTMOE_LIST_NAMES+=("$name")
        XTMOE_LIST_STATES+=("$state")
        XTMOE_LIST_INIT+=("${init_state:-unknown}")
        XTMOE_LIST_DOCKER+=("$docker_state")
    done


}

list_main() {
    local include_all=0 no_prompt=0 argument index choice
    for argument in "$@"; do
        case "$argument" in
            --all) include_all=1 ;;
            --running) include_all=0 ;;
            --no-prompt) no_prompt=1 ;;
            *) die "未知 list 参数：$argument" ;;
        esac
    done
    require_termux
    ensure_dirs
    manager_collect_rows "$include_all"

    printf '%-4s %-8s %-24s %-14s %-14s %s\n' '#' 'MODE' 'NAME' 'STATE' 'INIT' 'DOCKER'
    for ((index = 0; index < ${#XTMOE_LIST_NAMES[@]}; index++)); do
        printf '%-4s %-8s %-24s %-14s %-14s %s\n' \
            "$((index + 1))" "${XTMOE_LIST_MODES[index]}" "${XTMOE_LIST_NAMES[index]}" \
            "${XTMOE_LIST_STATES[index]}" "${XTMOE_LIST_INIT[index]}" "${XTMOE_LIST_DOCKER[index]}"
    done

    if ((${#XTMOE_LIST_NAMES[@]} == 0)); then
        info '没有符合条件的运行系统；使用 xtmoe on 或 xtmoe list --all。'
        return 0
    fi
    ((no_prompt == 0)) && [[ -t 0 && -t 1 ]] || return 0
    printf '输入编号进入系统，直接回车退出：' >&2
    IFS= read -r choice
    [[ -n $choice ]] || return 0
    [[ $choice =~ ^[0-9]{1,3}$ ]] || die '请输入列表中的数字编号。'
    choice=$((10#$choice))
    ((choice >= 1 && choice <= ${#XTMOE_LIST_NAMES[@]})) || die '编号超出范围。'
    index=$((choice - 1))
    enter_main "${XTMOE_LIST_MODES[index]}" "${XTMOE_LIST_NAMES[index]}"
}

enter_main() {
    require_arg_range 2 2 "$#" 'xtmoe enter <proot|chroot> <名称>'
    local mode=$1 name=$2
    require_name "$name"
    case "$mode" in
        proot)
            proot_exists "$name" || die "PRoot 容器不存在：$name"
            proot_main login "$name"
            ;;
        chroot)
            [[ -f $(chroot_base)/$name/.xtmoe-chroot ]] || die "Chroot 容器不存在：$name"
            chroot_main login "$name"
            ;;
        *) die "未知模式：$mode（只能是 proot 或 chroot）" ;;
    esac
}

menu_read() {
    local prompt=$1 default=${2:-} value
    if [[ -n $default ]]; then
        printf '%s [%s]：' "$prompt" "$default" >&2
    else
        printf '%s：' "$prompt" >&2
    fi
    IFS= read -r value || return 1
    printf '%s' "${value:-$default}"
}

menu_run() {
    local result
    # A conditional subshell disables errexit in nested installers.
    set +e
    ( set -Eeuo pipefail; if [[ $1 != proxy_main ]] && declare -F proxy_load >/dev/null; then proxy_load; fi; "$@" )
    result=$?
    set -e
    if ((result != 0)); then
        warn '操作未完成；请根据上方错误修复后重试。'
    fi
}

menu_select_container() {
    local mode=$1 title=${2:-请选择容器} choice index
    local -a names=()
    MENU_SELECTED_NAME=''
    case "$mode" in
        proot) mapfile -t names < <(manager_proot_names) ;;
        chroot) mapfile -t names < <(manager_chroot_names) ;;
        *) die "内部错误：未知容器模式：$mode" ;;
    esac
    if ((${#names[@]} == 0)); then
        info "没有已安装的 ${mode} 容器；请先选择安装。"
        return 1
    fi

    printf '\n%s\n' "$title" >&2
    for ((index = 0; index < ${#names[@]}; index++)); do
        printf '  %s) %s\n' "$((index + 1))" "${names[index]}" >&2
    done
    printf '  0) 取消\n' >&2
    choice=$(menu_read '请输入容器编号（回车取消）') || return 1
    [[ -n $choice ]] || return 1
    [[ $choice =~ ^[0-9]{1,3}$ ]] || { warn '请输入列表中的数字编号。'; return 1; }
    choice=$((10#$choice))
    ((choice == 0)) && return 1
    ((choice >= 1 && choice <= ${#names[@]})) || { warn '编号超出范围。'; return 1; }
    MENU_SELECTED_NAME=${names[choice - 1]}
}

# A page contains labels and public command actions only. Each page is a loop;
# returning from a leaf unwinds one fixed level, never re-enters a parent.
menu_entries() {
    case "$1:$2" in
        proot:main)
            printf '%s\n' '安装 Ubuntu 24.04|install' '容器运行管理|runtime' '备份、恢复与删除|data' ;;
        chroot:main)
            printf '%s\n' '容器管理|containers' 'systemd 服务管理|systemd' 'Docker 服务管理|docker' '网络与 DNS|network' '诊断与修复|diagnostics' ;;
        chroot:containers)
            printf '%s\n' '安装依赖|prepare' '创建 Ubuntu（按能力初始化）|install' '进入容器|login' '停止容器|stop' '容器状态|status' '数据管理|data' ;;
        chroot:systemd)
            printf '%s\n' '前置检查|systemd-check' '开启 systemd|systemd-start' '停止 systemd|systemd-stop' '重启 systemd|systemd-restart' '状态检查|systemd-status' ;;
        chroot:network)
            printf '%s\n' '检测网络、DNS 与监听端口|network-check' '修复 DNS 与 Docker 默认网络|network-repair' '独立网络状态和私有 IP|network-status' '设置网络模式（须停止容器）|network-mode' '查看局域网端口映射|port-list' '添加局域网端口映射|port-add' '删除局域网端口映射|port-remove' ;;
        proot:runtime)
            printf '%s\n' '进入容器|login' '执行容器命令|exec' '停止活动会话|stop' '更新容器系统|update-system' '查看状态|status' '活动会话|ps' ;;
        chroot:diagnostics)
            printf '%s\n' '深度环境能力检查|capabilities' '检查 systemd|systemd-check' '检查 Docker|docker-check' '初始化或修复|repair' '更新容器系统|update-system' '执行容器命令|exec' '绑定目录|bind' ;;
        proot:data|chroot:data)
            printf '%s\n' '备份|backup' '从备份恢复|restore' '重装（删除系统内数据）|reinstall' '卸载（永久删除系统和数据）|remove' ;;
        chroot:docker)
            printf '%s\n' '前置检查|docker-check' '开启 Docker|docker-start' '停止 Docker|docker-stop' '重启 Docker|docker-restart' '状态检查|docker-status' '安装或修复 Docker|docker-install' '查看日志|docker-logs' ;;
        *) return 1 ;;
    esac
}

menu_mode_label() {
    case "$1" in proot) printf PRoot ;; chroot) printf Chroot ;; *) die "未知菜单模式：$1" ;; esac
}

# Only the selected action goes to stdout. UI goes to stderr so command
# substitution cannot mix a rendered menu with the dispatch key.
menu_pick_entry() {
    local title=$1 choice index entry
    shift
    local -a entries=("$@")
    ((${#entries[@]} > 0)) || die '菜单没有可用选项'
    while true; do
        printf '\n%s\n' "$title" >&2
        for ((index = 0; index < ${#entries[@]}; index++)); do
            entry=${entries[index]}
            printf '  %s) %s\n' "$((index + 1))" "${entry%%|*}" >&2
        done
        printf '  0) 返回上一级（直接回车也可）\n' >&2
        choice=$(menu_read '请选择操作') || return 1
        [[ -n $choice ]] || return 1
        [[ $choice =~ ^[0-9]{1,3}$ ]] || { warn '请输入列表中的数字编号。'; continue; }
        choice=$((10#$choice))
        ((choice != 0)) || return 1
        ((choice <= ${#entries[@]})) || { warn '编号超出范围。'; continue; }
        entry=${entries[choice - 1]}
        printf '%s' "${entry#*|}"
        return 0
    done
}

menu_dispatch_action() {
    local mode=$1 action=$2 name=${3:-} backend label file host guest protocol
    label=$(menu_mode_label "$mode") || return 1
    backend="${mode}_main"
    case "$action" in
        install)
            name=$(menu_read '新容器名称' ubuntu) || return 0
            if [[ $mode == proot ]]; then menu_run "$backend" install ubuntu:24.04 "$name"
            else menu_run "$backend" install ubuntu 24.04 "$name"; fi
            return 0 ;;
        prepare) menu_run "$backend" prepare; return 0 ;;
        restore)
            file=$(menu_read '要恢复的备份文件（留空取消）') || return 0
            [[ -n $file ]] || { info '已取消恢复'; return 0; }
            if [[ $mode == proot ]]; then
                info 'PRoot 恢复名称保存在备份中，不另行指定新名称。'
                menu_run "$backend" restore "$file"
            else
                name=ubuntu-restored
                name=$(menu_read '恢复后的新名称（不会覆盖已有系统）' "$name") || return 0
                menu_run "$backend" restore "$file" "$name"
            fi
            return 0
            ;;
    esac

    if [[ -z $name ]]; then
        if ! menu_select_container "$mode" "选择操作目标（$label：$action）"; then return 0; fi
        name=$MENU_SELECTED_NAME
    fi
    require_name "$name"
    case "$action" in
        capabilities) menu_run chroot_root capabilities "$(chroot_base)" "$name" ;;
        exec)
            file=$(menu_read '容器内命令（留空取消）') || return 0
            [[ -n $file ]] || return 0
            menu_run "$backend" exec "$name" -- /bin/bash -lc "$file"
            ;;
        bind)
            host=$(menu_read '宿主目录（留空取消）') || return 0
            [[ -n $host ]] || return 0
            guest=$(menu_read '容器挂载目录（留空取消）') || return 0
            [[ -n $guest ]] || return 0
            protocol=$(menu_read 'ro/rw' ro) || return 0
            menu_run "$backend" bind "$name" "$host" "$guest" "$protocol"
            ;;
        data) menu_category "$mode" data "数据管理 — $name" "$name" ;;
        backup)
            file=$(menu_read '备份文件' "$PWD/${name}-$(date +%Y%m%d-%H%M%S)-${mode}.tar.gz") || return 0
            menu_run "$backend" backup "$name" "$file"
            ;;
        port-add)
            if [[ $mode == chroot ]]; then
                host=$(menu_read '手机局域网 IPv4:端口（留空取消）') || return 0
                [[ -n $host ]] || return 0
                guest=$(menu_read '容器端口') || return 0
                protocol=$(menu_read '协议 tcp/udp' tcp) || return 0
                menu_run "$backend" port-add "$name" --listen "$host" --to "$guest" --proto "$protocol"
                return 0
            fi
            ;;
        port-remove)
            if [[ $mode == chroot ]]; then
                host=$(menu_read '手机局域网 IPv4:端口（留空取消）') || return 0
                [[ -n $host ]] || return 0
                protocol=$(menu_read '协议 tcp/udp' tcp) || return 0
                menu_run "$backend" port-remove "$name" --listen "$host" --proto "$protocol"
                return 0
            fi
            ;;
        network-mode)
            protocol=$(menu_read '网络模式 auto/isolated/shared' auto) || return 0
            menu_run "$backend" network-mode "$name" "$protocol"
            ;;
        *) menu_run "$backend" "$action" "$name" ;;
    esac
}

menu_category() {
    local mode=$1 group=$2 title=$3 name=${4:-} action catalog
    local -a entries=()
    catalog=$(menu_entries "$mode" "$group") || die "未知菜单分组：$mode/$group"
    mapfile -t entries <<<"$catalog"
    while true; do
        action=$(menu_pick_entry "$title" "${entries[@]}") || return 0
        menu_dispatch_action "$mode" "$action" "$name"
    done
}

menu_backend() {
    local mode=$1 label group title entry
    local -a entries=()
    label=$(menu_mode_label "$mode") || return 1
    mapfile -t entries < <(menu_entries "$mode" main)
    while true; do
        group=$(menu_pick_entry "$label 管理" "${entries[@]}") || return 0
        if [[ $mode == proot && $group == install ]]; then
            menu_dispatch_action proot install
        elif [[ $mode == chroot && $group != containers ]]; then
            title=$group
            for entry in "${entries[@]}"; do
                [[ ${entry#*|} != "$group" ]] || { title=${entry%%|*}; break; }
            done
            if menu_select_container chroot "选择目标容器（$title）"; then
                menu_category chroot "$group" "$title — $MENU_SELECTED_NAME" "$MENU_SELECTED_NAME"
            fi
        else
            title=$group
            for entry in "${entries[@]}"; do
                [[ ${entry#*|} != "$group" ]] || { title=${entry%%|*}; break; }
            done
            menu_category "$mode" "$group" "$label / $title"
        fi
    done
}

menu_proot() { menu_backend proot; }
menu_chroot() { menu_backend chroot; }

menu_proxy() {
    local action address bypass
    local -a entries=(
        '设置并开启代理|set' '开启已保存代理|on' '关闭代理|off'
        '查看代理状态|status' '测试代理连通性|test' '同步到已有 Chroot|apply'
        '清除配置，沿用 Termux 环境|reset'
    )
    while true; do
        action=$(menu_pick_entry '统一代理配置（运行中的 Docker 配置变化时会重启）' "${entries[@]}") || return 0
        case "$action" in
            set)
                address=$(menu_read 'HTTP/混合代理 URL 或本机端口（留空取消）') || return 0
                [[ -n $address ]] || continue
                bypass=$(menu_read '直连域名/IP（逗号分隔）' 'localhost,127.0.0.1,::1') || return 0
                menu_run proxy_main on "$address" --no-proxy "$bypass"
                ;;
            on|off|status|test|apply|reset) menu_run proxy_main "$action" ;;
        esac
    done
}

menu_maintenance() {
    local action
    while true; do
        action=$(menu_pick_entry '程序维护' '环境与能力检查|doctor' '更新程序|update' '查看版本|version' '卸载程序（保留容器）|uninstall') || return 0
        case "$action" in
            doctor) menu_run doctor ;;
            update) menu_run update_main; info '更新操作结束，请退出并重新运行 xtmoe on。'; return 0 ;;
            version) printf 'XTMOE %s\n' "$XTMOE_VERSION" ;;
            uninstall) menu_run uninstall_app_main ;;
        esac
    done
}

on_main() {
    (($# == 0)) || die 'xtmoe on 不接受额外参数'
    require_termux
    [[ -t 0 && -t 1 ]] || die 'xtmoe on 需要交互终端；快捷操作请查看 xtmoe help。'
    local choice
    while true; do
        choice=$(menu_pick_entry "XTMOE ${XTMOE_VERSION:-v1.0.0}" 'PRoot 管理（无需 Root）|proot' 'Chroot 管理（需要 Root）|chroot' '查看并进入系统|list' '代理设置|proxy' '程序维护|maintenance') || return 0
        case "$choice" in
            proot) menu_proot ;;
            chroot) menu_chroot ;;
            list) menu_run list_main ;;
            proxy) menu_proxy ;;
            maintenance) menu_maintenance ;;
        esac
    done
}
