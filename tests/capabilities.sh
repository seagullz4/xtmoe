#!/usr/bin/env bash
assert_ok 'Public Chroot restart passes the actual CLI allowlist and preserves the target name' bash -c '
    source "$1/src/lib/common.sh"
    chroot_main() { [[ $* == "restart custom-ubuntu" ]]; }
    public_chroot restart custom-ubuntu
' _ "$ROOT_DIR"
# Sourced by run.sh.
assert_ok 'Android API 24 is accepted and API 23 is rejected' bash -c '
    source "$1/src/lib/common.sh"
    getprop() { printf 24; }; android_supported || exit 1
    getprop() { printf 23; }; if android_supported; then exit 1; fi
    getprop() { printf malformed; }; if android_supported; then exit 1; fi
' _ "$ROOT_DIR"

for pair in aarch64:arm64 arm:armhf x86_64:amd64 i686:i386; do
    assert_ok "Native ABI maps $pair without trusting the kernel architecture" bash -c '
        source "$1/src/lib/common.sh"; pair=$2
        dpkg() { printf "%s" "${pair%:*}"; }; uname() { printf aarch64; }
        [[ $(native_arch) == "${pair#*:}" ]]
    ' _ "$ROOT_DIR" "$pair"
done

assert_fail 'Unknown user-space ABI is rejected' bash -c '
    source "$1/src/lib/common.sh"; dpkg() { printf unknown; }; native_arch
' _ "$ROOT_DIR"

assert_fail 'Ubuntu Base does not claim i386 support' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    native_arch() { printf i386; }; ubuntu_arch
' _ "$ROOT_DIR"

assert_ok 'No Root does not fail the PRoot doctor baseline' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    require_termux() { :; }; root_available() { return 1; }
    capability_report >"$2/no-root"
    grep -qx Root=unavailable "$2/no-root"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Capability selection records unsupported enhancements without discarding Ubuntu' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_root() { case "$1" in capabilities) printf "base=supported\nsystemd=unsupported\ndocker=unsupported\nnetwork=unsupported\n";; network-mode) [[ $4 == shared ]];; *) return 1;; esac; }
    chroot_select_capabilities portable || exit 1
    [[ $(chroot_meta_get portable systemd_requested) == 0 && $(chroot_meta_get portable docker_capability) == unsupported ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Basic-only bootstrap completes without attempting systemd or Docker' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_meta_set basic systemd_capability unsupported; chroot_meta_set basic docker_capability unsupported
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }; chroot_setup() { :; }
    chroot_systemd_start() { exit 9; }; chroot_docker_install() { exit 9; }
    chroot_bootstrap basic || exit 1
    [[ $(chroot_meta_get basic state) == ready && $(chroot_meta_get basic systemd_requested) == 0 && $(chroot_meta_get basic docker_state) == unsupported ]]
' _ "$ROOT_DIR"

assert_ok 'New PRoot install pins native architecture without compatibility aliases' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    log="$2/native-install"; native_proot_arch() { printf arm; }
    proot_ssh_lock() { exec {PROOT_SSH_LOCK_FD}>"${log}.lock"; }
    proot_ssh_choose_port() { printf 22222; }
    proot_ssh_initialize() { :; }; proot_ssh_start_locked() { :; }
    timeout() { shift 3; "$@"; }
    proot-distro() { if [[ $* == "install --help" ]]; then printf "%s\n" "--name --architecture"; else printf "%s\n" "$*" >"$log"; fi; }
    proot_install ubuntu:24.04 native
    [[ $(<"$log") == "install --name native --architecture arm ubuntu:24.04" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'PRoot restore rejects an existing target before invoking destructive upstream restore' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    fixture="$2/proot-restore"; mkdir -p "$fixture/demo/rootfs" "$PREFIX/var/lib/proot-distro/containers/demo/rootfs"
    printf keep >"$PREFIX/var/lib/proot-distro/containers/demo/rootfs/user-file"
    tar -czf "$fixture/backup.tar.gz" -C "$fixture" demo
    proot-distro() { printf forbidden >"$fixture/called"; }
    if (proot_restore "$fixture/backup.tar.gz"); then exit 1; fi
    [[ ! -e $fixture/called && $(<"$PREFIX/var/lib/proot-distro/containers/demo/rootfs/user-file") == keep ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Network priorities avoid foreign rules without modifying them' bash -c '
    source "$1/src/lib/xtmoe-network"
    warn() { :; }; BASE="$2/priority"; CONTAINER="$BASE/current"; mkdir -p "$CONTAINER"
    ip() { if [[ $* == "-4 rule show" ]]; then printf "10500: from all lookup foreign\n"; fi; }
    net_paths; net_allocate || exit 1
    [[ $NET_PRIORITY == 10540 ]] || exit 1
    net_paths; [[ $NET_PRIORITY == 10540 ]]
' _ "$ROOT_DIR" "$TEST_TMP"
