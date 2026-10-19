#!/usr/bin/env bash
# Sourced by run.sh; exercise configuration, allocation, ownership and dispatch.
assert_ok 'Shadowed veth rules migrate only the owned priority group and retain a guard until refresh succeeds' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    CONTAINER="$2/shadowed"; NET_RUN="$CONTAINER/run"; mkdir -p "$NET_RUN"
    NET_CONFIG="$CONTAINER/.xtmoe-network"; NET_MODE=isolated; NET_SLOT=0; NET_PRIORITY=10580
    NET_HOST=xnfixture; net_addresses
    log="$NET_RUN/commands"; warn() { :; }
    printf "tun0 tun0\n" >"$NET_RUN/egress"
    printf "old-signature" >"$NET_RUN/signature"
    ip() {
        printf "%s\n" "$*" >>"$log"
        if [[ $* == "-4 rule show" ]]; then printf "10000: from all lookup legacy_system\n10520: from all iif xnfixture lookup wlan0\n10560: from all iif xnfixture lookup 1044\n"; fi
    }
    net_priority_prepare
    [[ $NET_PRIORITY == 10020 && -f $NET_RUN/priority-pending ]] || exit 1
    grep -qx "priority=10020" "$NET_CONFIG" || exit 1
    grep -qx -- "-4 rule add priority 10050 iif xnfixture unreachable" "$log" || exit 1
    net_priority_finish
    [[ -f $NET_RUN/priority-pending ]] || exit 1
    if grep -q "rule del" "$log"; then exit 1; fi
    printf "priority-v2|10020|ready" >"$NET_RUN/signature"
    net_priority_finish
    [[ ! -e $NET_RUN/priority-pending ]] || exit 1
    grep -qx -- "-4 rule del priority 10600 iif xnfixture lookup tun0" "$log" || exit 1
    if grep -Eq "rule del priority (10520|10560) " "$log"; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Shadow migration fails without touching foreign rules when no earlier group exists and rolls back an uncommitted guard' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    CONTAINER="$2/shadow-busy"; NET_RUN="$CONTAINER/run"; mkdir -p "$NET_RUN"
    NET_CONFIG="$CONTAINER/.xtmoe-network"; NET_MODE=isolated; NET_SLOT=0; NET_PRIORITY=10580
    NET_HOST=xnfixture; net_addresses; log="$NET_RUN/commands"; warn() { :; }
    ip() { printf "%s\n" "$*" >>"$log"; if [[ $* == "-4 rule show" ]]; then printf "10030: from all iif xnfixture lookup foreign\n"; fi; }
    if net_priority_prepare; then exit 1; fi
    [[ $NET_PRIORITY == 10580 && ! -e $NET_RUN/priority-pending && ! -e $NET_CONFIG ]] || exit 1
    ip() { printf "%s\n" "$*" >>"$log"; if [[ $* == "-4 rule show" ]]; then printf "10520: from all iif xnfixture lookup wlan0\n"; fi; }
    net_save_config() { return 1; }
    if net_priority_prepare; then exit 1; fi
    [[ $NET_PRIORITY == 10580 && ! -e $NET_RUN/priority-pending ]] || exit 1
    grep -qx -- "-4 rule del priority 10050 iif xnfixture unreachable" "$log" || exit 1
    if grep -Eq "rule del priority (10520|10560|10580) " "$log"; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Interrupted priority migration keeps old rules until new signature and stopping cleans both owned groups' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    NET_RUN="$2/shadow-recovery"; mkdir -p "$NET_RUN"; NET_HOST=xnfixture
    NET_SLOT=0; NET_PRIORITY=10020; net_addresses; log="$NET_RUN/commands"
    printf "10580 10020 tun0\n" >"$NET_RUN/priority-pending"
    printf "lan-return-v1|old" >"$NET_RUN/signature"
    ip() { printf "%s\n" "$*" >>"$log"; }
    net_priority_prepare
    [[ -f $NET_RUN/priority-pending && ! -s $log ]] || exit 1
    net_priority_finish stopping
    [[ ! -e $NET_RUN/priority-pending ]] || exit 1
    grep -qx -- "-4 rule del priority 10580 to 10.203.0.0/30 lookup 40000" "$log"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'An unrelated veth does not trigger migration but a rule between owned lookup and egress does' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    CONTAINER="$2/shadow-middle"; NET_RUN="$CONTAINER/run"; mkdir -p "$NET_RUN"
    NET_CONFIG="$CONTAINER/.xtmoe-network"; NET_MODE=isolated; NET_SLOT=0; NET_PRIORITY=10580
    NET_HOST=xnfixture; net_addresses; middle=0; warn() { :; }
    ip() {
        if [[ $* == "-4 rule show" ]]; then
            printf "10010: from all iif xnother lookup foreign\n10590: from all iif xnfixture lookup 40000 suppress_prefixlength 0\n"
            if ((middle)); then printf "10595: from all iif xnfixture lookup wlan0\n"; fi
        fi
        return 0
    }
    net_priority_prepare
    [[ $NET_PRIORITY == 10580 && ! -e $NET_RUN/priority-pending ]] || exit 1
    middle=1; net_priority_prepare
    [[ $NET_PRIORITY == 10020 && -f $NET_RUN/priority-pending ]]
' _ "$ROOT_DIR" "$TEST_TMP"

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
    printf "auto|28081|18081|tcp\n" >"$NET_PORTS"
    [[ $(net_port_lines) == "auto|28081|18081|tcp" ]] || exit 1
    printf "auto;id|28081|18081|tcp\n" >"$NET_PORTS"
    if net_port_lines; then exit 1; fi
    printf "192.168.0.6|28081|18081|tcp|extra\n" >"$NET_PORTS"
    if net_port_lines; then exit 1; fi
    ln -s "$NET_PORTS" "$NET_PORTS.link"; NET_PORTS+=.link
    if net_port_lines; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Auto LAN discovery excludes VPN, cellular, bridges, public and invalid addresses' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    ip() { printf "%s\n" \
        "2: wlan0 inet 192.168.1.123/24 brd 192.168.1.255 scope global wlan0" \
        "3: ap0 inet 192.168.43.1/24 scope global ap0" \
        "4: eth0@if1 inet 10.0.0.3/24 scope global eth0" \
        "5: tun0 inet 10.8.0.2/24 scope global tun0" \
        "6: ccmni0 inet 10.9.0.2/24 scope global ccmni0" \
        "7: rmnet_data0 inet 10.9.0.3/24 scope global rmnet_data0" \
        "8: docker0 inet 172.17.0.1/16 scope global docker0" \
        "9: xnfixture inet 10.203.0.1/30 scope global xnfixture" \
        "2: wlan0 inet 203.0.113.2/24 scope global wlan0" \
        "2: wlan0 inet 192.168.1.124/24 scope global tentative wlan0" \
        "2: wlan0 inet 999.168.1.1/24 scope global wlan0"; }
    [[ $(net_auto_addresses) == $(printf "10.0.0.3\n192.168.1.123\n192.168.43.1") ]]
' _ "$ROOT_DIR"

assert_ok 'Auto mappings rebind A to B, pause offline, recover and retry occupied ports' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    NET_SLOT=0; NET_HOST=xnfixture; NET_CHAIN=XNfixture; NET_RUN="$2/auto-refresh"; mkdir "$NET_RUN"
    NET_PORTS="$NET_RUN/ports"; printf "auto|18080|80|tcp\n192.168.1.123|18081|81|udp\n" >"$NET_PORTS"
    log="$NET_RUN/rules"; lan=192.168.1.123; occupied=0
    warn() { :; }; net_running() { return 0; }
    net_egress() { NET_EGRESS=tun0; NET_EGRESS_TABLE=100; }
    ip() {
        if [[ $* == *addr* && -n $lan ]]; then printf "2: wlan0 inet %s/24 scope global wlan0\n" "$lan"; fi
        return 0
    }
    ss() { if ((occupied)); then printf "tcp LISTEN 0 128 0.0.0.0:18080 *:*\n"; fi; return 0; }
    net_ipt() { printf "%s\n" "$*" >>"$log"; [[ $* != *" -C "* && $1 != -C ]]; }
    net_refresh
    grep -F -- "-d 192.168.1.123/32 -p tcp --dport 18080 -j DNAT" "$log" || exit 1
    : >"$log"; lan=192.168.99.123; net_refresh
    grep -F -- "-d 192.168.99.123/32 -p tcp --dport 18080 -j DNAT" "$log" || exit 1
    if grep -F -- "-d 192.168.1.123/32" "$log"; then exit 1; fi
    : >"$log"; lan=""; net_refresh
    grep -F -- "-t nat -F XNfixture" "$log" || exit 1
    if grep -F -- "-j DNAT" "$log"; then exit 1; fi
    [[ $(net_ports_status) == *waiting-lan* ]] || exit 1
    : >"$log"; lan=192.168.99.123; occupied=1; net_refresh
    if grep -F -- "-j DNAT" "$log"; then exit 1; fi
    [[ $(net_ports_status) == *port-occupied* ]] || exit 1
    : >"$log"; occupied=0; net_refresh
    grep -F -- "-d 192.168.99.123/32 -p tcp --dport 18080 -j DNAT" "$log" || exit 1
    [[ $(net_ports_status) == *pending* ]] || exit 1
    printf /fixture/iptables >"$NET_RUN/iptables"
    net_ipt() { return 0; }
    [[ $(net_ports_status) == *"auto:18080 => 192.168.99.123:18080 -> 80/tcp [active]"* ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Mapped LAN replies get connected routes without copying VPN or default routes' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"; NET_SUBNET=10.203.0.0/30
    ip() { printf "%s\n" \
        "2: wlan0 inet 10.77.74.139/24 scope global wlan0" \
        "3: eth0 inet 192.168.9.5/24 scope global eth0" \
        "4: tun0 inet 10.8.0.2/24 scope global tun0" \
        "5: wlan1 inet 10.99.0.1/8 scope global wlan1" \
        "6: wlan2 inet 192.168.8.2/0 scope global wlan2"; }
    resolved=$(printf "auto|10.77.74.139|1234|22|tcp|ready\nauto|10.8.0.2|1234|22|tcp|ready\nauto|192.168.9.5|1234|22|tcp|port-occupied\nauto|192.168.8.2|1234|22|tcp|ready\n")
    [[ $(net_lan_routes "$resolved") == "10.77.74.0/24|wlan0|10.77.74.139" ]]
    [[ -z $(net_lan_routes "") ]]
' _ "$ROOT_DIR"

assert_ok 'LAN return routes migrate and disappear without altering Android routes or VPN egress' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    NET_SLOT=0; NET_HOST=xnfixture; NET_CHAIN=XNfixture; NET_RUN="$2/lan-return"; mkdir "$NET_RUN"
    NET_PORTS="$NET_RUN/ports"; printf "auto|1234|22|tcp\n" >"$NET_PORTS"
    log="$NET_RUN/commands"; lan=10.77.74.139; link=wlan0; warn() { :; }
    net_running() { return 0; }; net_egress() { NET_EGRESS=tun0; NET_EGRESS_TABLE=100; }
    ip() {
        printf "ip %s\n" "$*" >>"$log"
        if [[ $* == *addr* && -n $lan ]]; then printf "2: %s inet %s/24 scope global %s\n" "$link" "$lan" "$link"; fi
        return 0
    }
    ss() { :; }; net_ipt() { printf "iptables %s\n" "$*" >>"$log"; [[ $* != *" -C "* && $1 != -C ]]; }
    net_refresh
    grep -qx "ip -4 route replace table 40000 10.77.74.0/24 dev wlan0 scope link src 10.77.74.139" "$log"
    grep -q "iif xnfixture lookup 100" "$log"
    : >"$log"; lan=192.168.99.7; link=eth0; net_refresh
    grep -qx "ip -4 route del table 40000 10.77.74.0/24 dev wlan0 scope link src 10.77.74.139" "$log"
    grep -qx "ip -4 route replace table 40000 192.168.99.0/24 dev eth0 scope link src 192.168.99.7" "$log"
    : >"$log"; lan=""; net_refresh
    grep -qx "ip -4 route del table 40000 192.168.99.0/24 dev eth0 scope link src 192.168.99.7" "$log"
    if grep -Eq "route (flush|replace .*default|.*table (main|100|wlan0))" "$log"; then exit 1; fi
    [[ -z $(<"$NET_RUN/lan-routes") ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'LAN return route overlap fails closed and linked state is not followed' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"; warn() { :; }; NET_SUBNET=10.203.0.0/30
    ip() { printf "2: wlan0 inet 10.203.0.9/24 scope global wlan0\n"; }
    if net_lan_routes "auto|10.203.0.9|1234|22|tcp|ready"; then exit 1; fi
    NET_RUN="$2/lan-route-link"; mkdir "$NET_RUN"; printf untouched >"$NET_RUN/target"
    ln -s "$NET_RUN/target" "$NET_RUN/lan-routes"
    if net_lan_routes_remove; then exit 1; fi
    [[ $(<"$NET_RUN/target") == untouched ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Auto reservations survive offline creation and reject fixed or cross-container overlap' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    BASE="$2/auto-reservations"; CONTAINER="$BASE/first"; mkdir -p "$CONTAINER" "$BASE/second"
    NET_PORTS="$CONTAINER/.xtmoe-ports"; NET_MODE=isolated
    die() { exit 1; }; net_paths() { :; }; net_lock() { :; }; net_unlock() { :; }; net_running() { return 1; }
    net_lan_address() { return 0; }; ss() { :; }
    net_port_change add --listen auto:18080 --to 80 --proto tcp
    [[ $(net_port_lines) == "auto|18080|80|tcp" ]] || exit 1
    if (net_port_change add --listen 192.168.1.123:18080 --to 81 --proto tcp); then exit 1; fi
    CONTAINER="$BASE/second"; NET_PORTS="$CONTAINER/.xtmoe-ports"
    if (net_port_change add --listen auto:18080 --to 82 --proto tcp); then exit 1; fi
    net_port_change add --listen auto:18080 --to 83 --proto udp
    net_port_change remove --listen auto:18080 --proto udp
    [[ -z $(net_port_lines) ]] || exit 1
    CONTAINER="$BASE/first"; NET_PORTS="$CONTAINER/.xtmoe-ports"
    net_port_change remove --listen auto:18080 --proto tcp
    net_port_change add --listen 192.168.1.123:18080 --to 80 --proto tcp
    CONTAINER="$BASE/second"; NET_PORTS="$CONTAINER/.xtmoe-ports"
    if (net_port_change add --listen auto:18080 --to 80 --proto tcp); then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Auto mappings report each LAN and fail closed when listener inspection fails' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    ss() { printf "udp UNCONN 0 0 192.168.1.123:18080 *:*\n"; }
    result=$(net_resolved_ports "auto|18080|80|udp" $'"'"'192.168.1.123\n192.168.43.1'"'"')
    [[ $result == *"auto|192.168.1.123|18080|80|udp|port-occupied"* && $result == *"auto|192.168.43.1|18080|80|udp|ready"* ]] || exit 1
    ss() { return 1; }
    [[ $(net_resolved_ports "auto|18080|80|tcp" "192.168.1.123") == *listener-check-failed ]]
' _ "$ROOT_DIR"

assert_ok 'Adding auto mapping to a pinned old watcher requires a container restart' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/xtmoe-network"
    fixture="$2/legacy-watcher"; mkdir "$fixture"
    net_paths() { NET_MODE=isolated; NET_RUN=$fixture; NET_PORTS="$fixture/ports"; }
    net_lock() { :; }; net_unlock() { :; }; net_running() { return 0; }; die() { exit 1; }
    if (net_port_change add --listen auto:18080 --to 80); then exit 1; fi
    [[ ! -e $fixture/ports ]]
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
