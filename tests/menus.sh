#!/usr/bin/env bash
# Sourced by run.sh. Menu simulations dispatch only to recording backends.

assert_ok 'Chroot exposes four task groups and requested actions while other modes retain their menus' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    [[ $(menu_entries chroot main | wc -l) == 4 && $(menu_entries qemu main | wc -l) == 5 && $(menu_entries proot main | wc -l) == 3 ]] || exit 1
    for mode in proot chroot qemu; do
        case "$mode" in
            proot) groups="runtime data"; expected="backup install login reinstall remove restore status stop update-system"; actions=install;;
            chroot) groups="containers systemd docker network"; expected="backup docker-check docker-install docker-logs docker-restart docker-start docker-status docker-stop install login network-check network-repair prepare remove restore status systemd-check systemd-restart systemd-start systemd-status systemd-stop"; actions="";;
            qemu) groups="install runtime data ports docker"; expected="backup console docker-status docker-test install port-add port-remove ports prepare reinstall remove restore ssh start status stop update-system wait-ready"; actions="";;
        esac
        for group in $groups; do
            catalog=$(menu_entries "$mode" "$group") || exit 1
            [[ $(wc -l <<<"$catalog") -le 7 ]] || exit 1
            actions+="\n$(cut -d "|" -f 2 <<<"$catalog")"
        done
        actual=$(printf "%b\n" "$actions" | sed "/^$/d" | sort -u | tr "\n" " ")
        [[ $actual == "$expected " ]] || { printf "mode=%s actual=%s\n" "$mode" "$actual"; exit 1; }
    done
' _ "$ROOT_DIR"

assert_ok 'Menu picker rejects invalid input and handles leading zero without arithmetic injection' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    selected=$(printf "bad\n999\n002\n" | menu_pick_entry test "First|one" "Second|two")
    [[ $selected == two ]]
' _ "$ROOT_DIR"

assert_ok 'Menu picker cancels on zero, blank and end of input' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    if menu_pick_entry test "First|one" <<<0; then exit 1; fi
    if menu_pick_entry test "First|one" <<<""; then exit 1; fi
    if menu_pick_entry test "First|one" </dev/null; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Canceled container selection clears a previous target' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    manager_chroot_names() { printf "alpha\nubuntu\n"; }
    MENU_SELECTED_NAME=stale
    if menu_select_container chroot <<<0; then exit 1; fi
    [[ -z $MENU_SELECTED_NAME ]] || exit 1
    if menu_select_container chroot </dev/null; then exit 1; fi
    [[ -z $MENU_SELECTED_NAME ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot Docker actions keep a single numbered target without an extra mode submenu' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/chroot-navigation"
    manager_chroot_names() { printf "alpha\nubuntu\n"; }
    chroot_main() { printf "%s\n" "$*" >>"$MENU_TEST_LOG"; }
    printf "3\n2\n5\n1\n3\n0\n0\n" | menu_chroot
    [[ $(wc -l <"$MENU_TEST_LOG") == 3 ]] && grep -qx "docker-status ubuntu" "$MENU_TEST_LOG" && grep -qx "docker-stop ubuntu" "$MENU_TEST_LOG" && grep -qx "docker-check ubuntu" "$MENU_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot systemd restart and network repair dispatch to their selected targets' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/chroot-runtime"
    manager_chroot_names() { printf "alpha\nubuntu\n"; }
    chroot_main() { printf "%s\n" "$*" >>"$MENU_TEST_LOG"; }
    printf "2\n2\n5\n4\n0\n4\n1\n1\n2\n0\n0\n" | menu_chroot
    [[ $(wc -l <"$MENU_TEST_LOG") == 4 ]] && grep -qx "systemd-status ubuntu" "$MENU_TEST_LOG" && grep -qx "systemd-restart ubuntu" "$MENU_TEST_LOG" && grep -qx "network-check alpha" "$MENU_TEST_LOG" && grep -qx "network-repair alpha" "$MENU_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Grouped menus preserve destructive confirmations by never adding --yes' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/menu-destructive"
    manager_proot_names() { printf "ubuntu\n"; }; manager_chroot_names() { printf "ubuntu\n"; }; manager_qemu_names() { printf "ubuntu\n"; }
    proot_main() { printf "proot:%s\n" "$*" >>"$MENU_TEST_LOG"; }
    chroot_main() { printf "chroot:%s\n" "$*" >>"$MENU_TEST_LOG"; }
    qemu_main() { printf "qemu:%s\n" "$*" >>"$MENU_TEST_LOG"; }
    for mode in proot qemu; do
        printf "3\n1\n4\n1\n0\n" | menu_category "$mode" data "data"
    done
    printf "4\n1\n0\n" | menu_category chroot containers "containers"
    [[ $(wc -l <"$MENU_TEST_LOG") == 5 ]] && ! grep -q -- --yes "$MENU_TEST_LOG" && [[ $(grep -c "reinstall ubuntu" "$MENU_TEST_LOG") == 2 && $(grep -c "remove ubuntu" "$MENU_TEST_LOG") == 3 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Grouped restore does not demand an existing container and respects PRoot archive naming' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/menu-restore"
    menu_select_container() { exit 9; }
    proot_main() { [[ $# == 2 && $1 == restore && $2 == "/tmp/archive with spaces.tar.gz" ]] || exit 9; printf "proot-ok\n" >>"$MENU_TEST_LOG"; }
    chroot_main() { [[ $# == 3 && $3 == restored ]] || exit 9; printf "chroot-ok\n" >>"$MENU_TEST_LOG"; }
    qemu_main() { [[ $# == 3 && $3 == restored ]] || exit 9; printf "qemu-ok\n" >>"$MENU_TEST_LOG"; }
    printf "/tmp/archive with spaces.tar.gz\n" | menu_dispatch_action proot restore
    printf "/tmp/archive.tar.gz\nrestored\n" | menu_dispatch_action chroot restore
    printf "/tmp/archive.tar.gz\nrestored\n" | menu_dispatch_action qemu restore
    [[ $(wc -l <"$MENU_TEST_LOG") == 3 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Menu input cancellation prevents install and incomplete port dispatch' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    proot_main() { exit 9; }; qemu_main() { exit 9; }; chroot_main() { exit 9; }
    menu_dispatch_action proot install </dev/null
    menu_dispatch_action chroot restore <<<""
    menu_dispatch_action qemu port-add ubuntu <<<"8080"
    menu_dispatch_action qemu port-remove ubuntu <<<""
' _ "$ROOT_DIR"

assert_ok 'QEMU grouped port forwarding preserves argument boundaries' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/menu-ports"
    manager_qemu_names() { printf "ubuntu\n"; }
    qemu_main() {
        case "$1" in port-add) [[ $# == 5 && $2 == ubuntu && $3 == 28080 && $4 == 80 && $5 == tcp ]];; port-remove) [[ $# == 4 && $4 == udp ]];; *) exit 9;; esac || exit 9
        printf "%s\n" "$1" >>"$MENU_TEST_LOG"
    }
    printf "4\n2\n1\n28080\n80\ntcp\n3\n1\n25353\nudp\n0\n0\n" | menu_qemu
    [[ $(wc -l <"$MENU_TEST_LOG") == 2 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Grouped menus tolerate repeated back navigation and EOF without growing the menu stack' timeout 30 bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    manager_chroot_names() { printf "ubuntu\n"; }
    chroot_main() { exit 9; }
    MENU_DEPTH_LOG="$2/menu-depth"
    menu_read() { local answer; printf "%s\n" "${#FUNCNAME[@]}" >>"$MENU_DEPTH_LOG"; IFS= read -r answer || return 1; printf "%s" "$answer"; }
    { for ((i=0; i<12; i++)); do printf "1\n0\n2\n1\n0\n3\n1\n0\n4\n1\n0\n"; done; printf "0\n"; } | menu_chroot >/dev/null 2>&1
    menu_chroot </dev/null >/dev/null 2>&1
    menu_proot </dev/null >/dev/null 2>&1
    menu_qemu </dev/null >/dev/null 2>&1
    [[ $(sort -nr "$MENU_DEPTH_LOG" | head -n 1) -lt 15 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_fail 'Unknown grouped menu mode fails rather than dispatching an arbitrary backend' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    menu_backend arbitrary
' _ "$ROOT_DIR"

assert_ok 'Proxy menu preserves address boundaries, cancels empty input and dispatches public commands' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_PROXY_LOG="$2/proxy-menu"
    proxy_main() { printf "%s\n" "$*" >>"$MENU_PROXY_LOG"; }
    printf "1\n\n1\nhttp://127.0.0.1:10808\ninternal.example\n2\n3\n4\n5\n6\n7\n0\n" | menu_proxy
    [[ $(wc -l <"$MENU_PROXY_LOG") == 7 ]] && grep -qx "on http://127.0.0.1:10808 --no-proxy internal.example" "$MENU_PROXY_LOG" && grep -qx reset "$MENU_PROXY_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Wizard actions reload saved proxy each time while reset keeps the original Termux environment' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"; source "$1/src/lib/manager.sh"
    XTMOE_CONFIG_DIR="$2/menu-proxy-live"; export http_proxy=http://original.example:3128
    proxy_sync_chroots() { :; }
    check_proxy() { [[ ${http_proxy:-unset} == "$1" ]] || exit 1; }
    menu_run proxy_main on 10808
    menu_run check_proxy http://127.0.0.1:10808
    menu_run proxy_main off
    menu_run check_proxy unset
    menu_run proxy_main reset
    menu_run check_proxy http://original.example:3128
    [[ $http_proxy == http://original.example:3128 ]]
' _ "$ROOT_DIR" "$TEST_TMP"
