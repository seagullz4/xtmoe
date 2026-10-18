#!/usr/bin/env bash
# Sourced by run.sh: focused failure-path regressions from lifecycle review.

assert_ok 'PRoot architecture detection failure blocks installation before upstream calls' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    log="$2/proot-unknown-arch"
    dpkg() { return 37; }
    proot-distro() { printf "%s\n" "$*" >>"$log"; printf "%s\n" "--name --architecture"; }
    timeout() { printf forbidden >>"$log"; }
    if proot_install ubuntu:24.04 invalid-arch; then exit 1; fi
    [[ ! -e $log ]]
' _ "$ROOT_DIR" "$TEST_TMP"

for proot_action in backup reinstall; do
    assert_ok "PRoot $proot_action preserves upstream failure without reporting success" bash -c '
        set -Eeuo pipefail
        source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
        log="$2/proot-failure-$3"; action=$3
        confirm() { return 0; }; proot_exists() { return 0; }
        proot-distro() { if [[ $1 == help ]]; then printf reset; else return 41; fi; }
        result=0
        if "proot_$action" existing >"$log" 2>&1; then exit 1; else result=$?; fi
        [[ $result == 41 ]] || exit 1
        if grep -F "[OK]" "$log"; then exit 1; fi
    ' _ "$ROOT_DIR" "$TEST_TMP" "$proot_action"
done

assert_ok 'Wizard operation aborts after failure while menu remains usable' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"
    source "$1/src/lib/manager.sh"
    operation() { false; printf forbidden >"$2"; }
    menu_run operation _ "$2"
    [[ ! -e $2 ]]
' _ "$ROOT_DIR" "$TEST_TMP/menu-must-not-write"

assert_ok 'Wizard cancel preserves menu and does not dispatch an operation' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"
    source "$1/src/lib/manager.sh"
    manager_proot_names() { printf "alpha\nubuntu\n"; }
    menu_select_container proot <<<"0" && exit 7
    printf "menu-alive\n"
' _ "$ROOT_DIR"

assert_ok 'Direct Docker package failure never starts a daemon' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_docker_dependencies() { :; }
    chroot_docker_compat_prepare() { :; }
    chroot_exec() { return 1; }
    chroot_systemd_stop() { printf forbidden >"$2"; }
    chroot_docker_direct_start() { printf forbidden >"$2"; }
    if chroot_docker_direct_install --accept-host-network-changes docker-gate; then exit 1; fi
    [[ $(chroot_meta_get docker-gate docker_state) == install-failed ]]
' _ "$ROOT_DIR" "$TEST_TMP/direct-must-not-start"
