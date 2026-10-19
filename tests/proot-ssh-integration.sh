#!/usr/bin/env bash
# Real rootless PRoot/OpenSSH test, confined to the disposable CI Docker image.
set -Eeuo pipefail
[[ -f /.dockerenv && -d /workspace/src ]] || { printf 'Disposable CI container required.\n' >&2; exit 1; }
if [[ $(id -u) == 0 ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 update
    apt-get install -y --no-install-recommends python3 git ca-certificates build-essential gcc-multilib libtalloc-dev util-linux openssh-client sshpass
    # Ubuntu's old generic proot does not implement Termux's virtual permission
    # extensions. Build the exact source tag used by official Termux packaging.
    git clone https://github.com/termux/proot.git /opt/termux-proot
    git -C /opt/termux-proot checkout --detach e2d843ee6dab076ea0ed1ffd5d0ea12232185499
    make -C /opt/termux-proot/src -j2
    install -m 0755 /opt/termux-proot/src/proot /usr/local/bin/proot
    git clone https://github.com/termux/proot-distro.git /opt/proot-distro
    git -C /opt/proot-distro checkout --detach 5a427a1f924550c176ab34197e9fcf5d010fdbd9
    printf '#!/bin/sh\nexec python3 /opt/proot-distro/proot-distro.py "$@"\n' >/usr/local/bin/proot-distro
    chmod 0755 /usr/local/bin/proot-distro
    useradd -m -u 10551 xtmoe-ci
    runuser -u xtmoe-ci -- env HOME=/home/xtmoe-ci NO_COLOR=1 PD_PROOT_BIN=/usr/local/bin/proot bash "$0" --guest
    exit
fi
[[ ${1:-} == --guest && $(id -u) != 0 ]]
export PREFIX="$HOME/files/usr" XTMOE_HOME="$HOME"
export XTMOE_CONFIG_DIR="$HOME/.config/xtmoe" XTMOE_DATA_DIR="$HOME/.local/share/xtmoe" XTMOE_CACHE_DIR="$HOME/.cache/xtmoe"
export XDG_DATA_HOME="$PREFIX/var/lib"
mkdir -p "$PREFIX/bin" "$XDG_DATA_HOME"
source /workspace/src/lib/common.sh
source /workspace/src/lib/proot.sh
cleanup() { proot-distro kill ssh-ci >/dev/null 2>&1 || true; }
trap cleanup EXIT
proot_install ubuntu:24.04 ssh-ci --ssh-port auto
port=$(proot_ssh_port ssh-ci)
proot_ssh_valid_port "$port"
[[ $(proot_ssh_status ssh-ci) == *SSH=running ]]
connect() {
    sshpass -p "$1" ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=5 root@127.0.0.1 id -u
}
[[ $(connect 123456) == 0 ]]
if connect incorrect-password; then exit 1; fi
proot_login ssh-ci -- /bin/sh -c 'printf "root:changed-in-proot-test-only\n" | chpasswd'
proot-distro kill ssh-ci
[[ $(proot_ssh_status ssh-ci) == *SSH=stopped ]]
proot_ssh_initialize ssh-ci "$port"
proot_ssh_start ssh-ci
[[ $(connect changed-in-proot-test-only) == 0 ]]
if connect 123456; then exit 1; fi
proot-distro kill ssh-ci
if proot_ssh_ready "$port"; then exit 1; fi
printf 'ROOTLESS_PROOT_RANDOM_PORT_PASSWORD_LOGIN_RESTART_AND_STOP_OK\n'
