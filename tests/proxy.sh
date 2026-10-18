#!/usr/bin/env bash
# Sourced by run.sh. All network requests and daemon operations are simulated.

assert_ok 'Proxy library persists settings across processes and forwards to PRoot without changing the parent' bash -c '
    set -Eeuo pipefail
    export XTMOE_CONFIG_DIR="$2/proxy-cli-config" XTMOE_DATA_DIR="$2/proxy-cli-data"
    export http_proxy=http://parent.example:3128
    bash "$1/tests/internal.sh" proxy on 7890 --no-proxy example.internal
    [[ $http_proxy == http://parent.example:3128 ]] || exit 1
    bash "$1/tests/internal.sh" proxy exec -- bash -c '\''[[ $http_proxy == http://127.0.0.1:7890 && $HTTPS_PROXY == "$http_proxy" && $NO_PROXY == example.internal,localhost,127.0.0.1,::1 ]]'\'' || exit 1
    bash "$1/src/bin/xtmoe" proot exec demo -- printf "%s" "two words"
    grep -Fq -- "--env http_proxy=http://127.0.0.1:7890" "$MOCK_LOG" && grep -Fq -- "-- printf %s two words" "$MOCK_LOG" || exit 1
    bash "$1/tests/internal.sh" proxy off
    bash "$1/tests/internal.sh" proxy exec -- bash -c '\''[[ ! ${http_proxy+x} && ! ${ALL_PROXY+x} ]]'\'' || exit 1
    bash "$1/tests/internal.sh" proxy on
    status=$(bash "$1/tests/internal.sh" proxy status) || exit 1
    [[ $status == *已启用* ]] || exit 1
    bash "$1/tests/internal.sh" proxy reset
    [[ ! -e $XTMOE_CONFIG_DIR/proxy.conf ]] || exit 1
    bash "$1/tests/internal.sh" proxy exec -- bash -c '\''[[ $http_proxy == http://parent.example:3128 ]]'\''
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy configuration treats credentials as data and status never prints them' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-credentials"
    url="http://tester:secret%25value@127.0.0.1:7890"
    proxy_write 1 "$url" localhost || exit 1
    proxy_load || exit 1
    [[ $http_proxy == "$url" ]] || exit 1
    output=$(proxy_status) || exit 1
    [[ $output != *tester* && $output != *secret* && $output == *"***@127.0.0.1:7890"* ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy parser rejects unknown keys, duplicate keys and shell payloads without executing them' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-invalid"; mkdir -p "$XTMOE_CONFIG_DIR"
    marker="$2/proxy-executed"
    printf "version=1\nenabled=1\nurl=http://127.0.0.1:7890\nno_proxy=localhost\nenabled=0\n" >"$XTMOE_CONFIG_DIR/proxy.conf"
    if proxy_load; then exit 1; fi
    printf '\''version=1\nenabled=1\nurl=$(touch "%s")\nno_proxy=localhost\n'\'' "$marker" >"$XTMOE_CONFIG_DIR/proxy.conf"
    if proxy_load; then exit 1; fi
    [[ ! -e $marker ]] || exit 1
    printf "version=1\nenabled=0\nurl=\nno_proxy=localhost\nPATH=/bad\n" >"$XTMOE_CONFIG_DIR/proxy.conf"
    if proxy_load; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy validates protocols, IPv6, ports and line injection without overwriting valid configuration' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-validation"
    proxy_write 1 http://127.0.0.1:7890 localhost || exit 1
    for url in socks5://127.0.0.1:1080 http://127.0.0.1:0 http://127.0.0.1:65536 http://host/path http://host?query; do
        if proxy_write 1 "$url" localhost; then exit 1; fi
    done
    if proxy_write 1 $'\''http://127.0.0.1:7890\nPATH=/bad'\'' localhost; then exit 1; fi
    proxy_read || exit 1
    [[ $XTMOE_PROXY_URL == http://127.0.0.1:7890 ]] || exit 1
    proxy_validate_url "https://[::1]:7890" && proxy_validate_url http://proxy.example:3128
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy writer and reader refuse symbolic links without altering the linked file' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-links"; mkdir -p "$XTMOE_CONFIG_DIR"
    printf original >"$2/proxy-outside"
    ln -s "$2/proxy-outside" "$XTMOE_CONFIG_DIR/proxy.conf"
    if proxy_write 0 "" localhost; then exit 1; fi
    if proxy_read; then exit 1; fi
    [[ $(<"$2/proxy-outside") == original ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy real-request test forces the proxy, hides credentials and preserves curl failures' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-request-test"
    proxy_write 1 http://user:private@127.0.0.1:7890 "*" || exit 1
    curl() {
        [[ $1 != --version ]] || return 0
        [[ $1 == --proxy && $2 == http://user:private@127.0.0.1:7890 && $3 == --noproxy && -z $4 ]] || return 9
        [[ ${CURL_TEST_FAILURE:-0} == 0 ]] && return 0
        printf "sensitive user:private error\n" >&2; return 7
    }
    output=$(proxy_test https://example.com) || exit 1
    [[ $output == *ICMP/ping* && $output == *Android/VPN* ]] || exit 1
    CURL_TEST_FAILURE=1
    result=0; output=$(proxy_test https://example.com 2>&1) || result=$?
    [[ $result == 7 && $output != *private* && $output != *sensitive* ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy help and status distinguish persistent HTTP configuration from ICMP routing' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-icmp-guidance"
    output=$(proxy_help) || exit 1
    [[ $output == *ICMP* && $output == *"连通测试"* ]] || exit 1
    [[ $output == *"不关闭 Android VPN"* && $output == *"reset 是删除保存配置"* ]] || exit 1
    output=$(proxy_status) || exit 1
    [[ $output == *未保存配置* && $output == *ICMP/ping* && $output == *Android/VPN* && $output == *"不会关闭 Android VPN"* ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy off and reset report their explicit-proxy scope without promising to stop the Android VPN or change the parent shell' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-off-scope"
    require_termux() { :; }; proxy_sync_chroots() { :; }
    export http_proxy=http://parent.example:3128
    output=$(proxy_main off) || exit 1
    [[ $output == *"仅关闭 XTMOE 显式代理"* && $output == *"父 Shell 不会被修改"* ]] || exit 1
    [[ $http_proxy == http://parent.example:3128 ]] || exit 1
    proxy_read || exit 1
    [[ $XTMOE_PROXY_ENABLED == 0 ]] || exit 1
    output=$(proxy_main reset) || exit 1
    [[ $output == *"reset 不等于关闭代理"* && $output == *"Android VPN 仍开启"* ]] || exit 1
    [[ $http_proxy == http://parent.example:3128 && ! -e $XTMOE_CONFIG_DIR/proxy.conf ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Chroot network diagnostics bound local DNS and distinguish failed ICMP from successful proxy requests' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_exec() { eval "$5"; }
    cat() { :; }
    dpkg() { printf arm64; }
    timeout() {
        case "$2" in
            getent) [[ $1 == 15 && $3 == ahostsv4 ]] || return 99; printf "DNS_TIMEOUT_BOUND\n"; return 124 ;;
            ping) [[ $1 == 10 && $3 == -4 && $4 == -n ]] || return 99; printf "ICMP_TIMEOUT_BOUND\n"; return 1 ;;
            docker) return 1 ;;
            *) shift; "$@" ;;
        esac
    }
    curl() { return "${HTTP_TEST_FAILURE:-0}"; }
    ping() { return 1; }
    ip() { :; }; ss() { :; }; docker() { return 1; }; systemctl() { :; }
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY
    export https_proxy=http://127.0.0.1:7890
    output=$(chroot_network_check ubuntu) || exit 1
    [[ $output == *"local_failed=1; ICMP: failed; HTTP/HTTPS: failures=0"* && $output == *"Summary: failures=0"* && $output == *不会自动绕过* ]] || exit 1
    [[ $output == *DNS_TIMEOUT_BOUND* && $output == *ICMP_TIMEOUT_BOUND* ]] || exit 1
    unset https_proxy
    if chroot_network_check ubuntu >/dev/null; then exit 1; fi
    export https_proxy=http://127.0.0.1:7890 HTTP_TEST_FAILURE=7
    if chroot_network_check ubuntu >/dev/null; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy test distinguishes a broken curl runtime before attempting a proxy connection' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"
    XTMOE_CONFIG_DIR="$2/proxy-broken-curl"
    proxy_write 1 http://127.0.0.1:7890 localhost || exit 1
    curl() { [[ $1 == --version ]] || exit 9; return 1; }
    result=0; output=$(proxy_test 2>&1) || result=$?
    [[ $result == 1 && $output == *"curl 本身无法运行"* ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy live sync keeps stopped containers stopped and reports partial Root or direct-mode failures' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/proxy.sh"; source "$1/src/lib/chroot.sh"
    proxy_sync_log="$2/proxy-sync"; root_state=ready; runtime_mode=systemd
    manager_chroot_names() { printf "one\ntwo\n"; }
    root_available() { [[ $root_state == ready ]]; }
    chroot_root() { if [[ $3 == two ]]; then printf stopped; else printf "%s" "$runtime_mode"; fi; }
    chroot_systemd_exec() { [[ $6 == _ && $7 == apply ]] || return 1; printf "%s\n" "$1" >>"$proxy_sync_log"; }
    chroot_systemd_network_refresh() { :; }
    chroot_systemd_start() { exit 9; }
    proxy_sync_chroots || exit 1
    [[ $(<"$proxy_sync_log") == one ]] || exit 1
    runtime_mode=direct-docker
    if proxy_sync_chroots; then exit 1; fi
    root_state=missing
    if proxy_sync_chroots; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Proxy apply restarts active Docker only on a changed managed file, and off removes only its file' bash -c '
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    fixture="$2/proxy-apply-daemon"; mkdir -p "$fixture"
    script=$(chroot_docker_proxy_script); script=${script//\/etc\/systemd\/system/$fixture}
    PROXY_APPLY_LOG="$fixture/systemctl"; PROXY_DAEMON_ACTIVE=1; export PROXY_APPLY_LOG PROXY_DAEMON_ACTIVE
    systemctl() { printf "%s\n" "$*" >>"$PROXY_APPLY_LOG"; [[ $1 != is-active || $PROXY_DAEMON_ACTIVE == 1 ]]; }; export -f systemctl
    http_proxy=http://127.0.0.1:7890 bash -c "$script" _ apply || exit 1
    http_proxy=http://127.0.0.1:7890 bash -c "$script" _ apply || exit 1
    [[ $(grep -c "^restart docker.service$" "$PROXY_APPLY_LOG") == 1 ]] || exit 1
    PROXY_DAEMON_ACTIVE=0
    http_proxy=http://127.0.0.1:7891 bash -c "$script" _ apply || exit 1
    [[ $(grep -c "^restart docker.service$" "$PROXY_APPLY_LOG") == 1 ]] || exit 1
    PROXY_DAEMON_ACTIVE=1
    bash -c "$script" _ apply || exit 1
    [[ ! -e $fixture/docker.service.d/90-xtmoe-proxy.conf && $(grep -c "^restart docker.service$" "$PROXY_APPLY_LOG") == 2 ]]
' _ "$ROOT_DIR" "$TEST_TMP"
