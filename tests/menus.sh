#!/usr/bin/env bash
# Sourced by run.sh. Menu simulations dispatch only to recording backends.

assert_ok 'Grouped menu first pages stay small and every original action remains reachable' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    [[ $(menu_entries chroot main | wc -l) == 5 && $(menu_entries qemu main | wc -l) == 5 && $(menu_entries proot main | wc -l) == 3 ]] || exit 1
    for mode in proot chroot qemu; do
        case "$mode" in
            proot) groups="runtime data"; expected="backup install login reinstall remove restore status stop update-system"; actions=install;;
            chroot) groups="install runtime data diagnostics docker-systemd docker-direct"; expected="backup cgroup-check docker-check docker-direct-install docker-direct-logs docker-direct-run-test docker-direct-start docker-direct-status docker-direct-stop docker-install docker-logs docker-restart docker-start docker-status docker-stop init install login network-check prepare reinstall remove repair restore status stop systemd-check systemd-start systemd-status update-system"; actions=docker-check;;
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

assert_ok 'Chroot grouped navigation retains numbered selection and direct daemon separation' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/chroot-navigation"
    manager_chroot_names() { printf "alpha\nubuntu\n"; }
    chroot_main() { printf "%s\n" "$*" >>"$MENU_TEST_LOG"; }
    # Docker -> ubuntu -> systemd -> status -> back -> direct -> status -> back -> capability -> back -> root exit.
    printf "5\n2\n1\n5\n0\n2\n4\n0\n3\n0\n0\n" | menu_chroot
    [[ $(wc -l <"$MENU_TEST_LOG") == 3 ]] && grep -qx "docker-status ubuntu" "$MENU_TEST_LOG" && grep -qx "docker-direct-status ubuntu" "$MENU_TEST_LOG" && grep -qx "docker-check ubuntu" "$MENU_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot grouped runtime and diagnostics return to the parent without dispatch on back' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/chroot-runtime"
    manager_chroot_names() { printf "alpha\nubuntu\n"; }
    chroot_main() { printf "%s\n" "$*" >>"$MENU_TEST_LOG"; }
    printf "2\n5\n2\n0\n4\n1\n1\n0\n0\n" | menu_chroot
    [[ $(wc -l <"$MENU_TEST_LOG") == 2 ]] && grep -qx "status ubuntu" "$MENU_TEST_LOG" && grep -qx "network-check alpha" "$MENU_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Grouped menus preserve destructive confirmations by never adding --yes' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    MENU_TEST_LOG="$2/menu-destructive"
    manager_proot_names() { printf "ubuntu\n"; }; manager_chroot_names() { printf "ubuntu\n"; }; manager_qemu_names() { printf "ubuntu\n"; }
    proot_main() { printf "proot:%s\n" "$*" >>"$MENU_TEST_LOG"; }
    chroot_main() { printf "chroot:%s\n" "$*" >>"$MENU_TEST_LOG"; }
    qemu_main() { printf "qemu:%s\n" "$*" >>"$MENU_TEST_LOG"; }
    for mode in proot chroot qemu; do
        printf "3\n1\n4\n1\n0\n" | menu_category "$mode" data "data"
    done
    [[ $(wc -l <"$MENU_TEST_LOG") == 6 ]] && ! grep -q -- --yes "$MENU_TEST_LOG" && [[ $(grep -c "reinstall ubuntu" "$MENU_TEST_LOG") == 3 && $(grep -c "remove ubuntu" "$MENU_TEST_LOG") == 3 ]]
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
    { for ((i=0; i<12; i++)); do printf "1\n0\n2\n0\n3\n0\n4\n0\n5\n1\n1\n0\n0\n"; done; printf "0\n"; } | menu_chroot >/dev/null 2>&1
    menu_chroot </dev/null >/dev/null 2>&1
    menu_proot </dev/null >/dev/null 2>&1
    menu_qemu </dev/null >/dev/null 2>&1
    [[ $(sort -nr "$MENU_DEPTH_LOG" | head -n 1) -lt 15 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_fail 'Unknown grouped menu mode fails rather than dispatching an arbitrary backend' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    menu_backend arbitrary
' _ "$ROOT_DIR"
