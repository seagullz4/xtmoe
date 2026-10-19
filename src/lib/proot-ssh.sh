#!/usr/bin/env bash
# PRoot shares the Android network. Ports are host TCP ports, not NAT mappings.

proot_ssh_python() {
    local candidate
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null && "$candidate" -c 'import socket' >/dev/null 2>&1; then
            printf '%s' "$candidate"; return 0
        fi
    done
    die 'SSH 端口检测需要 Python，请执行 pkg install python'
}

proot_ssh_valid_port() { [[ $1 =~ ^[1-9][0-9]{3,4}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }

proot_ssh_lock() {
    mkdir -p "$XTMOE_CONFIG_DIR"
    [[ ! -L $XTMOE_CONFIG_DIR/proot-ssh.lock ]] || die 'PRoot SSH 锁不能是链接'
    exec {PROOT_SSH_LOCK_FD}>"$XTMOE_CONFIG_DIR/proot-ssh.lock"
    flock -n "$PROOT_SSH_LOCK_FD" || die '另一项 PRoot SSH 配置/安装正在进行，请稍后重试'
}

proot_ssh_port() {
    local directory file port
    directory=$(proot_container_dir "$1") || return 1
    file="$directory/rootfs/etc/ssh/xtmoe-ssh.conf"
    [[ -f $file && ! -L $file ]] || return 1
    port=$(awk '$1=="Port" {print $2; count++} END {if(count!=1) exit 1}' "$file") || return 1
    proot_ssh_valid_port "$port" || return 1
    printf '%s' "$port"
}

proot_ssh_choose_port() {
    local requested=${1:-auto} name=$2 directory other port reserved='' python
    [[ $requested == auto ]] || proot_ssh_valid_port "$requested" || { warn 'SSH 端口必须为1024至65535的整数，留空/auto随机选择'; return 1; }
    for directory in "$PREFIX/var/lib/proot-distro/containers"/* "$PREFIX/var/lib/proot-distro/installed-rootfs"/*; do
        [[ -d $directory/rootfs ]] || continue
        other=${directory##*/}; [[ $other != "$name" ]] || continue
        if port=$(proot_ssh_port "$other"); then reserved+="$port "; fi
    done
    python=$(proot_ssh_python) || return 1
    "$python" - "$requested" "$reserved" <<'PORT_PROBE'
import socket
import sys

requested, reserved = sys.argv[1], set(sys.argv[2].split())
for _ in range(128 if requested == "auto" else 1):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("0.0.0.0", 0 if requested == "auto" else int(requested)))
            port = sock.getsockname()[1]
        except OSError:
            continue
        if port >= 1024 and str(port) not in reserved:
            print(port)
            sys.exit(0)
print("SSH端口被占用、被其他容器预留或无法绑定，请重新选择。", file=sys.stderr)
sys.exit(1)
PORT_PROBE
}

proot_ssh_prompt_port() {
    local value name=${1:-} selected
    while true; do
        printf 'SSH连接端口（1024-65535，回车随机选择未使用端口）：' >&2
        IFS= read -r value || return 1
        value=${value:-auto}
        if [[ $value == auto ]] || proot_ssh_valid_port "$value"; then
            if [[ -z $name ]]; then printf '%s' "$value"; return 0; fi
            if selected=$(proot_ssh_choose_port "$value" "$name"); then printf '%s' "$selected"; return 0; fi
            continue
        fi
        warn '请输入1024至65535的整数。'
    done
}

proot_ssh_guest_script() {
    cat <<'PROOT_SSH_GUEST'
set -eu
port=$1
case "$port" in ''|*[!0-9]*) exit 1 ;; esac
[ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || exit 1
export DEBIAN_FRONTEND=noninteractive
config=/etc/ssh/xtmoe-ssh.conf
state=/var/lib/xtmoe/proot-ssh
for path in /etc/ssh "$config" /var/lib/xtmoe "$state" "$state/initialized" /run/sshd; do
    [ ! -L "$path" ] || { printf '拒绝链接形式的SSH配置/状态路径\n' >&2; exit 1; }
done
if [ -e "$state/initialized" ]; then [ -f "$state/initialized" ] || exit 1; fi
if ! command -v sshd >/dev/null 2>&1 || ! command -v chpasswd >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || { printf '自动SSH目前要求Ubuntu/Debian apt镜像；容器已保留。\n' >&2; exit 1; }
    policy_dir=$(mktemp -d /usr/sbin/.xtmoe-ssh-policy.XXXXXX)
    if [ -e /usr/sbin/policy-rc.d ] || [ -L /usr/sbin/policy-rc.d ]; then cp -a /usr/sbin/policy-rc.d "$policy_dir/original"; fi
    cleanup_policy() {
        if [ -e "$policy_dir/original" ] || [ -L "$policy_dir/original" ]; then mv -Tf "$policy_dir/original" /usr/sbin/policy-rc.d
        else rm -f /usr/sbin/policy-rc.d; fi
        rm -f "$policy_dir/guard"
        rmdir "$policy_dir"
    }
    trap cleanup_policy EXIT
    printf '#!/bin/sh\nexit 101\n' >"$policy_dir/guard"
    chmod 0755 "$policy_dir/guard"
    mv -Tf "$policy_dir/guard" /usr/sbin/policy-rc.d
    apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=1 update
    apt-get install -y --no-install-recommends openssh-server passwd
fi
mkdir -p "$state" /run/sshd
chmod 0700 "$state"
chmod 0755 /run/sshd
ssh-keygen -A
temporary=$(mktemp /etc/ssh/.xtmoe-proot-ssh.XXXXXX)
printf '%s\n' '# XTMOE PRoot SSH' "Port $port" 'AddressFamily inet' 'ListenAddress 0.0.0.0' \
    'HostKey /etc/ssh/ssh_host_ed25519_key' 'PermitRootLogin yes' 'PasswordAuthentication yes' \
    'PermitEmptyPasswords no' 'KbdInteractiveAuthentication no' 'AuthenticationMethods any' \
    'UsePAM no' 'PidFile /run/xtmoe-proot-ssh.pid' 'Subsystem sftp internal-sftp' >"$temporary"
chmod 0600 "$temporary"
if ! /usr/sbin/sshd -t -f "$temporary"; then rm -f "$temporary"; exit 1; fi
mv -Tf "$temporary" "$config"
if [ ! -e "$state/initialized" ]; then
    printf 'root:123456\n' | chpasswd
    (umask 077; printf '1\n' >"$state/initialized")
fi
PROOT_SSH_GUEST
}

proot_ssh_initialize() {
    local name=$1 port=$2
    proot_login "$name" -- /bin/sh -lc "$(proot_ssh_guest_script)" _ "$port"
}

proot_ssh_session_count() {
    local name=$1
    COLUMNS=4096 PD_FORCE_NO_COLORS=1 proot-distro ps 2>&1 | awk -v name="$name" '$1 ~ /^[0-9]+$/ && $2==name && index($0,"xtmoe-ssh.conf") {count++} END {print count+0}'
}

proot_ssh_ready() {
    local port=$1 python
    python=$(proot_ssh_python) || return 1
    "$python" - "$port" <<'SSH_PROBE'
import socket
import sys
try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2) as sock:
        sock.settimeout(2)
        if sock.recv(256).startswith(b"SSH-2.0-"):
            sys.exit(0)
except OSError:
    pass
sys.exit(1)
SSH_PROBE
}

proot_ssh_start_locked() {
    local name=$1 port count help attempt directory
    directory=$(proot_container_dir "$name") || return 1
    [[ -f $directory/rootfs/var/lib/xtmoe/proot-ssh/initialized && ! -L $directory/rootfs/var/lib/xtmoe/proot-ssh/initialized ]] || die 'SSH初始化未完成，请先通过向导重新配置SSH'
    port=$(proot_ssh_port "$name") || die '此容器尚未配置SSH，请从PRoot运行管理选择配置SSH'
    count=$(proot_ssh_session_count "$name") || return 1
    if ((count > 0)); then
        proot_ssh_ready "$port" || { warn 'SSH会话存在但未就绪；请查看容器/var/log/xtmoe-ssh.log'; return 1; }
        ok "PRoot SSH 已运行：root@手机IP:$port"; return 0
    fi
    proot_ssh_choose_port "$port" "$name" >/dev/null || return 1
    help=$(PD_FORCE_NO_COLORS=1 proot-distro login --help 2>&1) || return 1
    [[ $help == *--detach* ]] || die 'SSH后台会话要求新版proot-distro --detach，请先执行 pkg upgrade proot-distro'
    proot_login "$name" --detach -- /bin/sh -lc 'mkdir -p /run/sshd; exec /usr/sbin/sshd -D -e -f /etc/ssh/xtmoe-ssh.conf >>/var/log/xtmoe-ssh.log 2>&1' || return 1
    for attempt in 1 2 3 4 5; do
        count=$(proot_ssh_session_count "$name") || return 1
        if ((count > 0)) && proot_ssh_ready "$port"; then
            ok "PRoot SSH 已启动：ssh -p $port root@手机当前局域网IP"
            return 0
        fi
        sleep "$attempt"
    done
    proot_login "$name" -- /bin/sh -lc 'tail -n 20 /var/log/xtmoe-ssh.log 2>/dev/null || true' >&2 || true
    warn 'SSH未能启动；容器已保留，请检查/var/log/xtmoe-ssh.log或重新配置SSH端口'
    return 1
}

proot_ssh_start() (
    require_arg_range 1 1 "$#" 'xtmoe on → PRoot → 启动SSH'
    require_name "$1"; proot_ssh_lock
    proot_ssh_start_locked "$1"
)

proot_ssh_configure() (
    local name=$1 requested=${2:-auto} port
    require_arg_range 1 2 "$#" 'xtmoe on → PRoot → 配置SSH端口'
    require_name "$name"; proot_ssh_lock
    [[ $(proot_session_count "$name") == 0 ]] || die '请先停止此容器活动会话，再更改SSH配置'
    port=$(proot_ssh_choose_port "$requested" "$name") || return 1
    proot_ssh_initialize "$name" "$port" || return 1
    proot_ssh_start_locked "$name"
)

proot_ssh_status() {
    local name=$1 port count
    require_arg_range 1 1 "$#" 'xtmoe on → PRoot → SSH状态'
    require_name "$name"
    port=$(proot_ssh_port "$name") || { printf 'SSH=not-configured\n'; return 0; }
    printf 'SSH user=root port=%s\n' "$port"
    count=$(proot_ssh_session_count "$name") || return 1
    if ((count > 0)) && proot_ssh_ready "$port"; then printf 'SSH=running\n'
    elif ((count > 0)); then printf 'SSH=not-ready\n'; return 1
    else printf 'SSH=stopped\n'; fi
}
