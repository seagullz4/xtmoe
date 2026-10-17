#!/usr/bin/env bash
# Sourced by run.sh. No downloads, real mounts or real package installation.

assert_ok 'Chroot install preflight failure prevents download and metadata creation' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_install_preflight() { return 1; }
    download_ubuntu_base() { printf forbidden >"$2"; }
    if chroot_install --yes --skip-docker ubuntu 24.04 init-preflight-fail; then exit 1; fi
    [[ ! -e $(chroot_meta_file init-preflight-fail) ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot install dispatch reaches dependency preparation before requiring Root' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    require_chroot() { exit 9; }; chroot_install() { printf install-dispatched; }
    [[ $(chroot_main install --skip-docker) == install-dispatched ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot init orders DNS, real source preflight, packages, shell and verified systemd' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    mkdir -p "$(chroot_base)/init-order"; touch "$(chroot_base)/init-order/.xtmoe-chroot"
    INIT_TEST_LOG="$2/init-order.log"
    chroot_apply_dns() { printf "dns\n" >>"$INIT_TEST_LOG"; }
    chroot_network_preflight() { printf "network\n" >>"$INIT_TEST_LOG"; }
    chroot_setup() { printf "packages\n" >>"$INIT_TEST_LOG"; }
    chroot_use_bash_sh() { printf "bash\n" >>"$INIT_TEST_LOG"; }
    chroot_systemd_start() { printf "systemd\n" >>"$INIT_TEST_LOG"; }
    chroot_systemd_verify() { printf "verify\n" >>"$INIT_TEST_LOG"; }
    chroot_init --skip-docker init-order
    [[ $(tr "\n" " " <"$INIT_TEST_LOG") == "dns network packages bash systemd verify " ]]
    [[ $(chroot_meta_get init-order state) == ready && $(chroot_meta_get init-order docker_state) == skipped-by-user ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot network failure records partial and blocks all package and Docker mutation' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    INIT_TEST_LOG="$2/network-mutations"
    chroot_apply_dns() { :; }; chroot_network_preflight() { return 1; }
    chroot_setup() { printf forbidden >"$INIT_TEST_LOG"; }
    chroot_docker_install() { printf forbidden >"$INIT_TEST_LOG"; }
    if chroot_bootstrap init-network --accept-host-network-changes; then exit 1; fi
    [[ ! -e $INIT_TEST_LOG && $(chroot_meta_get init-network state) == partial && $(chroot_meta_get init-network failed_stage) == network ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot repair preserves skipped shell/Docker and resumes after package failure without extraction' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    mkdir -p "$(chroot_base)/init-repair"; touch "$(chroot_base)/init-repair/.xtmoe-chroot"
    INIT_TEST_LOG="$2/repair-mutations"
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }; chroot_setup() { return 1; }
    if chroot_bootstrap init-repair --skip-bash-sh --skip-docker; then exit 1; fi
    [[ $(chroot_meta_get init-repair failed_stage) == packages ]] || exit 1
    chroot_setup() { :; }; chroot_systemd_start() { :; }; chroot_systemd_verify() { :; }
    chroot_use_bash_sh() { printf forbidden >"$INIT_TEST_LOG"; }
    download_ubuntu_base() { printf forbidden >"$INIT_TEST_LOG"; }
    chroot_docker_install() { printf forbidden >"$INIT_TEST_LOG"; }
    chroot_repair init-repair && chroot_repair init-repair || exit 1
    [[ ! -e $INIT_TEST_LOG && $(chroot_meta_get init-repair state) == ready && -z $(chroot_meta_get init-repair failed_stage) ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot systemd verification failure prevents Docker and records exact stage' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    INIT_TEST_LOG="$2/systemd-mutations"
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }; chroot_setup() { :; }; chroot_systemd_start() { :; }
    chroot_systemd_verify() { return 1; }; chroot_docker_install() { printf forbidden >"$INIT_TEST_LOG"; }
    if chroot_bootstrap init-systemd --skip-bash-sh --accept-host-network-changes; then exit 1; fi
    [[ ! -e $INIT_TEST_LOG && $(chroot_meta_get init-systemd failed_stage) == systemd-verify ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot init accepts default network preparation without reading stdin' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    mkdir -p "$(chroot_base)/init-consent"; touch "$(chroot_base)/init-consent/.xtmoe-chroot"
    chroot_bootstrap() { [[ $* == *--accept-host-network-changes* ]]; }
    chroot_init init-consent </dev/null
' _ "$ROOT_DIR"

assert_ok 'Chroot init declining bridge changes still allows Ubuntu/systemd initialization' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    mkdir -p "$(chroot_base)/init-decline"; touch "$(chroot_base)/init-decline/.xtmoe-chroot"
    chroot_confirm_network_changes() { return 1; }
    chroot_bootstrap() { [[ $* == "init-decline --skip-docker" ]]; }
    chroot_init init-decline
' _ "$ROOT_DIR"

assert_ok 'Chroot DNS failure prevents APT and strict source failure propagates' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    INIT_TEST_LOG="$2/network-apt-calls"; export INIT_TEST_LOG
    dpkg() { printf arm64; }; cat() { printf "nameserver 1.1.1.1\n"; }
    getent() { return 1; }; apt-get() { printf "%s\n" "$*" >>"$INIT_TEST_LOG"; return 1; }
    timeout() { shift 2; "$@"; }
    export -f dpkg cat getent apt-get timeout
    chroot_exec() { bash -c "$5"; }
    if chroot_network_preflight init-order; then exit 1; fi
    [[ ! -e $INIT_TEST_LOG ]] || exit 1
    getent() { printf "1.2.3.4 fixture\n"; }; export -f getent
    if chroot_network_preflight init-order; then exit 1; fi
    grep -q "APT::Update::Error-Mode=any" "$INIT_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot systemd verification accepts running and qualified degraded, not critical failures' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    SYSTEMD_FIXTURE_STATE=running; SYSTEMD_FIXTURE_BAD_UNIT=""; export SYSTEMD_FIXTURE_STATE SYSTEMD_FIXTURE_BAD_UNIT
    SYSTEMD_FIXTURE_TMP="$2/systemd-basic"; SYSTEMD_FIXTURE_TIME=0; export SYSTEMD_FIXTURE_TMP SYSTEMD_FIXTURE_TIME
    mktemp() { command mktemp "$SYSTEMD_FIXTURE_TMP.XXXXXX"; }
    date() { printf "%s\n" "$SYSTEMD_FIXTURE_TIME"; }
    sleep() { SYSTEMD_FIXTURE_TIME=$((SYSTEMD_FIXTURE_TIME + $1)); }
    systemctl() {
        case "$1" in
            is-system-running) printf "%s\n" "$SYSTEMD_FIXTURE_STATE"; [[ $SYSTEMD_FIXTURE_STATE == running ]];;
            is-active) [[ $3 != "$SYSTEMD_FIXTURE_BAD_UNIT" ]];;
            --failed) return 0;; status) return 1;; *) return 1;;
        esac
    }
    journalctl() { printf "fixture journal\n"; }
    timeout() { shift 2; "$@"; }; export -f systemctl timeout mktemp date sleep journalctl
    chroot_systemd_exec() { bash -c "$5"; }
    chroot_systemd_verify init-order || exit 1
    SYSTEMD_FIXTURE_STATE=degraded
    chroot_systemd_verify init-order || exit 1
    SYSTEMD_FIXTURE_BAD_UNIT=dbus.service
    if chroot_systemd_verify init-order; then exit 1; fi
    SYSTEMD_FIXTURE_STATE=starting
    if chroot_systemd_verify init-order; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

# Focused guest-side verifier scenarios: fake time avoids a 120-second real
# wait, but execute the production generated script rather than copying it.
systemd_verifier_fixture() (
    source "$ROOT_DIR/src/lib/common.sh"
    source "$ROOT_DIR/src/lib/chroot.sh"
    SYSTEMD_VERIFY_SCENARIO=$1
    SYSTEMD_VERIFY_FIXTURE="$TEST_TMP/systemd-$1"
    SYSTEMD_VERIFY_TIME=0
    export SYSTEMD_VERIFY_SCENARIO SYSTEMD_VERIFY_FIXTURE SYSTEMD_VERIFY_TIME
    printf 0 >"$SYSTEMD_VERIFY_FIXTURE.probes"
    mktemp() { command mktemp "$SYSTEMD_VERIFY_FIXTURE.XXXXXX"; }
    date() { printf '%s\n' "$SYSTEMD_VERIFY_TIME"; }
    sleep() { SYSTEMD_VERIFY_TIME=$((SYSTEMD_VERIFY_TIME + $1)); }
    timeout() { shift 2; "$@"; }
    journalctl() { printf 'fixture journal diagnostic\n'; }
    systemctl() {
        if [[ $1 == is-system-running ]]; then
            # --wait is precisely what the regression must not reintroduce.
            [[ $* != *--wait* ]] || return 9
            local count
            count=$(( $(<"$SYSTEMD_VERIFY_FIXTURE.probes") + 1 ))
            printf '%s' "$count" >"$SYSTEMD_VERIFY_FIXTURE.probes"
            case "$SYSTEMD_VERIFY_SCENARIO" in
                ready-after-starting)
                    if ((count == 1)); then printf 'starting\n'; return 1; fi
                    printf 'running\n'; return 0 ;;
                timeout-then-ready)
                    if ((count == 1)); then printf 'fixture timeout detail\n' >&2; return 124; fi
                    printf 'running\n'; return 0 ;;
                pending-job) printf 'starting\n'; return 1 ;;
                bus-error) printf 'Failed to connect to bus: Permission denied\n' >&2; return 1 ;;
                empty-success) return 0 ;;
                empty-timeout) return 124 ;;
                missing-command) printf 'fixture exec failure\n' >&2; return 127 ;;
            esac
            return 9
        fi
        case "$1" in
            is-active) return 0 ;;
            list-jobs) printf 'fixture wait-online.service start running\n' ;;
            --failed) printf '0 loaded units listed.\n' ;;
            status) printf 'fixture basic services diagnostic\n' ;;
            *) return 9 ;;
        esac
    }
    export -f mktemp date sleep timeout systemctl journalctl
    chroot_systemd_exec() { bash -c "$5"; }
    result=0
    chroot_systemd_verify fixture >"$SYSTEMD_VERIFY_FIXTURE.out" 2>"$SYSTEMD_VERIFY_FIXTURE.err" || result=$?
    case "$SYSTEMD_VERIFY_SCENARIO" in
        ready-after-starting)
            [[ $result == 0 ]] && grep -q 'systemd: starting' "$SYSTEMD_VERIFY_FIXTURE.out" && grep -q 'systemd: running' "$SYSTEMD_VERIFY_FIXTURE.out" ;;
        timeout-then-ready)
            [[ $result == 0 && $(<"$SYSTEMD_VERIFY_FIXTURE.probes") == 2 ]] && grep -q 'fixture timeout detail' "$SYSTEMD_VERIFY_FIXTURE.err" ;;
        pending-job|empty-timeout)
            [[ $result == 1 && $(<"$SYSTEMD_VERIFY_FIXTURE.probes") -le 25 ]] && grep -q '120 秒内未完成启动' "$SYSTEMD_VERIFY_FIXTURE.err" && grep -q 'fixture wait-online.service' "$SYSTEMD_VERIFY_FIXTURE.err" && grep -q '0 loaded units' "$SYSTEMD_VERIFY_FIXTURE.err" ;;
        bus-error)
            [[ $result == 1 && $(<"$SYSTEMD_VERIFY_FIXTURE.probes") == 1 ]] && grep -q 'Failed to connect to bus: Permission denied' "$SYSTEMD_VERIFY_FIXTURE.err" ;;
        empty-success|missing-command)
            [[ $result == 1 && $(<"$SYSTEMD_VERIFY_FIXTURE.probes") == 1 ]] && grep -q 'systemd: 无响应' "$SYSTEMD_VERIFY_FIXTURE.out" ;;
    esac
)

assert_ok 'Systemd verifier reports starting and polls to running without --wait' systemd_verifier_fixture ready-after-starting
assert_ok 'Systemd verifier retries bounded probe timeout and retains stderr' systemd_verifier_fixture timeout-then-ready
assert_ok 'Systemd verifier lists pending jobs even when failed units are empty' systemd_verifier_fixture pending-job
assert_ok 'Systemd verifier preserves bus permission errors and stops immediately' systemd_verifier_fixture bus-error
assert_ok 'Systemd verifier refuses empty output even with successful exit status' systemd_verifier_fixture empty-success
assert_ok 'Systemd verifier bounds repeated empty timeouts instead of blank status' systemd_verifier_fixture empty-timeout
assert_ok 'Systemd verifier distinguishes command execution failure' systemd_verifier_fixture missing-command

assert_ok 'Chroot repair does not silently enable systemd on a basic-only installation' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    mkdir -p "$(chroot_base)/init-basic"; touch "$(chroot_base)/init-basic/.xtmoe-chroot"
    chroot_meta_set init-basic systemd_requested 0
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }
    chroot_setup() { exit 9; }; chroot_systemd_start() { exit 9; }
    chroot_repair init-basic
    [[ $(chroot_meta_get init-basic systemd_requested) == 0 && $(chroot_meta_get init-basic state) == ready ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot initialization rejects lock contention before executing any stage' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    flock() { return 1; }; chroot_apply_dns() { exit 9; }
    if chroot_bootstrap init-busy --skip-docker; then exit 1; fi
    [[ ! -e $(chroot_meta_file init-busy) ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot Root boundary closes initialization locks only in descendants' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    exec {CHROOT_INIT_LOCK_FD}>"$2/init-fd-test"
    exec {CHROOT_INSTALL_LOCK_FD}>"$2/install-fd-test"
    expected_init_fd=$CHROOT_INIT_LOCK_FD; expected_install_fd=$CHROOT_INSTALL_LOCK_FD
    chroot_helper() { printf /dev/null; }
    run_root() {
        # Do not wrap this check in another redirection: Bash may reuse the
        # freshly closed FD to save stderr, making a closed FD appear open.
        if : >&"$expected_init_fd"; then return 1; fi
        if : >&"$expected_install_fd"; then return 1; fi
    }
    chroot_root probe || exit 1
    : >&"$CHROOT_INIT_LOCK_FD" && : >&"$CHROOT_INSTALL_LOCK_FD"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot reinstall preserves rootfs if image preflight fails' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    mkdir -p "$(chroot_base)/init-reinstall/rootfs"; touch "$(chroot_base)/init-reinstall/.xtmoe-chroot"
    printf original >"$(chroot_base)/init-reinstall/rootfs/keep"
    chroot_install_preflight() { :; }; download_ubuntu_base() { return 1; }
    chroot_root() { exit 9; }
    if chroot_reinstall --yes --skip-docker init-reinstall; then exit 1; fi
    [[ $(<"$(chroot_base)/init-reinstall/rootfs/keep") == original ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot download and checksum failure propagate even in a conditional caller' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    XTMOE_CACHE_DIR="$2/download-error-cache"
    ubuntu_arch() { printf amd64; }
    curl() { return 1; }
    if output=$(download_ubuntu_base 24.04); then exit 1; fi
    [[ -z $output ]] || exit 1
    curl() {
        output_file=""; url=""
        while (($#)); do case "$1" in -o) output_file=$2; shift 2;; *) url=$1; shift;; esac; done
        case "$url" in
            */release/) printf "ubuntu-base-24.04.5-base-amd64.tar.gz\n" >"$output_file";;
            */SHA256SUMS) printf "%064d *ubuntu-base-24.04.5-base-amd64.tar.gz\n" 0 >"$output_file";;
            *.tar.gz) printf invalid-archive >"$output_file";; *) return 1;;
        esac
    }
    if output=$(download_ubuntu_base 24.04); then exit 1; fi
    [[ -z $output ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot reinstall refuses deletion after stop failure in a conditional caller' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    INIT_TEST_LOG="$2/reinstall-stop-calls"
    mkdir -p "$(chroot_base)/init-stop-fail"; touch "$(chroot_base)/init-stop-fail/.xtmoe-chroot"
    chroot_install_preflight() { :; }; download_ubuntu_base() { printf cache; }
    chroot_root() { printf "%s\n" "$1" >>"$INIT_TEST_LOG"; return 1; }
    if chroot_reinstall --yes --skip-docker init-stop-fail; then exit 1; fi
    [[ $(<"$INIT_TEST_LOG") == stop && -f $(chroot_base)/init-stop-fail/.xtmoe-chroot ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot Docker user dependencies are prepared before systemd and full gate' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    INIT_TEST_LOG="$2/docker-order"
    chroot_docker_kernel_check() { printf "kernel\n" >>"$INIT_TEST_LOG"; }
    chroot_docker_dependencies() { printf "dependencies\n" >>"$INIT_TEST_LOG"; }
    chroot_docker_compat_prepare() { printf "compatibility\n" >>"$INIT_TEST_LOG"; }
    chroot_systemd_start() { printf "systemd\n" >>"$INIT_TEST_LOG"; }; chroot_systemd_verify() { :; }
    chroot_docker_check() { printf "full-gate\n" >>"$INIT_TEST_LOG"; return 1; }
    chroot_systemd_exec() { exit 9; }
    if chroot_docker_install --accept-host-network-changes init-order; then exit 1; fi
    [[ $(tr "\n" " " <"$INIT_TEST_LOG") == "kernel dependencies compatibility systemd full-gate " && $(chroot_meta_get init-order docker_state) == prerequisites-failed ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot Docker dependency failure is not mislabeled kernel-blocked' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_docker_kernel_check() { :; }; chroot_docker_dependencies() { return 1; }
    chroot_systemd_start() { exit 9; }
    if chroot_docker_install --accept-host-network-changes init-order; then exit 1; fi
    [[ $(chroot_meta_get init-order docker_state) == dependencies-failed ]]
' _ "$ROOT_DIR"

assert_ok 'Chroot generated scripts parse and APT update treats repository errors as failure' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_exec() { bash -n -c "$5" && grep -q "APT::Update::Error-Mode=any" <<<"$5"; }
    chroot_network_preflight init-order || exit 1
    chroot_exec() { bash -n -c "$5" && grep -q "getent ahostsv4" <<<"$5" && ! grep -q eval <<<"$5"; }
    chroot_network_check init-order
' _ "$ROOT_DIR"

assert_ok 'Chroot package setup script validates and blocks service autostart' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_exec() {
        bash -n -c "$5" || return 1
        grep -q "exit 101" <<<"$5" && grep -q "dpkg --configure -a" <<<"$5" && grep -q "systemd-sysv dbus" <<<"$5" && grep -q "iptables --version" <<<"$5"
    }
    chroot_setup init-order
' _ "$ROOT_DIR"

assert_ok 'Chroot package guard restores original policy on success and failure' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    fixture="$2/policy-fixture"; mkdir -p "$fixture/sbin" "$fixture/run"
    printf "original-policy\n" >"$fixture/sbin/policy-rc.d"
    guard=$(chroot_apt_guard_script)
    guard=${guard//\/usr\/sbin/$fixture/sbin}; guard=${guard//\/run\//$fixture/run/}
    # This fixture tests policy restoration, not the lock implementation. The
    # guest script resets PATH, so export a stub independent of the mock PATH.
    flock() { :; }; export -f flock
    bash -c "$guard
grep -q \"exit 101\" \"$fixture/sbin/policy-rc.d\"" || exit 1
    [[ $(<"$fixture/sbin/policy-rc.d") == original-policy ]] || exit 1
    if bash -c "$guard
false"; then exit 1; fi
    [[ $(<"$fixture/sbin/policy-rc.d") == original-policy ]] || exit 1
    rm -f -- "$fixture/sbin/policy-rc.d"
    printf linked-policy >"$fixture/sbin/saved-policy"
    ln -s saved-policy "$fixture/sbin/policy-rc.d"
    bash -c "$guard
grep -q \"exit 101\" \"$fixture/sbin/policy-rc.d\"" || exit 1
    [[ -L $fixture/sbin/policy-rc.d && $(readlink "$fixture/sbin/policy-rc.d") == saved-policy ]] || exit 1
    rm -f -- "$fixture/sbin/policy-rc.d"
    if bash -c "$guard
false"; then exit 1; fi
    [[ ! -e $fixture/sbin/policy-rc.d && ! -L $fixture/sbin/policy-rc.d ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot hosts repair corrects existing NSS stub config without dropping custom hosts' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    fixture="$2/hosts-fixture"; mkdir -p "$fixture/etc"
    printf "hosts: resolve [!UNAVAIL=return] files\npasswd: files\n" >"$fixture/etc/nsswitch.conf"
    printf "10.0.0.1 custom-host\n" >"$fixture/etc/hosts"
    ensure_hosts_config "$fixture"; ensure_hosts_config "$fixture"
    grep -qx "hosts: files dns" "$fixture/etc/nsswitch.conf" && grep -qx "passwd: files" "$fixture/etc/nsswitch.conf" && grep -q custom-host "$fixture/etc/hosts" && [[ $(grep -c "^hosts:" "$fixture/etc/nsswitch.conf") == 1 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot gate classifies software failure separately and probes NAT only in fresh netns' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS=/fixture
    GATE_TEST_LOG="$2/nat-probe"
    namespace_check() { :; }; cgroup_mode() { printf v2; }; cgroup_has_controller() { :; }
    cat() { if [[ ${1:-} == /proc/sys/net/ipv4/ip_forward ]]; then printf 1; else command cat "$@"; fi; }
    systemd_running() { :; }; systemd_manager_ready() { :; }
    rootfs_has_executable() { return 1; }
    docker_gate kernel || exit 1
    result=0; docker_gate || result=$?
    [[ $result == 1 ]] || exit 1
    rootfs_has_executable() { return 0; }
    timeout() { printf "%s\n" "$*" >>"$GATE_TEST_LOG"; printf "fixture-version\n"; }
    docker_gate || exit 1
    grep -q -- "20 unshare --net chroot /fixture /usr/bin/env -i" "$GATE_TEST_LOG" && grep -q -- "-m addrtype --dst-type LOCAL" "$GATE_TEST_LOG" || exit 1
    timeout() { [[ $* != *" unshare "* ]]; }
    result=0; docker_gate || result=$?
    [[ $result == 2 ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot guest path resolution follows alternatives and rejects escape and link loops' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    fixture="$2/link-fixture"; mkdir -p "$fixture/etc/alternatives" "$fixture/usr/sbin"
    printf "#!/bin/sh\nexit 0\n" >"$fixture/usr/sbin/xtables-nft-multi"; chmod +x "$fixture/usr/sbin/xtables-nft-multi"
    ln -s /etc/alternatives/iptables "$fixture/usr/sbin/iptables"
    ln -s /usr/sbin/xtables-nft-multi "$fixture/etc/alternatives/iptables"
    rootfs_has_executable "$fixture" /usr/sbin/iptables || exit 1
    [[ $(rootfs_resolve_path "$fixture" /usr/sbin/iptables) == "$fixture/usr/sbin/xtables-nft-multi" ]] || exit 1
    ln -s ../../outside "$fixture/escape"
    if rootfs_resolve_path "$fixture" /escape; then exit 1; fi
    ln -s /loop "$fixture/loop"
    if rootfs_resolve_path "$fixture" /loop; then exit 1; fi
    ln -s /usr "$fixture/absolute-directory"
    [[ $(rootfs_resolve_path "$fixture" /absolute-directory/sbin/iptables) == "$fixture/usr/sbin/xtables-nft-multi" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Systemd launcher passes clean container identity before executing guest PID 1' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    fixture="$2/systemd-launch-fixture"; mkdir -p "$fixture/bin"
    ROOTFS="$fixture/rootfs"; export SYSTEMD_LAUNCH_FIXTURE_LOG="$fixture/steps" SYSTEMD_LAUNCH_FIXTURE_ARGS="$fixture/args"
    cat >"$fixture/bin/chroot" <<"MOCK_CHROOT"
#!/usr/bin/env bash
printf "%s\n" "$@" >"$SYSTEMD_LAUNCH_FIXTURE_ARGS"
printf "exec\n" >>"$SYSTEMD_LAUNCH_FIXTURE_LOG"
MOCK_CHROOT
    chmod +x "$fixture/bin/chroot"; export PATH="$fixture/bin:$PATH"
    readlink() { if [[ $1 == /proc/self/ns/mnt ]]; then printf private-mnt; else printf host-mnt; fi; }
    mount() { printf "isolate\n" >>"$SYSTEMD_LAUNCH_FIXTURE_LOG"; }
    mount_all() { [[ $2 == 0 ]] || exit 9; printf "mounts\n" >>"$SYSTEMD_LAUNCH_FIXTURE_LOG"; }
    ensure_cgroup_mount() { printf "cgroup\n" >>"$SYSTEMD_LAUNCH_FIXTURE_LOG"; }
    systemd_protect_kernel_views() { printf "protect\n" >>"$SYSTEMD_LAUNCH_FIXTURE_LOG"; }
    (systemd_namespace_launch fixture.binds) || exit 1
    [[ $(tr "\n" " " <"$SYSTEMD_LAUNCH_FIXTURE_LOG") == "isolate mounts cgroup protect exec " ]] || exit 1
    grep -qx container=xtmoe "$SYSTEMD_LAUNCH_FIXTURE_ARGS" && grep -qx /usr/bin/env "$SYSTEMD_LAUNCH_FIXTURE_ARGS" && grep -qx -- -i "$SYSTEMD_LAUNCH_FIXTURE_ARGS" && grep -q /run/host/container-manager "$SYSTEMD_LAUNCH_FIXTURE_ARGS"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Systemd launcher refuses the host mount namespace before any mount' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    readlink() { printf same-mnt; }
    mount() { printf forbidden >"$2"; }
    if (systemd_namespace_launch); then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Systemd sysfs protection remounts only guest non-cgroup views read-only' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS="$2/systemd sysfs/rootfs"
    mkdir -p "$ROOTFS/sys/fs/selinux" "$ROOTFS/sys/fs/cgroup" "$ROOTFS/selinux"
    SYSTEMD_MOUNT_TEST_LOG="$2/sysfs-remounts"
    awk() {
        if [[ ${1:-} == -v && ${2:-} == p=* ]]; then
            for target in "$ROOTFS/sys" "$ROOTFS/sys/fs/selinux" "$ROOTFS/sys/fs/cgroup" "$ROOTFS/sys/fs/cgroup/pids"; do mount_path_encode "$target"; printf "\n"; done
        else command awk "$@"; fi
    }
    mount() { printf "%s\n" "$*" >>"$SYSTEMD_MOUNT_TEST_LOG"; }
    systemd_protect_kernel_views || exit 1
    grep -Fxq -- "-o remount,bind,ro -- $ROOTFS/sys/fs/selinux" "$SYSTEMD_MOUNT_TEST_LOG" && grep -Fxq -- "-o remount,bind,ro -- $ROOTFS/sys" "$SYSTEMD_MOUNT_TEST_LOG" && grep -Fxq -- "-o remount,bind,ro -- $ROOTFS/selinux" "$SYSTEMD_MOUNT_TEST_LOG" || exit 1
    ! grep -q /fs/cgroup "$SYSTEMD_MOUNT_TEST_LOG" && ! grep -Fxq -- "-o remount,bind,ro -- /sys" "$SYSTEMD_MOUNT_TEST_LOG"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Systemd sysfs protection fails closed when a read-only remount is denied' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    ROOTFS="$2/systemd-ro-fail/rootfs"; mkdir -p "$ROOTFS/sys"
    awk() { if [[ ${1:-} == -v ]]; then mount_path_encode "$ROOTFS/sys"; printf "\n"; else command awk "$@"; fi; }
    mount() { return 1; }
    if (systemd_protect_kernel_views); then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Systemd guest bootstrap refuses proc mount failure and never loads policy' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    script=$(systemd_guest_init_script)
    bash -n -c "$script" || exit 1
    [[ $script == *"mount -t proc proc /proc ||"* && $script == *"container:-"* && $script == *"exec /sbin/init"* ]] || exit 1
    if grep -Eq "setenforce|load_policy|SELINUX=disabled|mount -t selinuxfs" <<<"$script"; then exit 1; fi
    mount() { return 1; }; export -f mount
    if bash -c "$script"; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Root dispatch falls back to su when tsu Shell invocation fails' bash -c '
    source "$1/src/lib/common.sh"
    tsu() { printf "unknown option\n" >&2; return 2; }
    su() { [[ $1 == -c ]] || return 9; if [[ $2 == "id -u" ]]; then printf "0\n"; else bash -c "$2"; fi; }
    [[ $(run_root printf "%s" "argument with spaces") == "argument with spaces" ]]
' _ "$ROOT_DIR"
