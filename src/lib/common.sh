#!/data/data/com.termux/files/usr/bin/bash

: "${XTMOE_HOME:=${HOME:-}}"
: "${XTMOE_CONFIG_DIR:=$XTMOE_HOME/.config/xtmoe}"
: "${XTMOE_DATA_DIR:=$XTMOE_HOME/.local/share/xtmoe}"
: "${XTMOE_CACHE_DIR:=$XTMOE_HOME/.cache/xtmoe}"

if [[ -t 1 && ${NO_COLOR:-} == '' ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

is_termux() {
    [[ -n ${PREFIX:-} && $PREFIX == */files/usr && -d $PREFIX/bin ]]
}

require_termux() {
    if [[ ${XTMOE_ALLOW_NON_TERMUX:-0} != 1 ]]; then
        is_termux || die '此操作只能在 Android Termux 中运行。'
    fi
    [[ $(id -u) -ne 0 ]] || die '请在 Termux 普通用户会话中运行；不要先执行 su/tsu。'
}

require_command() {
    command_exists "$1" || die "缺少命令：$1${2:+；$2}"
}

valid_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
}

require_name() {
    valid_name "$1" || die '名称只能包含字母、数字、点、下划线和连字符，最长 64 个字符。'
}

require_arg_range() {
    local minimum=$1 maximum=$2 actual=$3 usage=$4
    ((actual >= minimum && actual <= maximum)) || die "参数数量错误。用法：$usage"
}

confirm() {
    local prompt=$1 answer
    [[ ${XTMOE_YES:-0} == 1 ]] && return 0
    [[ -t 0 ]] || die "$prompt；非交互模式请显式添加 --yes。"
    printf '%s [y/N] ' "$prompt" >&2
    read -r answer
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

confirm_default_yes() {
    local prompt=$1 answer
    [[ ${XTMOE_YES:-0} == 1 ]] && return 0
    [[ -t 0 ]] || die "$prompt；非交互模式请使用 --yes 或显式跳过选项。"
    printf '%s [Y/n] ' "$prompt" >&2
    read -r answer
    [[ -z $answer || $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

root_available() {
    if command_exists tsu && tsu -c 'id -u' 2>/dev/null | grep -qx 0; then
        return 0
    fi
    if command_exists su && su -c 'id -u' 2>/dev/null | grep -qx 0; then
        return 0
    fi
    return 1
}

shell_quote_args() {
    local arg result=''
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        result+="${result:+ }$arg"
    done
    printf '%s' "$result"
}

run_root() {
    local command_line
    command_line=$(shell_quote_args "$@")
    if command_exists tsu && tsu -c 'id -u' 2>/dev/null | grep -qx 0; then
        tsu -c "$command_line"
    elif command_exists su && su -c 'id -u' 2>/dev/null | grep -qx 0; then
        su -c "$command_line"
    else
        die 'tsu/su 均未取得 Root，无法执行 Chroot 操作。'
    fi
}

ensure_dirs() {
    mkdir -p "$XTMOE_CONFIG_DIR" "$XTMOE_DATA_DIR" "$XTMOE_CACHE_DIR"
}

# Only proxy variables cross guest boundaries; do not inherit Termux PATH/LD_PRELOAD.
proxy_environment() {
    local lower upper value any=0
    for lower in http_proxy https_proxy all_proxy; do
        upper=${lower^^}; value=${!lower:-${!upper:-}}
        [[ -n $value ]] || continue
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || { warn '代理设置不能包含换行。'; return 1; }
        printf '%s=%s\n%s=%s\n' "$lower" "$value" "$upper" "$value"
        any=1
    done
    if ((any)); then
        value=${no_proxy:-${NO_PROXY:-}}
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || { warn 'NO_PROXY 不能包含换行。'; return 1; }
        value="${value:+$value,}localhost,127.0.0.1,::1"
        printf 'no_proxy=%s\nNO_PROXY=%s\n' "$value" "$value"
    fi
    return 0
}

