#!/usr/bin/env bash
# Sourced by run.sh: focused failure-path regressions from lifecycle review.

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
