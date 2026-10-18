#!/usr/bin/env bash
# Sourced by run.sh. Exercise real menu navigation with recording backends.
assert_ok 'Dual mode menu catalog covers service, network, data and repair functions' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    [[ $(menu_entries chroot main | wc -l) == 5 && $(menu_entries proot main | wc -l) == 3 ]] || exit 1
    for group in containers systemd docker network diagnostics data; do menu_entries chroot "$group" >/dev/null || exit 1; done
    for group in runtime data; do menu_entries proot "$group" >/dev/null || exit 1; done
    menu_entries chroot network | grep -q port-add
    menu_entries chroot diagnostics | grep -q repair
' _ "$ROOT_DIR"

assert_ok 'Menu picker validates numbers and supports zero, blank and EOF cancellation' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    [[ $(printf "bad\n999\n002\n" | menu_pick_entry test "One|one" "Two|two") == two ]] || exit 1
    if menu_pick_entry test "One|one" <<<0; then exit 1; fi
    if menu_pick_entry test "One|one" <<<""; then exit 1; fi
    if menu_pick_entry test "One|one" </dev/null; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Canceled selection clears stale target and does not invoke the backend' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    manager_chroot_names() { printf "alpha\nubuntu\n"; }
    MENU_SELECTED_NAME=old
    if menu_select_container chroot <<<0; then exit 1; fi
    [[ -z $MENU_SELECTED_NAME ]]
' _ "$ROOT_DIR"

assert_ok 'Container data menu stays on the selected target and preserves deletion confirmation' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    log="$2/data-menu"
    chroot_main() { printf "%s\n" "$*" >>"$log"; }
    printf "4\n0\n" | menu_category chroot data test ubuntu
    [[ $(<"$log") == "remove ubuntu" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Port mapping prompts preserve address, protocol and argument boundaries' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    log="$2/port-menu"; chroot_main() { printf "%s\n" "$*" >>"$log"; }
    printf "192.168.0.6:18080\n80\nudp\n" | menu_dispatch_action chroot port-add ubuntu
    [[ $(<"$log") == "port-add ubuntu --listen 192.168.0.6:18080 --to 80 --proto udp" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Port menu accepts automatic mappings and defaults a bare port to auto' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    log="$2/auto-port-menu"; chroot_main() { printf "%s\n" "$*" >>"$log"; }
    printf "18080\n80\ntcp\n" | menu_dispatch_action chroot port-add ubuntu
    printf "auto:18080\ntcp\n" | menu_dispatch_action chroot port-remove ubuntu
    [[ $(head -n 1 "$log") == "port-add ubuntu --listen auto:18080 --to 80 --proto tcp" && $(tail -n 1 "$log") == "port-remove ubuntu --listen auto:18080 --proto tcp" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Maintenance menu confirms force updates and cancellation never calls updater' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    log="$2/force-menu"; update_main() { printf "%s\n" "$*" >>"$log"; }
    confirm() { return 1; }
    printf "5\n0\n" | menu_maintenance
    [[ ! -e $log ]] || exit 1
    confirm() { return 0; }
    printf "5\n" | menu_maintenance
    [[ $(<"$log") == --force ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Menu command execution is explicit and keeps the command as one argument' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    log="$2/exec-menu"; chroot_main() { printf "%s\n" "$@" >"$log"; }
    printf "printf hello\n" | menu_dispatch_action chroot exec ubuntu
    [[ $(tail -n 1 "$log") == "printf hello" ]] && grep -qx -- -- "$log"
' _ "$ROOT_DIR" "$TEST_TMP"
