#!/usr/bin/env bash
# Sourced by run.sh; exercise configuration, allocation, ownership and dispatch.
assert_ok 'Plain Chroot kernel protection diagnostics do not contaminate command stdout' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS=/fixture; XTMOE_NET_PLAIN=1
    net_proxy_environment() { :; }; ensure_hosts_config() { :; }; is_mounted() { return 1; }
    mount_all() { :; }; unmount_all() { :; }
    systemd_protect_kernel_views() { printf "diagnostic\n"; }
    chroot() { printf smoke-ok; }
    [[ $(run_chroot "" /bin/cat /root/marker) == smoke-ok ]]
' _ "$ROOT_DIR"

assert_ok 'Private IPv4 validation rejects injection, invalid octets and ambiguous ports' bash -c '
    source "$1/src/lib/xtmoe-network"
    net_ipv4 10.203.0.2 && net_port 65535 || exit 1
    for value in 256.1.1.1 1.2.3 "1.2.3.4;id" 01.2.3.4; do if net_ipv4 "$value"; then exit 1; fi; done
    for value in 0 65536 -1 01 "22;id"; do if net_port "$value"; then exit 1; fi; done
' _ "$ROOT_DIR"

assert_ok 'Private port parser rejects malformed or linked configuration' bash -c '
    source "$1/src/lib/xtmoe-network"; warn() { :; }
    NET_PORTS="$2/private-ports"
    printf "192.168.0.6|28081|18081|tcp\n" >"$NET_PORTS"
    [[ $(net_port_lines) == "192.168.0.6|28081|18081|tcp" ]] || exit 1
    printf "192.168.0.6|28081|18081|tcp|extra\n" >"$NET_PORTS"
    if net_port_lines; then exit 1; fi
    ln -s "$NET_PORTS" "$NET_PORTS.link"; NET_PORTS+=.link
    if net_port_lines; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Port reservation distinguishes protocol, explicit address and wildcard listeners' bash -c '
    source "$1/src/lib/xtmoe-network"
    ss() { printf "tcp LISTEN 0 128 127.0.0.1:19808 *:*\ntcp LISTEN 0 128 *:5555 *:*\nudp UNCONN 0 0 192.168.0.6:28082 *:*\n"; }
    net_port_busy 192.168.0.6 5555 tcp || exit 1
    net_port_busy 192.168.0.6 28082 udp || exit 1
    if net_port_busy 192.168.0.6 19808 tcp || net_port_busy 192.168.0.6 28082 tcp; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Loopback proxy translation preserves credentials and repeated exec keeps the relay' bash -c '
    source "$1/src/lib/xtmoe-network"
    fixture="$2/network-proxy"; mkdir "$fixture"; printf /fixture/iptables >"$fixture/iptables"
    printf "39808\n" >"$fixture/proxy-19808.port"
    net_paths() { NET_MODE=isolated; NET_SLOT=0; NET_RUN=$fixture; NET_HOST=xnfixture; NET_CHAIN=XNfixture; }
    net_running() { return 0; }; net_pid_alive() { return 0; }; readlink() { printf host-net; }
    net_lock() { :; }; net_unlock() { :; }
    socat() { :; }; net_ipt() { return 0; }
    ORIGINAL_GUEST_PROXY_ENV=("http_proxy=http://user:pass@127.0.0.1:19808" "https_proxy=http://other.example:8080" "no_proxy=localhost")
    GUEST_PROXY_ENV=("${ORIGINAL_GUEST_PROXY_ENV[@]}")
    net_proxy_environment || exit 1
    [[ ${GUEST_PROXY_ENV[0]} == http_proxy=http://user:pass@10.203.0.1:39808 && ${GUEST_PROXY_ENV[1]} == https_proxy=http://other.example:8080 ]] || exit 1
    net_proxy_environment || exit 1
    [[ ${GUEST_PROXY_ENV[0]} == http_proxy=http://user:pass@10.203.0.1:39808 && ${ORIGINAL_GUEST_PROXY_ENV[0]} == http_proxy=http://user:pass@127.0.0.1:19808 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Missing egress installs a per-veth unreachable guard without selecting a physical interface' bash -c '
    source "$1/src/lib/xtmoe-network"
    NET_SLOT=0; NET_HOST=xnfixture; NET_CHAIN=XNfixture; NET_RUN="$2/no-egress"; mkdir "$NET_RUN"
    log="$NET_RUN/commands"; NET_PORTS="$NET_RUN/ports"
    net_running() { return 0; }; net_egress() { NET_EGRESS=""; NET_EGRESS_TABLE=main; return 1; }
    net_ipt() { printf "iptables %s\n" "$*" >>"$log"; [[ $* != *" -C "* && $1 != -C ]]; }
    ip() { printf "ip %s\n" "$*" >>"$log"; }
    net_refresh || exit 1
    grep -q "rule add priority 10530 iif xnfixture unreachable" "$log" || exit 1
    ! grep -q MASQUERADE "$log" && ! grep -q wlan0 "$log"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Watcher cleans a holder lost before its first refresh with initialized ownership addresses' bash -c '
    source "$1/src/lib/xtmoe-network"
    fixture="$2/watcher-loss"; mkdir "$fixture"; printf /fixture/iptables >"$fixture/iptables"
    net_paths() { NET_RUN=$fixture; NET_SLOT=1; }
    net_running() { return 1; }; net_lock() { :; }; net_unlock() { :; }
    net_cleanup_locked() { [[ $NET_SUBNET == 10.203.0.4/30 && $NET_GUEST == 10.203.0.6 ]]; }
    net_watch
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Daemon descriptor cleanup closes inherited handles only in the child' bash -c '
    source "$1/src/lib/xtmoe-network"
    exec {test_fd}>"$2/daemon-fd"
    (net_close_fds; [[ ! -e /proc/self/fd/$test_fd ]]) || exit 1
    printf parent-alive >&"$test_fd"
    exec {test_fd}>&-
    [[ $(<"$2/daemon-fd") == parent-alive ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Nested systemd stop exits its manager and cleans networking after service shutdown' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    log="$2/nested-stop"; stop_fixture=$2; ROOTFS=/fixture
    systemd_running() { return 0; }; systemd_target_pid() { printf 123; }; rootfs_has_executable() { return 0; }
    systemd_exec() { printf "%s\n" "$*" >>"$log"; }; process_alive() { return 1; }
    readlink() { printf private-pid; }; systemd_resume_namespace_waiters() { :; }
    systemd_pid_files() { PID_FILE="$stop_fixture/unused.pid"; LAUNCHER_PID_FILE="$stop_fixture/unused-launcher.pid"; }
    unmount_all() { printf "unmount\n" >>"$log"; }; net_stop() { printf "network-stop\n" >>"$log"; }
    systemd_stop || exit 1
    grep -qx "/usr/bin/systemctl exit" "$log" && ! grep -q poweroff "$log" && [[ $(tail -n 1 "$log") == network-stop ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Shutdown resumes only stopped nsenter parents belonging to its exact PID namespace' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    log="$2/namespace-waiters"
    pgrep() { printf "123\n456\n789\n"; }; net_identity() { printf 100; }
    readlink() { if [[ $1 == /proc/456/* ]]; then printf another-pid; else printf private-pid; fi; }
    cat() { printf nsenter; }; awk() { if [[ $* == */proc/789/status ]]; then printf S; else printf T; fi; }
    kill() { printf "%s\n" "$*" >>"$log"; }
    systemd_resume_namespace_waiters private-pid
    [[ $(<"$log") == "-CONT 123" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Network allocator understands overlap and /30 boundary addresses' bash -c '
    source "$1/src/lib/xtmoe-network"
    net_cidr_overlap 10.203.0.0/30 10.203.0.0/16 || exit 1
    net_cidr_overlap 10.203.0.0/30 10.203.0.2/32 || exit 1
    if net_cidr_overlap 10.203.0.0/30 10.203.0.4/30; then exit 1; fi
    NET_SLOT=16383; net_addresses
    [[ $NET_SUBNET == 10.203.255.252/30 && $NET_GATEWAY == 10.203.255.253 && $NET_GUEST == 10.203.255.254 ]]
' _ "$ROOT_DIR"

assert_ok 'Missing network config defaults auto and configuration is never sourced' bash -c '
    source "$1/src/lib/xtmoe-network"
    die() { exit 1; }; CONTAINER="$2/network-config"; mkdir -p "$CONTAINER"
    net_paths; [[ $NET_MODE == auto && $NET_SLOT == -1 ]] || exit 1
    NET_SLOT=5; net_save_config; net_paths; [[ $NET_SLOT == 5 ]] || exit 1
    printf "mode=shared\nslot=5\nmode=isolated\n" >"$NET_CONFIG"
    if (net_paths); then exit 1; fi
    printf "mode=\$(touch %s/injected)\n" "$CONTAINER" >"$NET_CONFIG"
    if (net_paths); then exit 1; fi
    [[ ! -e $CONTAINER/injected ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Address allocation excludes live routes and other stopped container reservations' bash -c '
    source "$1/src/lib/xtmoe-network"
    warn() { :; }; BASE="$2/net-allocation"; CONTAINER="$BASE/current"; mkdir -p "$CONTAINER" "$BASE/other"
    printf "mode=isolated\nslot=1\n" >"$BASE/other/.xtmoe-network"
    ip() { [[ $* == *"table all"* ]] || return 0; printf "10.203.0.0/30 dev other\n192.168.0.0/24 dev wlan0\n"; }
    net_paths; net_allocate || exit 1
    [[ $NET_SLOT == 2 && $NET_GUEST == 10.203.0.10 ]] || exit 1
    net_paths; net_allocate; [[ $NET_SLOT == 2 ]]
    ip() { return 0; }
    NET_SLOT=1; net_allocate; [[ $NET_SLOT == 0 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'PID ownership rejects reuse and missing process without sending signals' bash -c '
    source "$1/src/lib/xtmoe-network"
    file="$2/net-owner"; net_record_pid "$$" "$file"; net_pid_alive "$file" || exit 1
    printf "%s 0\n" "$$" >"$file"; if net_pid_alive "$file"; then exit 1; fi
    printf "999999999 1\n" >"$file"; if net_pid_alive "$file"; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Private mode changes refuse a live container before touching networking' bash -c '
    source "$1/src/lib/xtmoe-network"
    die() { exit 1; }; systemd_running() { return 0; }
    net_stop() { touch "$2/forbidden"; }
    if (net_mode_set shared); then exit 1; fi
    [[ ! -e $2/forbidden ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'New CLI network actions preserve arguments and never change existing status output' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    require_chroot() { :; }; ensure_dirs() { :; }
    chroot_root() { printf "%s\n" "$@"; }
    result=$(chroot_main port-add ubuntu24 --listen 192.168.0.6:18080 --to 80 --proto udp) || exit 1
    grep -qx port-add <<<"$result" && grep -qx 192.168.0.6:18080 <<<"$result" && grep -qx udp <<<"$result"
' _ "$ROOT_DIR"
