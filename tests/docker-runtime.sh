#!/usr/bin/env bash
# Sourced by run.sh: Android nft/legacy, real OverlayFS and policy route regressions.

assert_ok 'Docker network rule probe checks addrtype/NAT/bridge, not list-only success' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    script=$(docker_network_probe_script)
    bash -n -c "$script" && grep -q -- "-A PREROUTING -m addrtype" <<<"$script" && grep -q -- "-j MASQUERADE" <<<"$script" && grep -q "type veth" <<<"$script"
' _ "$ROOT_DIR"

assert_ok 'Docker compatible current backend is not switched' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS=/fixture; rootfs_has_executable() { return 0; }
    docker_network_probe() { return 0; }; chroot() { exit 9; }
    docker_network_prepare
' _ "$ROOT_DIR"

assert_ok 'Docker incompatible nft backend selects legacy only after a real successful probe' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS=/fixture; COMPAT_TEST_LOG="$2/legacy-selection"
    rootfs_has_executable() { return 0; }
    docker_network_probe() { [[ $1 == /usr/sbin/iptables-legacy ]]; }
    chroot() {
        printf "%s\n" "$*" >>"$COMPAT_TEST_LOG"
        case "$*" in *readlink*) printf /usr/sbin/xtables-nft-multi;; *--query*) printf "Status: auto\n";; esac
    }
    docker_network_prepare || exit 1
    grep -q -- "--set iptables /usr/sbin/iptables-legacy" "$COMPAT_TEST_LOG" && grep -q -- "--set ip6tables /usr/sbin/ip6tables-legacy" "$COMPAT_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Docker failed nft and legacy probes never change alternatives' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS=/fixture; rootfs_has_executable() { return 0; }
    docker_network_probe() { return 1; }; chroot() { exit 9; }
    result=0; docker_network_prepare || result=$?
    [[ $result == 2 ]]
' _ "$ROOT_DIR"

assert_ok 'Docker target filesystem mount failure produces complete classic VFS configuration' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS="$2/overlay-failure/rootfs"; TERMUX_PREFIX=/fixture
    mkdir -p "$ROOTFS"; timeout() { return 1; }
    docker_storage_prepare || exit 1
    grep -qx "{\"features\":{\"containerd-snapshotter\":false},\"storage-driver\":\"vfs\"}" "$ROOTFS/etc/docker/daemon.json"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Docker successful target OverlayFS probe keeps default config absent' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS="$2/overlay-success/rootfs"; TERMUX_PREFIX=/fixture
    mkdir -p "$ROOTFS"; timeout() { return 0; }
    docker_storage_prepare && [[ ! -e $ROOTFS/etc/docker/daemon.json ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Docker storage preparation preserves user JSON and existing data stores' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS="$2/storage-preserved/rootfs"; mkdir -p "$ROOTFS/etc/docker"
    printf "{\"user-config\":true}\n" >"$ROOTFS/etc/docker/daemon.json"
    timeout() { exit 9; }
    docker_storage_prepare || exit 1
    grep -qx "{\"user-config\":true}" "$ROOTFS/etc/docker/daemon.json" || exit 1
    ROOTFS="$2/store-preserved/rootfs"; mkdir -p "$ROOTFS/var/lib/containerd"
    printf precious >"$ROOTFS/var/lib/containerd/data"
    docker_storage_prepare && [[ ! -e $ROOTFS/etc/docker/daemon.json && $(<"$ROOTFS/var/lib/containerd/data") == precious ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Routing parameters reject injection, invalid IPv4 and oversized interface names' bash -c '
    source "$1/src/lib/xtmoe-docker-routing"
    routing_validate 172.17.0.0/16 docker0 1036 || exit 1
    if routing_validate "172.17.0.0/16;bad" docker0 1036; then exit 1; fi
    if routing_validate 999.17.0.0/16 docker0 1036; then exit 1; fi
    if routing_validate 172.17.0.0/16 "docker0;bad" 1036; then exit 1; fi
    if routing_validate 172.17.0.0/16 docker0 "1036;bad"; then exit 1; fi
    if routing_validate 172.17.0.0/16 toolonginterfacename 1036; then exit 1; fi
' _ "$ROOT_DIR"

routing_fixture() (
    source "$ROOT_DIR/src/lib/xtmoe-docker-routing"
    routing_scenario=$1
    routing_state_file="$TEST_TMP/routing-$1.state"
    ROUTING_TEST_LOG="$TEST_TMP/routing-$1.commands"
    : >"$ROUTING_TEST_LOG"
    timeout() { shift; "$@"; }
    docker() {
        if [[ $* == *Subnet* ]]; then printf '172.17.0.0/16 172.17.0.1\n'; else printf 'docker0\n'; fi
    }
    ip() {
        printf '%s\n' "$*" >>"$ROUTING_TEST_LOG"
        case "$*" in
            'link show dev docker0') return 0 ;;
            '-4 route get 1.1.1.1 from '* ) [[ $routing_scenario == native ]] ;;
            '-4 route get 1.1.1.1')
                if [[ $routing_scenario == bad-table ]]; then printf '1.1.1.1 dev tun0 table 1036;bad\n'; else printf '1.1.1.1 dev tun0 table 1036 src 172.19.0.1\n'; fi ;;
            '-4 rule show') [[ $routing_scenario != collision ]] || printf '10940: from all lookup other\n'; return 0 ;;
            '-4 rule add priority 10950 '*) [[ $routing_scenario != second-rule-fails ]] ;;
            '-4 rule add '*|'-4 rule del '*) return 0 ;;
            *) return 9 ;;
        esac
    }
    result=0; routing_start || result=$?
    case "$routing_scenario" in
        native) [[ $result == 0 && ! -e $routing_state_file ]] && ! grep -q 'rule add' "$ROUTING_TEST_LOG" ;;
        android)
            [[ $result == 0 && $(<"$routing_state_file") == '172.17.0.0/16|docker0|1036' ]] || exit 1
            grep -qx -- '-4 rule add priority 10950 from 172.17.0.0/16 iif docker0 lookup 1036' "$ROUTING_TEST_LOG" || exit 1
            routing_start && routing_stop && routing_stop || exit 1
            [[ ! -e $routing_state_file ]] && grep -qx -- '-4 rule del priority 10940 to 172.17.0.0/16 lookup main' "$ROUTING_TEST_LOG" ;;
        collision|bad-table) [[ $result != 0 && ! -e $routing_state_file ]] && ! grep -q 'rule add' "$ROUTING_TEST_LOG" ;;
        second-rule-fails)
            [[ $result != 0 && ! -e $routing_state_file ]] && grep -qx -- '-4 rule del priority 10940 to 172.17.0.0/16 lookup main' "$ROUTING_TEST_LOG" ;;
    esac
)

assert_ok 'Native forwarding requires no Android policy route changes' routing_fixture native
assert_ok 'Android bridge routes follow current VPN table and stop cleans exact owned rules' routing_fixture android
assert_ok 'Routing refuses occupied priorities without replacing user rules' routing_fixture collision
assert_ok 'Routing refuses malformed detected table before changing rules' routing_fixture bad-table
assert_ok 'Routing rolls back the first rule when adding the second fails' routing_fixture second-rule-fails

assert_ok 'Docker routing unit follows daemon lifecycle, not Android boot' bash -c '
    grep -qx Requires=docker.service "$1/src/lib/xtmoe-docker-routing.service" && grep -qx PartOf=docker.service "$1/src/lib/xtmoe-docker-routing.service" && grep -qx WantedBy=docker.service "$1/src/lib/xtmoe-docker-routing.service"
' _ "$ROOT_DIR"

docker_acceptance_fixture() (
    source "$ROOT_DIR/src/lib/common.sh"
    source "$ROOT_DIR/src/lib/chroot.sh"
    docker_test_scenario=$1
    chroot_docker_kernel_check() { :; }; chroot_docker_dependencies() { :; }; chroot_docker_compat_prepare() { :; }
    chroot_systemd_start() { :; }; chroot_systemd_verify() { :; }; chroot_docker_check() { :; }
    chroot_docker_status() { :; }; chroot_docker_routing_setup() { :; }
    chroot_systemd_exec() {
        case "$*" in
            *'docker pull hello-world') [[ $docker_test_scenario != registry-failed ]] ;;
            *'docker run --rm --pull=never hello-world') [[ $docker_test_scenario == ready ]] || return 125 ;;
            *) return 0 ;;
        esac
    }
    local result=0 expected
    chroot_docker_install --accept-host-network-changes docker-gate || result=$?
    case "$docker_test_scenario" in
        registry-failed) expected=daemon-ready-registry-unverified; [[ $result == 1 ]] || exit 1 ;;
        container-failed) expected=daemon-ready-container-failed; [[ $result == 125 ]] || exit 1 ;;
        ready) expected=ready; [[ $result == 0 ]] || exit 1 ;;
    esac
    [[ $(chroot_meta_get docker-gate docker_state) == "$expected" ]]
)

assert_ok 'Registry failure remains distinct from container execution failure' docker_acceptance_fixture registry-failed
assert_ok 'Successful pull with failed real container records runtime failure, not registry failure' docker_acceptance_fixture container-failed
assert_ok 'Docker complete readiness requires pull and real container success' docker_acceptance_fixture ready
