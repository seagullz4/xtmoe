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
    require_command proot-distro '执行 pkg install proot-distro'
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
    [[ $choice =~ ^[0-9]+$ ]] || die '请输入列表中的数字编号。'
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
    IFS= read -r value
    printf '%s' "${value:-$default}"
}

menu_run() {
    if ! ( "$@" ); then
        warn '操作未完成；请根据上方错误修复后重试。'
    fi
}

menu_select_container() {
    local mode=$1 title=${2:-请选择容器} choice index
    local -a names=()
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
    choice=$(menu_read '请输入容器编号')
    [[ $choice =~ ^[0-9]+$ ]] || { warn '请输入列表中的数字编号。'; return 1; }
    ((choice == 0)) && return 1
    ((choice >= 1 && choice <= ${#names[@]})) || { warn '编号超出范围。'; return 1; }
    MENU_SELECTED_NAME=${names[choice - 1]}
}

menu_proot() {
    local choice name file
    while true; do
        cat <<'EOF'

PRoot 管理
  1) 安装 Ubuntu 24.04
  2) 进入容器
  3) 停止活动会话
  4) 更新容器系统
  5) 重装容器
  6) 备份
  7) 恢复
  8) 卸载
  9) 查看状态
  0) 返回
EOF
        choice=$(menu_read '请选择操作')
        case "$choice" in
            1) name=$(menu_read '容器名称' ubuntu); menu_run proot_main install ubuntu:24.04 "$name" ;;
            2) menu_select_container proot '选择要进入的 PRoot 容器' && menu_run proot_main login "$MENU_SELECTED_NAME" ;;
            3) menu_select_container proot '选择要停止的 PRoot 容器' && menu_run proot_main stop "$MENU_SELECTED_NAME" ;;
            4) menu_select_container proot '选择要更新的 PRoot 容器' && menu_run proot_main update-system "$MENU_SELECTED_NAME" ;;
            5) menu_select_container proot '选择要重装的 PRoot 容器' && menu_run proot_main reinstall "$MENU_SELECTED_NAME" ;;
            6)
                if menu_select_container proot '选择要备份的 PRoot 容器'; then
                    file=$(menu_read '备份文件' "$PWD/${MENU_SELECTED_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz")
                    menu_run proot_main backup "$MENU_SELECTED_NAME" "$file"
                fi
                ;;
            7) file=$(menu_read '备份文件'); menu_run proot_main restore "$file" ;;
            8) menu_select_container proot '选择要卸载的 PRoot 容器' && menu_run proot_main remove "$MENU_SELECTED_NAME" ;;
            9) menu_select_container proot '选择要查看的 PRoot 容器' && menu_run proot_main status "$MENU_SELECTED_NAME" ;;
            0|'') return 0 ;;
            *) warn '无效选项。' ;;
        esac
    done
}

menu_chroot_docker() {
    local name=${1:?缺少 Chroot 容器名称} choice
    while true; do
        cat <<'EOF'

Docker 管理
  1) 严格能力检查
  2) 安装 Docker Engine（systemd 严格模式）
  3) systemd 模式启动
  4) systemd 模式停止
  5) systemd 模式重启
  6) systemd 模式状态
  7) systemd 模式日志
  8) 安装并启动 Docker（direct dockerd 兼容模式）
  9) direct dockerd 启动
 10) direct dockerd 停止
 11) direct dockerd 状态（docker info）
 12) direct dockerd 日志
 13) direct 运行 hello-world 验证容器
  0) 返回
EOF
        choice=$(menu_read '请选择操作')
        case "$choice" in
            1) menu_run chroot_main docker-check "$name" ;;
            2) menu_run chroot_main docker-install "$name" ;;
            3) menu_run chroot_main docker-start "$name" ;;
            4) menu_run chroot_main docker-stop "$name" ;;
            5) menu_run chroot_main docker-restart "$name" ;;
            6) menu_run chroot_main docker-status "$name" ;;
            7) menu_run chroot_main docker-logs "$name" ;;
            8) menu_run chroot_main docker-direct-install "$name" ;;
            9) menu_run chroot_main docker-direct-start "$name" ;;
            10) menu_run chroot_main docker-direct-stop "$name" ;;
            11) menu_run chroot_main docker-direct-status "$name" ;;
            12) menu_run chroot_main docker-direct-logs "$name" ;;
            13) menu_run chroot_main docker-direct-run-test "$name" ;;
            0|'') return 0 ;;
            *) warn '无效选项。' ;;
        esac
    done
}

menu_chroot() {
    local choice name file
    while true; do
        cat <<'EOF'

Chroot 管理
  1) 准备依赖
  2) 全新安装 Ubuntu 24.04
  3) 启动 systemd
  4) 进入容器
  5) 停止容器
  6) 修复/继续初始化
  7) 更新容器系统
  8) 重装容器
  9) 备份
 10) 恢复
 11) 卸载
 12) 网络诊断
 13) cgroup 检查
 14) Docker 管理
 15) 查看状态
  0) 返回
EOF
        choice=$(menu_read '请选择操作')
        case "$choice" in
            1) menu_run chroot_main prepare ;;
            2) name=$(menu_read '容器名称' ubuntu); menu_run chroot_main install ubuntu 24.04 "$name" ;;
            3) menu_select_container chroot '选择要启动 systemd 的 Chroot 容器' && menu_run chroot_main systemd-start "$MENU_SELECTED_NAME" ;;
            4) menu_select_container chroot '选择要进入的 Chroot 容器' && menu_run chroot_main login "$MENU_SELECTED_NAME" ;;
            5) menu_select_container chroot '选择要停止的 Chroot 容器' && menu_run chroot_main stop "$MENU_SELECTED_NAME" ;;
            6) menu_select_container chroot '选择要修复的 Chroot 容器' && menu_run chroot_main repair "$MENU_SELECTED_NAME" ;;
            7) menu_select_container chroot '选择要更新的 Chroot 容器' && menu_run chroot_main update-system "$MENU_SELECTED_NAME" ;;
            8) menu_select_container chroot '选择要重装的 Chroot 容器' && menu_run chroot_main reinstall "$MENU_SELECTED_NAME" ;;
            9)
                if menu_select_container chroot '选择要备份的 Chroot 容器'; then
                    file=$(menu_read '备份文件' "$PWD/${MENU_SELECTED_NAME}-$(date +%Y%m%d-%H%M%S)-chroot.tar.gz")
                    menu_run chroot_main backup "$MENU_SELECTED_NAME" "$file"
                fi
                ;;
            10)
                file=$(menu_read '备份文件')
                name=$(menu_read '恢复后的容器名称' ubuntu-restored)
                menu_run chroot_main restore "$file" "$name"
                ;;
            11) menu_select_container chroot '选择要卸载的 Chroot 容器' && menu_run chroot_main remove "$MENU_SELECTED_NAME" ;;
            12) menu_select_container chroot '选择要诊断网络的 Chroot 容器' && menu_run chroot_main network-check "$MENU_SELECTED_NAME" ;;
            13) menu_select_container chroot '选择要检查 cgroup 的 Chroot 容器' && menu_run chroot_main cgroup-check "$MENU_SELECTED_NAME" ;;
            14) menu_select_container chroot '选择要管理 Docker 的 Chroot 容器' && menu_chroot_docker "$MENU_SELECTED_NAME" ;;
            15) menu_select_container chroot '选择要查看状态的 Chroot 容器' && menu_run chroot_main status "$MENU_SELECTED_NAME" ;;
            0|'') return 0 ;;
            *) warn '无效选项。' ;;
        esac
    done
}

on_main() {
    (($# == 0)) || die 'xtmoe on 不接受额外参数'
    require_termux
    [[ -t 0 && -t 1 ]] || die 'xtmoe on 是交互向导；自动化请使用对应的直接子命令。'
    local choice
    while true; do
        cat <<'EOF'

XTMOE 管理向导
  1) PRoot（无需 Root）
  2) Chroot（需要 Root）
  3) 查看并进入正在运行的系统
  4) 更新 XTMOE
  0) 退出
EOF
        choice=$(menu_read '请选择模式')
        case "$choice" in
            1) menu_proot ;;
            2) menu_chroot ;;
            3) menu_run list_main ;;
            4)
                menu_run update_main
                info 'XTMOE 已更新；请重新运行 xtmoe on 载入新版本。'
                return 0
                ;;
            0|'') return 0 ;;
            *) warn '无效选项。' ;;
        esac
    done
}
