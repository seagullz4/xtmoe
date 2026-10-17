#!/usr/bin/env bash
# Sourced by run.sh: focused failure-path regressions from lifecycle review.

assert_ok 'QEMU daemonize success without a live VM is rejected' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/launch"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"
    qemu_require() { :; }; qemu_vm_exists() { return 0; }
    qemu_arch() { printf amd64; }
    qemu_config_get() { case "$2" in arch) printf amd64;; ssh_port) printf 2399;; esac; }
    qemu_ports_file() { printf /dev/null; }; qemu_port_in_use() { return 1; }
    qemu_pid_valid() { return 1; }; qemu_start_with_accel() { return 0; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$dir/config-changes"; }
    sleep() { :; }
    if (qemu_start audit); then exit 1; fi
    ! grep -qx state=running "$dir/config-changes" 2>/dev/null
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU stop refuses an uninspectable live PID without deleting tracking files' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/stop"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"
    printf "%s\n" "$$" >"$dir/qemu.pid"
    printf keep >"$dir/serial.sock"; printf keep >"$dir/monitor.sock"
    qemu_vm_exists() { return 0; }; qemu_pid_valid() { return 1; }
    qemu_pid_inspect() { QEMU_PID_REASON=unreadable-cmdline; return 1; }
    if (qemu_stop audit); then exit 1; fi
    [[ -f $dir/qemu.pid && -f $dir/serial.sock && -f $dir/monitor.sock ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU PID identity accepts no trailing newline and reordered drive fields' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/identity"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"
    printf 2345 >"$dir/qemu.pid"
    qemu_config_get() { printf amd64; }; qemu_process_alive() { return 0; }
    qemu_process_cmdline() { printf "%s\0" /usr/bin/qemu-system-x86_64 -drive "if=virtio,file=$dir/disk.qcow2,format=qcow2"; }
    qemu_pid_valid audit
    [[ $QEMU_PID_VALUE == 2345 && $QEMU_PID_REASON == running ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU PID inspection rejects reused PID, wrong disk and partial procfs reads' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/identity-bad"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"; printf "2345\n" >"$dir/qemu.pid"
    qemu_config_get() { printf amd64; }; qemu_process_alive() { return 0; }
    qemu_process_cmdline() { printf "%s\0" sleep -drive "file=$dir/disk.qcow2"; }
    if qemu_pid_valid audit; then exit 1; fi
    [[ $QEMU_PID_REASON == executable-mismatch ]] || exit 1
    qemu_process_cmdline() { printf "%s\0" qemu-system-x86_64 -drive "file=$dir/disk.qcow2.evil"; }
    if qemu_pid_valid audit; then exit 1; fi
    [[ $QEMU_PID_REASON == disk-mismatch ]] || exit 1
    qemu_process_cmdline() { printf "%s\0" qemu-system-x86_64 -drive "file=$dir/disk.qcow2"; return 1; }
    if qemu_pid_valid audit; then exit 1; fi
    [[ $QEMU_PID_REASON == unreadable-cmdline ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU distinguishes a dead PID from denied process access and protects cleanup' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/identity-state"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"; printf "2345\n" >"$dir/qemu.pid"
    qemu_vm_exists() { return 0; }; qemu_process_alive() { return 1; }
    qemu_process_exists() { return 1; }
    [[ $(qemu_status_value audit) == stale-pid ]] || exit 1
    qemu_tracking_safe_to_clear audit || exit 1
    qemu_process_exists() { return 0; }
    [[ $(qemu_status_value audit) == unverified-pid ]] || exit 1
    if qemu_tracking_safe_to_clear audit; then exit 1; fi
    [[ $QEMU_PID_REASON == permission-denied ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU refuses to start over an unverified live PID and preserves socket files' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/refuse-start"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"; printf keep >"$dir/serial.sock"
    qemu_require() { :; }; qemu_vm_exists() { return 0; }; qemu_arch() { printf amd64; }
    qemu_config_get() { printf amd64; }; qemu_pid_valid() { return 1; }
    qemu_pid_inspect() { QEMU_PID_REASON=unreadable-cmdline; return 1; }
    qemu_start_with_accel() { printf forbidden >"$dir/started"; }
    if (qemu_start audit); then exit 1; fi
    [[ -f $dir/serial.sock && ! -e $dir/started ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU readiness distinguishes SSH boot wait from cloud-init and probes once per tick' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/readiness"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"; printf 0 >"$dir/ticks"; printf 0 >"$dir/probes"
    qemu_vm_exists() { return 0; }; qemu_pid_valid() { return 0; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$dir/changes"; }
    date() { cat "$dir/ticks"; }
    sleep() { printf "%s" "$(( $(<"$dir/ticks") + $1 ))" >"$dir/ticks"; }
    qemu_probe() {
        if [[ $3 == systemctl ]]; then printf running; return 0; fi
        count=$(( $(<"$dir/probes") + 1 )); printf "%s" "$count" >"$dir/probes"
        case "$count" in 1) printf "Connection refused\n" >&2; return 255;; 2) printf cloud-init-running;; 3) printf done;; *) return 1;; esac
    }
    qemu_verify_docker() { qemu_config_set "$1" docker_state ready; }
    qemu_wait_ready --timeout 60 audit >"$dir/output"
    [[ $(<"$dir/probes") == 3 ]] && grep -q "等待 SSH" "$dir/output" && grep -q "SSH 已连通" "$dir/output" && grep -qx docker_state=ready "$dir/changes"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU readiness aborts authentication failure without sleeping for thirty minutes' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/auth-fail"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"
    qemu_vm_exists() { return 0; }; qemu_pid_valid() { return 0; }
    qemu_pid_inspect() { QEMU_PID_REASON=running; return 0; }
    qemu_boot_phase() { printf "Permission denied (publickey).\n" >&2; return 255; }
    sleep() { printf forbidden >"$dir/slept"; }
    if (qemu_wait_ready --timeout 10 audit); then exit 1; fi
    [[ ! -e $dir/slept ]] && grep -q "Permission denied" "$dir/readiness.log"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU readiness stops immediately and shows startup stderr when its PID dies' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/dead-wait"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"; printf "fixture fatal error\n" >"$dir/startup.log"; printf 0 >"$dir/checks"
    audit_fixture_dir=$dir
    qemu_vm_exists() { return 0; }
    qemu_pid_valid() { count=$(( $(<"$audit_fixture_dir/checks") + 1 )); printf "%s" "$count" >"$audit_fixture_dir/checks"; ((count == 1)); }
    qemu_pid_inspect() { QEMU_PID_REASON=dead; return 1; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$dir/changes"; }
    qemu_boot_phase() { printf forbidden >"$dir/probed"; }
    if (qemu_wait_ready --timeout 10 audit) 2>"$dir/output"; then exit 1; fi
    [[ ! -e $dir/probed ]] && grep -q "fixture fatal error" "$dir/output" && grep -qx state=failed "$dir/changes"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU readiness timeout is bounded and preserves the VM with diagnostics' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/timeout-wait"
    dir="$(qemu_vm_dir audit)"; mkdir -p "$dir"; printf 0 >"$dir/ticks"; printf keep >"$dir/disk.qcow2"
    qemu_vm_exists() { return 0; }; qemu_pid_valid() { return 0; }
    qemu_pid_inspect() { QEMU_PID_REASON=running; return 0; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$dir/changes"; }
    date() { cat "$dir/ticks"; }; sleep() { printf 10 >"$dir/ticks"; }
    qemu_boot_phase() { printf "Connection refused\n" >&2; return 255; }
    if (qemu_wait_ready --timeout 10 audit) 2>"$dir/output"; then exit 1; fi
    [[ $(<"$dir/disk.qcow2") == keep ]] && grep -qx init_state=initializing "$dir/changes" && grep -q "Connection refused" "$dir/output"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'QEMU graceful stop is idempotent and clears tracking only after exit' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/graceful-stop"
    audit_stop_dir="$(qemu_vm_dir audit)"; mkdir -p "$audit_stop_dir"
    printf 2345 >"$audit_stop_dir/qemu.pid"; touch "$audit_stop_dir/alive" "$audit_stop_dir/serial.sock" "$audit_stop_dir/monitor.sock"
    qemu_vm_exists() { return 0; }
    qemu_pid_inspect() {
        QEMU_PID_VALUE=2345; QEMU_PID_REASON=dead
        [[ -f $audit_stop_dir/alive ]] || return 1
        QEMU_PID_REASON=running
    }
    qemu_ssh_base_args() { QEMU_SSH_ARGS=(); }
    timeout() { printf poweroff >>"$audit_stop_dir/commands"; rm -f "$audit_stop_dir/alive"; }
    kill() { printf forbidden >>"$audit_stop_dir/signals"; return 1; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$audit_stop_dir/changes"; }
    qemu_stop audit && qemu_stop audit || exit 1
    [[ ! -e $audit_stop_dir/qemu.pid && ! -e $audit_stop_dir/serial.sock && ! -e $audit_stop_dir/monitor.sock && ! -e $audit_stop_dir/signals ]] && grep -qx state=stopped "$audit_stop_dir/changes"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Unified running list excludes unverified QEMU PIDs but all includes them' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/manager.sh"
    manager_proot_sessions() { :; }; manager_proot_names() { :; }; manager_chroot_names() { :; }
    manager_qemu_names() { printf "live\nunknown\ndead\n"; }
    qemu_status_value() { case "$1" in live) printf initializing;; unknown) printf unverified-pid;; dead) printf stale-pid;; esac; }
    qemu_config_get() { printf unknown; }
    manager_collect_rows 0
    [[ ${#XTMOE_LIST_NAMES[@]} == 1 && ${XTMOE_LIST_NAMES[0]} == live ]] || exit 1
    manager_collect_rows 1
    [[ ${#XTMOE_LIST_NAMES[@]} == 3 ]]
' _ "$ROOT_DIR"

assert_ok 'QEMU cloud-init failure remains a usable VM without reporting Docker ready' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/qemu.sh"
    XTMOE_DATA_DIR="$2/bootstrap-fail"
    audit_boot_dir="$(qemu_vm_dir audit)"; mkdir -p "$audit_boot_dir"
    qemu_vm_exists() { return 0; }; qemu_pid_valid() { return 0; }
    qemu_boot_phase() { printf bootstrap-failed; }
    qemu_config_set() { printf "%s=%s\n" "$2" "$3" >>"$audit_boot_dir/changes"; }
    qemu_verify_docker() { printf forbidden >"$audit_boot_dir/verified"; }
    if (qemu_wait_ready --timeout 10 audit); then exit 1; fi
    [[ ! -e $audit_boot_dir/verified ]] && grep -qx state=running "$audit_boot_dir/changes" && grep -qx docker_state=failed "$audit_boot_dir/changes"
' _ "$ROOT_DIR" "$TEST_TMP"

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
