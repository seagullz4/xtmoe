#!/usr/bin/env bash
# Sourced by run.sh. No real container or host account is changed.
assert_ok 'PRoot SSH validates high ports and blank/invalid prompts' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    for port in 1024 2222 65535; do proot_ssh_valid_port "$port" || exit 1; done
    for port in 0 22 1023 65536 02222 "2222;id"; do if proot_ssh_valid_port "$port"; then exit 1; fi; done
    [[ $(proot_ssh_prompt_port <<<"") == auto && $(printf "bad\n22\n22222\n" | proot_ssh_prompt_port) == 22222 ]] || exit 1
    if proot_ssh_prompt_port </dev/null; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'PRoot SSH random allocation excludes other installed container reservations' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    port=$(proot_ssh_choose_port auto allocation-first); proot_ssh_valid_port "$port"
    directory="$PREFIX/var/lib/proot-distro/containers/allocation-first/rootfs/etc/ssh"; mkdir -p "$directory"
    printf "Port %s\n" "$port" >"$directory/xtmoe-ssh.conf"
    if proot_ssh_choose_port "$port" allocation-second; then exit 1; fi
    other=$(proot_ssh_choose_port auto allocation-second)
    proot_ssh_valid_port "$other" && [[ $other != "$port" ]]
' _ "$ROOT_DIR"

assert_ok 'PRoot SSH checks a real occupied host TCP port without stealing it' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    python=$(proot_ssh_python); fixture="$2/ssh-port-socket"
    "$python" - "$fixture" <<'"'"'PY'"'"' &
import pathlib,socket,sys,time
p=pathlib.Path(sys.argv[1])
with socket.socket() as s:
    s.bind(("0.0.0.0",0)); s.listen()
    p.write_text(str(s.getsockname()[1]))
    for _ in range(300):
        if p.with_suffix(".done").exists(): break
        time.sleep(0.1)
PY
    server=$!; trap '\''touch "$fixture.done"; wait "$server" || true'\'' EXIT
    for attempt in 1 2 3 4 5; do [[ ! -f $fixture ]] || break; sleep "$attempt"; done
    port=$(<"$fixture")
    if proot_ssh_choose_port "$port" another-container; then exit 1; fi
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'PRoot SSH prompts retry an occupied selection and accept a free custom port' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    proot_ssh_choose_port() { [[ $1 != 22222 ]] || return 1; printf "%s" "$1"; }
    [[ $(printf "22222\n23333\n" | proot_ssh_prompt_port demo) == 23333 ]]
' _ "$ROOT_DIR"

for ssh_phase in success install-fail setup-fail start-fail; do
    assert_ok "PRoot install SSH ordering and error propagation: $ssh_phase" bash -c '
        set -Eeuo pipefail
        source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
        log="$2/proot-install-$3"; phase=$3
        native_proot_arch() { printf aarch64; }; proot_exists() { return 1; }
        proot_ssh_lock() { exec {PROOT_SSH_LOCK_FD}>"${log}.lock"; }
        proot_ssh_choose_port() { [[ $1 == auto && $2 == demo ]]; printf 24333; }
        proot-distro() { printf "%s\n" "--name --architecture"; }
        timeout() { printf "install\n" >>"$log"; [[ $phase != install-fail ]] || return 41; }
        proot_ssh_initialize() { [[ $* == "demo 24333" ]]; printf "setup\n" >>"$log"; [[ $phase != setup-fail ]] || return 42; }
        proot_ssh_start_locked() { printf "start\n" >>"$log"; [[ $phase != start-fail ]] || return 43; }
        if proot_install ubuntu:24.04 demo --ssh-port auto; then result=0; else result=$?; fi
        case "$phase" in
            success) [[ $result == 0 && $(tr "\n" " " <"$log") == "install setup start " ]] ;;
            install-fail) [[ $result == 41 && $(<"$log") == install ]] ;;
            setup-fail) [[ $result != 0 && $(tr "\n" " " <"$log") == "install setup " ]] ;;
            start-fail) [[ $result != 0 && $(tr "\n" " " <"$log") == "install setup start " ]] ;;
        esac
    ' _ "$ROOT_DIR" "$TEST_TMP" "$ssh_phase"
done

assert_ok 'PRoot SSH background login closes the parent lock descriptor' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    exec {PROOT_SSH_LOCK_FD}>"$2/proot-ssh-fd"
    proot-distro() { [[ ! -e /proc/self/fd/$PROOT_SSH_LOCK_FD ]]; }
    proot_login demo --detach -- /bin/true
    printf parent-still-open >&"$PROOT_SSH_LOCK_FD"
    exec {PROOT_SSH_LOCK_FD}>&-
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'PRoot SSH does not report a listener ready without its managed session' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    proot_ssh_port() { printf 23333; }; proot_ssh_session_count() { printf 0; }
    proot_ssh_ready() { exit 9; }
    [[ $(proot_ssh_status demo) == *SSH=stopped ]]
' _ "$ROOT_DIR"

assert_ok 'PRoot SSH parser rejects duplicate, invalid and linked port configuration' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    directory="$PREFIX/var/lib/proot-distro/containers/parse-ssh/rootfs/etc/ssh"; mkdir -p "$directory"
    file="$directory/xtmoe-ssh.conf"
    printf "Port 22222\n" >"$file"; [[ $(proot_ssh_port parse-ssh) == 22222 ]]
    printf "Port 22222\nPort 23333\n" >"$file"; if proot_ssh_port parse-ssh; then exit 1; fi
    printf "Port 22\n" >"$file"; if proot_ssh_port parse-ssh; then exit 1; fi
    mv "$file" "$file.real"; ln -s "$file.real" "$file"
    if proot_ssh_port parse-ssh; then exit 1; fi
' _ "$ROOT_DIR"

assert_ok 'PRoot install rejects malformed SSH options before running upstream' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"
    native_proot_arch() { printf arm64; }; proot_exists() { return 1; }
    proot_ssh_lock() { :; }; proot-distro() { exit 9; }
    for args in "--ssh-port" "--ssh-port auto --ssh-port auto" "--invalid"; do
        if (proot_install $args); then exit 1; fi
    done
' _ "$ROOT_DIR"

assert_ok 'PRoot session detection reads stdout or stderr tables without truncating commands' bash -c '
    set -Eeuo pipefail
    source "$1/src/lib/common.sh"; source "$1/src/lib/proot.sh"; source "$1/src/lib/manager.sh"
    proot-distro() { [[ $COLUMNS == 4096 && $PD_FORCE_NO_COLORS == 1 ]]; printf "PID CONTAINER TYPE USER UPTIME COMMAND\n123 demo login* root 0m /usr/sbin/sshd -D -f /etc/ssh/xtmoe-ssh.conf\n" >&2; }
    [[ $(proot_session_count demo) == 1 && $(proot_ssh_session_count demo) == 1 && $(manager_proot_sessions) == "demo 1" ]]
' _ "$ROOT_DIR"
