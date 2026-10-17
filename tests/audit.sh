#!/usr/bin/env bash
# Sourced by run.sh: focused failure-path regressions from lifecycle review.

assert_fail 'QEMU status rejects path traversal and returns failure' bash "$CLI" qemu status ../outside
assert_fail 'PRoot login rejects path traversal' bash "$CLI" proot login ../outside
assert_fail 'PRoot exec rejects path traversal' bash "$CLI" proot exec ../outside -- true

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

assert_ok 'QEMU rejects duplicate keys and unsafe resource config' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    file="$2/config"
    qemu_write_config audit-config amd64 2 2048 20 2399 stopped
    cp "$(qemu_config_file audit-config)" "$file"
    printf "cpus=8\n" >>"$file"
    if qemu_validate_config_file "$file"; then exit 1; fi
    printf "arch=amd64\ncpus=-object\nmemory=2048\ndisk_size=20\nssh_port=2399\nstate=stopped\n" >"$file"
    if qemu_validate_config_file "$file"; then exit 1; fi
    rm -f -- "$(qemu_config_file audit-config)"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU rejects duplicate ports and QEMU netdev injection' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    file="$2/ports"
    printf "tcp|8080|80\ntcp|8080|81\n" >"$file"
    if qemu_validate_ports_file "$file" 2222; then exit 1; fi
    printf "tcp|8080|80,hostfwd=tcp::9999-:22\n" >"$file"
    if qemu_validate_ports_file "$file" 2222; then exit 1; fi
    printf "udp|5353|53\ntcp|8080|80\n" >"$file"
    qemu_validate_ports_file "$file" 2222
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU Docker test propagates failure and saves partial status' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    qemu_probe() { [[ $* != *hello-world* ]]; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$2.audit"; }
    cd "$2"
    if qemu_verify_docker audit; then exit 1; fi
    grep -qx docker_state=container-unverified docker_state.audit
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Direct Docker package failure never starts a daemon' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_exec() { return 1; }
    chroot_systemd_stop() { printf forbidden >"$2"; }
    chroot_docker_direct_start() { printf forbidden >"$2"; }
    if chroot_docker_direct_install --accept-host-network-changes docker-gate; then exit 1; fi
    [[ $(chroot_meta_get docker-gate docker_state) == install-failed ]]
' _ "$ROOT_DIR" "$TEST_TMP/direct-must-not-start"

assert_ok 'QEMU archive preflight rejects arbitrary files before extraction' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    dir="$2/archive-fixture"
    mkdir -p "$dir/audit-vm"
    printf "xtmoe-qemu-format-1\n" >"$dir/audit-vm/.xtmoe-qemu"
    printf evil >"$dir/unexpected-file"
    tar -czf "$2/bad-qemu.tar.gz" -C "$dir" audit-vm/.xtmoe-qemu unexpected-file
    if ( qemu_archive_name "$2/bad-qemu.tar.gz" ); then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU failed image preflight preserves original VM during reinstall' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    qemu_vm_exists() { return 0; }
    qemu_status_value() { printf stopped; }
    qemu_config_get() { case "$2" in cpus) printf 2;; memory) printf 2048;; disk_size) printf 20;; ssh_port) printf 2399;; arch) printf amd64;; esac; }
    qemu_require() { :; }
    qemu_download_image() { return 1; }
    dir="$(qemu_vm_dir audit-original)"
    mkdir -p "$dir"
    printf original >"$dir/disk.qcow2"
    set +e
    ( set -e; qemu_reinstall --yes audit-original )
    status=$?
    set -e
    [[ $status != 0 && $(<"$dir/disk.qcow2") == original ]]
' _ "$ROOT_DIR"
