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
    [[ $(tr "\n" " " <"$INIT_TEST_LOG") == "dns network packages dns bash systemd verify dns network " ]]
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

assert_ok 'Fresh bootstrap repairs DNS replaced by package scripts and service startup' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    DNS_FIXTURE="$2/resolved-regression"; mkdir -p "$DNS_FIXTURE"
    chroot_apply_dns() { rm -f "$DNS_FIXTURE/resolv.conf"; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" >"$DNS_FIXTURE/resolv.conf"; }
    chroot_network_preflight() { [[ ! -L $DNS_FIXTURE/resolv.conf ]] && grep -qx "nameserver 1.1.1.1" "$DNS_FIXTURE/resolv.conf"; }
    chroot_setup() { rm -f "$DNS_FIXTURE/resolv.conf"; ln -s /run/systemd/resolve/stub-resolv.conf "$DNS_FIXTURE/resolv.conf"; }
    chroot_systemd_start() { chroot_setup; }
    chroot_systemd_verify() { :; }
    chroot_bootstrap dns-regression --skip-bash-sh --skip-docker || exit 1
    [[ ! -L $DNS_FIXTURE/resolv.conf && $(chroot_meta_get dns-regression state) == ready && $(chroot_meta_get dns-regression last_completed_stage) == network-after-systemd ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Standalone Docker preparation repairs stub DNS before and after dependencies' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    DNS_LOG="$2/docker-dependency-dns"
    chroot_apply_dns() { printf "dns\n" >>"$DNS_LOG"; }
    chroot_network_preflight() { printf "network\n" >>"$DNS_LOG"; }
    chroot_exec() { printf "packages\n" >>"$DNS_LOG"; }
    chroot_docker_dependencies fixture
    [[ $(tr "\n" " " <"$DNS_LOG") == "dns network packages dns " ]]
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
    timeout() { [[ $1 != --kill-after=* ]] || shift; shift; "$@"; }
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

assert_ok 'Noninteractive systemd and direct logins retain command channels without allocating a PTY' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    login_log="$2/noninteractive-logins"
    systemd_exec() { printf "systemd:%s\n" "$*" >>"$login_log"; }
    direct_docker_exec() { printf "direct:%s\n" "$*" >>"$login_log"; }
    systemd_login </dev/null
    guest_interactive_login direct_docker_exec </dev/null
    grep -qx "systemd:/bin/bash -l" "$login_log" && grep -qx "direct:/bin/bash -l" "$login_log"
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

assert_ok 'Systemd start repairs DNS around launch and never refreshes after launch failure' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/systemd-start-network"
    chroot_apply_dns() { printf "dns\n" >>"$lifecycle_log"; }
    chroot_exec() { printf "proxy\n" >>"$lifecycle_log"; }
    chroot_root() { printf "launch\n" >>"$lifecycle_log"; }
    chroot_systemd_network_refresh() { printf "refresh\n" >>"$lifecycle_log"; }
    chroot_systemd_start fixture || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "dns proxy launch refresh " ]] || exit 1
    : >"$lifecycle_log"
    chroot_root() { printf "launch\n" >>"$lifecycle_log"; return 1; }
    if chroot_systemd_start fixture; then exit 1; fi
    [[ $(tr "\n" " " <"$lifecycle_log") == "dns proxy launch " ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy forwarding normalizes case, protects local access, and rejects injected lines' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    [[ -z $(chroot_proxy_environment) ]] || exit 1
    HTTP_PROXY=http://127.0.0.1:7890; HTTPS_PROXY=http://127.0.0.1:7890; NO_PROXY=example.internal
    values=$(chroot_proxy_environment) || exit 1
    grep -qx "http_proxy=http://127.0.0.1:7890" <<<"$values" && grep -qx "HTTPS_PROXY=http://127.0.0.1:7890" <<<"$values" || exit 1
    grep -qx "NO_PROXY=example.internal,localhost,127.0.0.1,::1" <<<"$values" || exit 1
    HTTP_PROXY=$'"'"'http://127.0.0.1:7890\nPATH=/bad'"'"'
    if chroot_proxy_environment; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Proxy daemon drop-in escapes systemd specifiers and only clears managed configuration' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    fixture="$2/proxy-dropin"; mkdir -p "$fixture"
    script=$(chroot_docker_proxy_script)
    script=${script//\/etc\/systemd\/system/$fixture}
    http_proxy=http://user:pa%25ss@127.0.0.1:7890 bash -c "$script" || exit 1
    file="$fixture/docker.service.d/90-xtmoe-proxy.conf"
    grep -q "pa%%25ss" "$file" || exit 1
    bash -c "$script" || exit 1
    [[ ! -e $file ]] || exit 1
    printf "user-owned\n" >"$file"
    if bash -c "$script"; then exit 1; fi
    [[ $(<"$file") == user-owned ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy-assisted preflight allows remote DNS only after real APT succeeds' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    export http_proxy=http://127.0.0.1:7890
    dpkg() { printf arm64; }; cat() { :; }; getent() { return 1; }
    apt-get() { return "${APT_FIXTURE_RESULT:-0}"; }; timeout() { [[ $1 != --kill-after=* ]] || shift; shift; "$@"; }
    export -f dpkg cat getent apt-get timeout
    chroot_exec() { bash -c "$5"; }
    chroot_network_preflight fixture || exit 1
    export APT_FIXTURE_RESULT=1
    if chroot_network_preflight fixture; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'Systemd restart refuses to launch over a failed stop and verifies a successful restart' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/systemd-restart"
    chroot_systemd_stop() { printf "stop\n" >>"$lifecycle_log"; return 1; }
    chroot_systemd_start() { printf "start\n" >>"$lifecycle_log"; }
    chroot_systemd_verify() { printf "verify\n" >>"$lifecycle_log"; }
    if chroot_systemd_restart fixture; then exit 1; fi
    [[ $(<"$lifecycle_log") == stop ]] || exit 1
    : >"$lifecycle_log"
    chroot_systemd_stop() { printf "stop\n" >>"$lifecycle_log"; }
    chroot_systemd_restart fixture || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "stop start verify " ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Login boots a configured systemd environment and never silently falls back after boot failure' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/login-start"; runtime_mode=stopped
    chroot_meta_get() { printf 1; }
    chroot_root() { if [[ $1 == status ]]; then printf "%s\n" "$runtime_mode"; else printf "login\n" >>"$lifecycle_log"; fi; }
    chroot_systemd_start() { printf "start\n" >>"$lifecycle_log"; }
    chroot_systemd_verify() { printf "verify\n" >>"$lifecycle_log"; }
    chroot_login fixture || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "start verify login " ]] || exit 1
    : >"$lifecycle_log"; runtime_mode=direct-docker
    chroot_login fixture || exit 1
    [[ $(<"$lifecycle_log") == login ]] || exit 1
    : >"$lifecycle_log"; runtime_mode=stopped
    chroot_systemd_start() { return 1; }
    if chroot_login fixture; then exit 1; fi
    [[ ! -s $lifecycle_log ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Live network refresh fixes DNS, refreshes active Docker only, and preserves bus errors' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/live-network"; service_state=active; export service_state
    dockerd() { :; }
    systemctl() { [[ $service_state != bus-error ]] || return 1; printf "%s\n" "$service_state"; }
    export -f dockerd systemctl
    chroot_apply_dns() { printf "dns\n" >>"$lifecycle_log"; }
    chroot_docker_routing_setup() { printf "route\n" >>"$lifecycle_log"; }
    chroot_systemd_exec() { bash -c "$5"; }
    chroot_systemd_network_refresh fixture || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "dns route " ]] || exit 1
    for service_state in inactive failed activating; do
        : >"$lifecycle_log"
        chroot_systemd_network_refresh fixture || exit 1
        [[ $(<"$lifecycle_log") == dns ]] || exit 1
    done
    service_state=bus-error
    if chroot_systemd_network_refresh fixture; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Network repair leaves stopped services stopped, avoids APT, and propagates network failure' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/network-repair"; runtime_mode=stopped
    chroot_root() { [[ $1 == status ]] || exit 9; printf "%s\n" "$runtime_mode"; }
    chroot_apply_dns() { printf "dns\n" >>"$lifecycle_log"; }
    chroot_systemd_network_refresh() { printf "refresh\n" >>"$lifecycle_log"; }
    chroot_network_check() { printf "check\n" >>"$lifecycle_log"; }
    chroot_network_preflight() { exit 9; }; chroot_setup() { exit 9; }; chroot_systemd_start() { exit 9; }
    chroot_network_repair fixture || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "dns check " ]] || exit 1
    : >"$lifecycle_log"; runtime_mode=systemd
    chroot_network_repair fixture || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "refresh check " ]] || exit 1
    chroot_network_check() { return 1; }
    if chroot_network_repair fixture; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Docker start and restart refresh routing, propagate failures, and stop includes socket activation' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/docker-lifecycle"
    chroot_systemd_start() { printf "systemd\n" >>"$lifecycle_log"; }
    chroot_systemd_exec() { printf "command\n" >>"$lifecycle_log"; }
    chroot_systemd_network_refresh() { printf "refresh\n" >>"$lifecycle_log"; }
    chroot_docker_status() { printf "status\n" >>"$lifecycle_log"; }
    for action in chroot_docker_start chroot_docker_restart; do
        : >"$lifecycle_log"; "$action" fixture || exit 1
        [[ $(tr "\n" " " <"$lifecycle_log") == "systemd command refresh status " ]] || exit 1
    done
    chroot_systemd_exec() { return 1; }
    : >"$lifecycle_log"
    if chroot_docker_start fixture; then exit 1; fi
    [[ $(<"$lifecycle_log") == systemd ]] || exit 1
    chroot_systemd_exec() { [[ $* == *"stop docker.service docker.socket containerd.service" ]]; }
    chroot_docker_stop fixture
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Docker install restores DNS after package hooks before daemon or registry access' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    lifecycle_log="$2/docker-final-dns"; packages_done=0; dns_fixed=0
    chroot_docker_kernel_check() { :; }; chroot_docker_dependencies() { :; }; chroot_docker_compat_prepare() { :; }
    chroot_systemd_start() { :; }; chroot_systemd_verify() { :; }; chroot_docker_check() { :; }
    chroot_docker_packages_script() { printf fixture-packages; }
    chroot_apply_dns() { [[ $packages_done == 1 ]] || return 1; dns_fixed=1; printf "dns\n" >>"$lifecycle_log"; }
    chroot_docker_status() { :; }; chroot_docker_routing_setup() { printf "route\n" >>"$lifecycle_log"; }
    chroot_systemd_exec() {
        case "$*" in
            *fixture-packages) packages_done=1; dns_fixed=0; printf "packages\n" >>"$lifecycle_log";;
            *"restart containerd.service"*) [[ $dns_fixed == 1 ]] || return 1; printf "daemon\n" >>"$lifecycle_log";;
            *"docker pull hello-world") [[ $dns_fixed == 1 ]] || return 1; printf "pull\n" >>"$lifecycle_log";;
            *) return 0;;
        esac
    }
    chroot_docker_install --accept-host-network-changes docker-gate || exit 1
    [[ $(tr "\n" " " <"$lifecycle_log") == "packages dns daemon route pull " ]] || exit 1
    : >"$lifecycle_log"
    chroot_apply_dns() { return 1; }
    if chroot_docker_install --accept-host-network-changes docker-gate; then exit 1; fi
    [[ $(<"$lifecycle_log") == packages && $(chroot_meta_get docker-gate docker_state) == dns-failed ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Routing refresh reruns an already-active oneshot and preserves unmanaged files' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    XTMOE_LIB_DIR="$1/src/lib"; routing_fixture="$2/routing-refresh"
    mkdir -p "$routing_fixture/system"
    ROUTE_REFRESH_LOG="$routing_fixture/commands"; export ROUTE_REFRESH_LOG
    systemctl() { printf "%s\n" "$*" >>"$ROUTE_REFRESH_LOG"; }; export -f systemctl
    chroot_systemd_exec() {
        local script=$5
        script=${script//\/usr\/local\/libexec/$routing_fixture/libexec}
        script=${script//\/etc\/systemd\/system/$routing_fixture/system}
        bash -c "$script" _ "$7" "$8"
    }
    chroot_docker_routing_setup fixture && chroot_docker_routing_setup fixture || exit 1
    [[ $(grep -c "^restart xtmoe-docker-routing.service$" "$ROUTE_REFRESH_LOG") == 2 ]] || exit 1
    printf "user-owned\n" >"$routing_fixture/system/xtmoe-docker-routing.service"
    if chroot_docker_routing_setup fixture; then exit 1; fi
    [[ $(<"$routing_fixture/system/xtmoe-docker-routing.service") == user-owned ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Systemd stop reports remaining mounts instead of allowing restart over them' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    CONTAINER="$2/stop-mounts"; ROOTFS="$CONTAINER/rootfs"; mkdir -p "$ROOTFS"
    systemd_running() { return 1; }; is_mounted() { return 0; }; unmount_all() { return 1; }
    if systemd_stop; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

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

assert_ok 'Chroot repair preserves a configured hostname and adds one resolvable mapping' bash -c '
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    fixture="$2/hostname-preservation"; mkdir -p "$fixture/etc"
    printf "my-ubuntu.example\n" >"$fixture/etc/hostname"
    printf "10.0.0.1 custom-host\n" >"$fixture/etc/hosts"
    ensure_hosts_config "$fixture"; ensure_hosts_config "$fixture"
    [[ $(<"$fixture/etc/hostname") == my-ubuntu.example ]] || exit 1
    [[ $(grep -c "127.0.1.1.*my-ubuntu.example" "$fixture/etc/hosts") == 1 ]] || exit 1
    grep -qx "10.0.0.1 custom-host" "$fixture/etc/hosts"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Ubuntu Base filters are backed up once and pending restoration survives repeated setup' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    fixture="$2/userland-filter"; mkdir -p "$fixture/dpkg"
    printf "%s\n" "# Ubuntu Base defaults" "path-exclude=/usr/share/man/*" "path-exclude=/usr/share/locale/*/LC_MESSAGES/*.mo" "path-exclude=/usr/share/doc/*" "path-include=/usr/share/doc/*/copyright" "path-include=/usr/share/doc/*/changelog.*" >"$fixture/dpkg/excludes"
    cp "$fixture/dpkg/excludes" "$fixture/original"
    # Git Bash cannot represent a Linux 0700 directory ACL; the real device
    # verifies permissions. Keep the policy/backup fixture filesystem-portable.
    install() { shift 3; mkdir -p -- "$@"; }; export -f install
    script=$(chroot_userland_prepare_script)
    script=${script//\/etc\/dpkg\/dpkg.cfg.d/$fixture/dpkg}
    script=${script//\/var\/lib\/xtmoe\/userland/$fixture/state}
    bash -e -c "$script" && bash -e -c "$script" || exit 1
    [[ ! -e $fixture/dpkg/excludes && -f $fixture/state/restore.pending ]] || exit 1
    backups=("$fixture/state"/base-excludes.*)
    [[ ${#backups[@]} == 1 ]] && cmp -s "${backups[0]}" "$fixture/original"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Userland restoration replaces only the known local man placeholder and preserves a backup' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    fixture="$2/userland-man-stub"; mkdir -p "$fixture"
    script=$(chroot_userland_restore_script)
    sed -n "/^#!\/bin\/sh$/,/^XTMOE_MINIMIZED_MAN$/p" <<<"$script" | sed '\''$d'\'' >"$fixture/man"
    printf "#!/bin/sh\nexit 0\n" >"$fixture/man.REAL"; chmod +x "$fixture/man.REAL"
    script=${script//\/usr\/bin\/man/$fixture/man}
    script=${script//\/var\/lib\/xtmoe\/userland/$fixture/state}
    script=${script//\/etc\/default\/locale/$fixture/locale}
    USERLAND_MAN_FIXTURE=$fixture; export USERLAND_MAN_FIXTURE
    dpkg-divert() {
        case "$1" in
            --truename) printf "%s/man.REAL\n" "$USERLAND_MAN_FIXTURE";;
            --listpackage) printf LOCAL;;
            --local) mv "$USERLAND_MAN_FIXTURE/man.REAL" "$USERLAND_MAN_FIXTURE/man";;
            *) return 9;;
        esac
    }
    install() { shift 3; mkdir -p -- "$@"; }; export -f install dpkg-divert
    bash -e -c "$script" || exit 1
    [[ -x $fixture/man && ! -e $fixture/man.REAL ]] || exit 1
    grep -q "exit 0" "$fixture/man" || exit 1
    backups=("$fixture/state"/man-stub.*)
    [[ ${#backups[@]} == 1 ]] && grep -q "This system has been minimized" "${backups[0]}"
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Userland preparation refuses custom filters and symlinks without changing policy' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    fixture="$2/userland-custom-filter"; mkdir -p "$fixture/dpkg"
    printf "path-exclude=/usr/share/doc/custom/*\n" >"$fixture/dpkg/excludes"
    script=$(chroot_userland_prepare_script)
    script=${script//\/etc\/dpkg\/dpkg.cfg.d/$fixture/dpkg}
    script=${script//\/var\/lib\/xtmoe\/userland/$fixture/state}
    if bash -e -c "$script"; then exit 1; fi
    [[ ! -e $fixture/state && $(<"$fixture/dpkg/excludes") == "path-exclude=/usr/share/doc/custom/*" ]] || exit 1
    mv "$fixture/dpkg/excludes" "$fixture/custom"
    ln -s "$fixture/custom" "$fixture/dpkg/excludes"
    if bash -e -c "$script"; then exit 1; fi
    [[ -L $fixture/dpkg/excludes && -f $fixture/custom && ! -e $fixture/state ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Userland restoration reinstalls only missing installed package files and retries APT failure' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    fixture="$2/userland-restore"; mkdir -p "$fixture/info" "$fixture/state"
    printf "ubuntu-base-userland-v1\n" >"$fixture/state/restore.pending"
    printf "abc usr/share/man/man1/fixture.1.gz\n" >"$fixture/info/fixture.md5sums"
    printf "abc usr/share/man/man1/removed.1.gz\n" >"$fixture/info/removed.md5sums"
    script=$(chroot_userland_restore_script)
    script=${script//\/var\/lib\/xtmoe\/userland/$fixture/state}
    script=${script//\/var\/lib\/dpkg\/info/$fixture/info}
    script=${script//\/etc\/default\/locale/$fixture/locale}
    script=${script//\"\/\$xtmoe_relative\"/\"$fixture/\$xtmoe_relative\"}
    USERLAND_FIXTURE=$fixture; export USERLAND_FIXTURE
    dpkg-query() { [[ ${!#} != removed ]] && printf installed || printf config-files; }
    man() { printf "/usr/share/man/man1/%s.1.gz\n" "${!#}"; }
    apt-get() { [[ $* == "install -y --reinstall fixture" ]] || return 9; return 1; }
    export -f dpkg-query apt-get man
    if bash -e -c "$script"; then exit 1; fi
    [[ -f $fixture/state/restore.pending ]] || exit 1
    apt-get() { [[ $* == "install -y --reinstall fixture" ]] || return 9; mkdir -p "$USERLAND_FIXTURE/usr/share/man/man1"; printf restored >"$USERLAND_FIXTURE/usr/share/man/man1/fixture.1.gz"; }
    export -f apt-get
    bash -e -c "$script" || exit 1
    [[ ! -e $fixture/state/restore.pending && $(<"$fixture/locale") == LANG=C.UTF-8 ]]
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
