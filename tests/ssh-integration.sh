#!/usr/bin/env bash
# Run only in the CI's disposable Ubuntu container, never on an Android/host OS.
set -Eeuo pipefail
[[ -f /.dockerenv && $(id -u) == 0 && -d /workspace/src ]] || {
    printf 'This SSH integration test requires the disposable CI container.\n' >&2
    exit 1
}
export DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends openssh-server openssh-client sshpass systemd passwd
source /workspace/src/lib/chroot.sh
printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' >/etc/ssh/sshd_config.d/50-test-image-defaults.conf
script=$(chroot_ssh_initial_script)
bash -c "$script" _ 1
[[ -f /var/lib/xtmoe/ssh/initialized ]]
[[ -L /etc/systemd/system/multi-user.target.wants/ssh.service ]]
sshd -t
sshd -T -C user=root,host=localhost,addr=127.0.0.1 | grep -x 'permitrootlogin yes'
server=''
cleanup() { if [[ -n $server ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi; }
trap cleanup EXIT
/usr/sbin/sshd -D -e -p 22222 -o ListenAddress=127.0.0.1 >/tmp/ssh-integration-server.log 2>&1 &
server=$!
connect() {
    sshpass -p "$1" ssh -p 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 -o ConnectTimeout=3 root@127.0.0.1 id -u
}
success=0
for attempt in 1 2 3 4 5; do
    printf 'SSH readiness attempt %s\n' "$attempt"
    if [[ $(connect 123456) == 0 ]]; then success=1; break; fi
    sleep 1
done
if ((success == 0)); then cat /tmp/ssh-integration-server.log; exit 1; fi
if connect incorrect-password; then printf 'Incorrect SSH password was accepted.\n' >&2; exit 1; fi
printf 'root:changed-in-disposable-test-only\n' | chpasswd
saved_hash=$(awk -F: '$1=="root" {print $2}' /etc/shadow)
bash -c "$script" _ 1
[[ $(awk -F: '$1=="root" {print $2}' /etc/shadow) == "$saved_hash" ]]
[[ $(connect changed-in-disposable-test-only) == 0 ]]
if connect 123456; then printf 'Initialization reset the changed SSH password.\n' >&2; exit 1; fi
printf 'REAL_SSH_ROOT_PASSWORD_LOGIN_AND_ONE_TIME_INITIALIZATION_OK\n'
