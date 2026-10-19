#!/usr/bin/env bash
# Sourced by run.sh; no host account, password or service is changed.

assert_ok 'Fresh Chroot metadata requests initial SSH credentials' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_meta_initialize ssh-new 24.04 arm64 yes
    [[ $(chroot_meta_get ssh-new ssh_initialization) == pending ]]
' _ "$ROOT_DIR"

assert_ok 'SSH setup waits for packages, checks the service and never reinitializes on repair' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    log="$2/ssh-order"; mkdir -p "$(chroot_base)/ssh-order"; touch "$(chroot_base)/ssh-order/.xtmoe-chroot"
    chroot_meta_initialize ssh-order 24.04 arm64 no
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }
    chroot_setup() { printf "packages\n" >>"$log"; }
    chroot_ssh_initialize() { [[ $2 == 1 ]]; printf "credentials\n" >>"$log"; }
    chroot_use_bash_sh() { :; }; chroot_systemd_verify() { :; }
    chroot_systemd_start() { printf "systemd\n" >>"$log"; }
    chroot_systemd_exec() { [[ $* == *"systemctl start ssh.service"* ]]; printf "ssh-service\n" >>"$log"; }
    chroot_bootstrap ssh-order --skip-docker
    [[ $(tr "\n" " " <"$log") == "packages credentials systemd ssh-service " ]] || exit 1
    [[ $(chroot_meta_get ssh-order ssh_initialization) == ready ]] || exit 1
    chroot_ssh_initialize() { exit 9; }; chroot_systemd_exec() { exit 9; }
    chroot_repair ssh-order
    [[ $(chroot_meta_get ssh-order ssh_initialization) == ready ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'SSH initialization failure preserves pending state and blocks systemd' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_meta_initialize ssh-fail 24.04 arm64 no
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }; chroot_setup() { :; }
    chroot_ssh_initialize() { return 43; }; chroot_systemd_start() { exit 9; }
    if chroot_bootstrap ssh-fail --skip-docker; then exit 1; fi
    [[ $(chroot_meta_get ssh-fail failed_stage) == ssh && $(chroot_meta_get ssh-fail ssh_initialization) == pending ]]
' _ "$ROOT_DIR"

assert_ok 'SSH service failure is reported separately and retries without resetting credentials' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_meta_set ssh-service-fail ssh_initialization prepared
    chroot_systemd_exec() { return 42; }
    if chroot_initial_ssh_service ssh-service-fail; then exit 1; fi
    [[ $(chroot_meta_get ssh-service-fail failed_stage) == ssh-service && $(chroot_meta_get ssh-service-fail ssh_initialization) == prepared ]] || exit 1
    chroot_ssh_initialize() { exit 9; }; chroot_initial_ssh ssh-service-fail
    chroot_systemd_exec() { return 0; }; chroot_initial_ssh_service ssh-service-fail
    [[ $(chroot_meta_get ssh-service-fail ssh_initialization) == ready ]]
' _ "$ROOT_DIR"

assert_ok 'Basic fresh Chroot configures SSH credentials without systemd service changes' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    chroot_meta_initialize ssh-basic 24.04 arm64 no
    chroot_meta_set ssh-basic systemd_requested 0
    chroot_apply_dns() { :; }; chroot_network_preflight() { :; }
    chroot_ssh_initialize() { [[ $2 == 0 ]]; }; chroot_systemd_start() { exit 9; }
    chroot_basic_repair ssh-basic
    [[ $(chroot_meta_get ssh-basic ssh_initialization) == ready ]]
' _ "$ROOT_DIR"

for ssh_fault in none config effective password service; do
    assert_ok "Initial SSH guest policy, one-time password and failure handling: $ssh_fault" bash -c '
        set -Eeuo pipefail
        source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
        fixture="$2/ssh-guest-$3"; mkdir -p "$fixture/etc/ssh" "$fixture/var/lib/xtmoe" "$fixture/run"
        printf "# image default\nPermitRootLogin prohibit-password\nPasswordAuthentication no\n" >"$fixture/etc/ssh/sshd_config"
        script=$(chroot_ssh_initial_script)
        script=${script//\/etc\/ssh/$fixture/etc/ssh}
        script=${script//\/var\/lib\/xtmoe/$fixture/var/lib/xtmoe}
        script=${script//\/run\/sshd/$fixture/run/sshd}
        export SSH_TEST_FIXTURE=$fixture SSH_TEST_FAULT=$3
        # Git Bash cannot represent Linux directory modes; Linux CI and the
        # disposable Ubuntu integration test exercise the real install command.
        if [[ $(uname -s) == MINGW* || $(uname -s) == MSYS* ]]; then
            install() { shift 3; mkdir -p "$@"; }; export -f install
        fi
        ssh-keygen() { printf "keys\n" >>"$SSH_TEST_FIXTURE/events"; }
        sshd() {
            printf "sshd %s\n" "$1" >>"$SSH_TEST_FIXTURE/events"
            case "$1" in
                -t) [[ $SSH_TEST_FAULT != config ]] ;;
                -T)
                    printf "%s\n" "permitrootlogin yes" "permitemptypasswords no" "authenticationmethods any"
                    if [[ $SSH_TEST_FAULT == effective ]]; then printf "passwordauthentication no\n"; else printf "passwordauthentication yes\n"; fi
                    ;;
                *) return 1 ;;
            esac
        }
        chpasswd() { cat >"$SSH_TEST_FIXTURE/password-input"; [[ $SSH_TEST_FAULT != password ]]; }
        systemctl() { printf "%s\n" "$*" >>"$SSH_TEST_FIXTURE/service"; [[ $SSH_TEST_FAULT != service ]]; }
        export -f ssh-keygen sshd chpasswd systemctl
        if bash -c "$script" _ 1; then result=0; else result=$?; fi
        marker="$fixture/var/lib/xtmoe/ssh/initialized"
        if [[ $3 != none ]]; then
            [[ $result != 0 && ! -e $marker ]] || exit 1
            if [[ $3 == config || $3 == effective || $3 == service ]]; then [[ ! -e $fixture/password-input ]] || exit 1; fi
            case "$3" in
                config) grep -qx "sshd -t" "$fixture/events" ;;
                effective) grep -qx "sshd -T" "$fixture/events" ;;
                password) [[ $(<"$fixture/password-input") == root:123456 ]] ;;
                service) [[ $(<"$fixture/service") == "enable ssh.service" ]] ;;
            esac
            exit 0
        fi
        [[ $result == 0 && -f $marker && $(<"$fixture/password-input") == root:123456 ]] || exit 1
        [[ $(head -n 1 "$fixture/etc/ssh/sshd_config") == "Include $fixture/etc/ssh/xtmoe-initial.conf" ]] || exit 1
        [[ $(<"$fixture/service") == "enable ssh.service" ]] || exit 1
        printf user-changed-password >"$fixture/password-input"
        printf "# user config\n" >>"$fixture/etc/ssh/sshd_config"
        config_hash=$(sha256sum "$fixture/etc/ssh/sshd_config")
        bash -c "$script" _ 1
        [[ $(<"$fixture/password-input") == user-changed-password && $(sha256sum "$fixture/etc/ssh/sshd_config") == "$config_hash" ]]
    ' _ "$ROOT_DIR" "$TEST_TMP" "$ssh_fault"
done

assert_ok 'SSH guest initializer refuses linked configuration before changing a password' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    fixture="$2/ssh-linked"; mkdir -p "$fixture/etc/ssh" "$fixture/var/lib/xtmoe" "$fixture/run"
    printf keep >"$fixture/original"; ln -s "$fixture/original" "$fixture/etc/ssh/sshd_config"
    script=$(chroot_ssh_initial_script)
    script=${script//\/etc\/ssh/$fixture/etc/ssh}; script=${script//\/var\/lib\/xtmoe/$fixture/var/lib/xtmoe}; script=${script//\/run\/sshd/$fixture/run/sshd}
    if bash -c "$script" _ 1; then exit 1; fi
    [[ $(<"$fixture/original") == keep && ! -e $fixture/var/lib/xtmoe/ssh/initialized ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'SSH package failure blocks all account and configuration initialization' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"
    export SSH_PACKAGE_TEST_LOG="$2/ssh-package-must-not-initialize"
    chroot_apt_guard_script() { printf "set -Eeuo pipefail\n"; }
    chroot_ssh_initial_script() { printf '\''printf forbidden >"$SSH_PACKAGE_TEST_LOG"\n'\''; }
    command() { if [[ $* == "-v sshd" ]]; then return 1; else builtin command "$@"; fi; }
    apt-get() { return 37; }; export -f command apt-get
    chroot_exec() { bash -c "$5" _ "$7"; }
    if chroot_ssh_initialize fixture 1; then exit 1; else result=$?; fi
    [[ $result == 37 && ! -e $SSH_PACKAGE_TEST_LOG ]]
' _ "$ROOT_DIR" "$TEST_TMP"
