#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

MODE=${1:-doctor}
STAMP=$(date +%Y%m%d%H%M%S)
PROOT_NAME="xtmoe-smoke-p-$STAMP"
CHROOT_NAME="xtmoe-smoke-c-$STAMP"
QEMU_NAME="xtmoe-smoke-q-$STAMP"
RESTORE_NAME="xtmoe-smoke-r-$STAMP"
QEMU_RESTORE_NAME="xtmoe-smoke-qr-$STAMP"
WORK_DIR="${TMPDIR:-$HOME/.cache}/xtmoe-smoke-$STAMP"
BACKUP_FILE="$WORK_DIR/$PROOT_NAME.tar.gz"
CHROOT_BACKUP="$WORK_DIR/$CHROOT_NAME.tar.gz"
QEMU_BACKUP="$WORK_DIR/$QEMU_NAME.tar.gz"
HOST_SHARE="$WORK_DIR/host-share"

say() { printf '%s\n' "$*"; }
die() { printf 'SMOKE FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Android 真机冒烟测试

  bash tests/android-smoke.sh doctor
  bash tests/android-smoke.sh proot
  XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot
  XTMOE_SMOKE_ACCEPT_QEMU_COST=YES bash tests/android-smoke.sh qemu

proot 会创建、备份、恢复并删除一个名称带时间戳的临时容器。
chroot 会执行真实 Root 挂载和删除，仅在明确设置风险确认变量时运行。
qemu 会下载大型 Ubuntu 镜像、创建虚拟机并测试 Docker，仅在明确确认成本时运行。
EOF
}

cleanup_proot() {
    xtmoe proot stop "$PROOT_NAME" >/dev/null 2>&1 || true
    xtmoe proot remove --yes "$PROOT_NAME" >/dev/null 2>&1 || true
}

cleanup_chroot() {
    xtmoe chroot systemd-stop "$CHROOT_NAME" >/dev/null 2>&1 || true
    xtmoe chroot systemd-stop "$RESTORE_NAME" >/dev/null 2>&1 || true
    xtmoe chroot stop "$CHROOT_NAME" >/dev/null 2>&1 || true
    xtmoe chroot stop "$RESTORE_NAME" >/dev/null 2>&1 || true
    xtmoe chroot remove --yes "$CHROOT_NAME" >/dev/null 2>&1 || true
    xtmoe chroot remove --yes "$RESTORE_NAME" >/dev/null 2>&1 || true
}

cleanup_qemu() {
    xtmoe qemu stop --force "$QEMU_NAME" >/dev/null 2>&1 || true
    xtmoe qemu stop --force "$QEMU_RESTORE_NAME" >/dev/null 2>&1 || true
    xtmoe qemu remove --yes "$QEMU_NAME" >/dev/null 2>&1 || true
    xtmoe qemu remove --yes "$QEMU_RESTORE_NAME" >/dev/null 2>&1 || true
}

doctor_test() {
    command -v xtmoe >/dev/null 2>&1 || die '未安装 xtmoe'
    [[ ${PREFIX:-} == */files/usr ]] || die '当前不是 Termux PREFIX'
    [[ $(id -u) -ne 0 ]] || die '请退出 su/tsu 后再运行测试'
    xtmoe version
    xtmoe doctor
    xtmoe proot help >/dev/null
    xtmoe chroot help >/dev/null
    xtmoe qemu help >/dev/null
    say 'SMOKE PASS: doctor/help'
}

qemu_test() {
    [[ ${XTMOE_SMOKE_ACCEPT_QEMU_COST:-} == YES ]] || die 'QEMU 测试需要设置 XTMOE_SMOKE_ACCEPT_QEMU_COST=YES'
    doctor_test
    mkdir -p "$WORK_DIR"
    trap cleanup_qemu EXIT INT TERM
    xtmoe qemu prepare
    XTMOE_QEMU_INTERNAL_NONINTERACTIVE=1 xtmoe qemu install --yes --cpus 1 --memory 2048 --disk-size 12 "$QEMU_NAME"
    xtmoe list --all --no-prompt | grep -Fq "$QEMU_NAME" || die '统一列表没有显示新 QEMU VM'
    xtmoe qemu exec "$QEMU_NAME" -- grep -q '^ID=ubuntu' /etc/os-release
    xtmoe qemu exec "$QEMU_NAME" -- systemctl is-system-running
    xtmoe qemu docker-status "$QEMU_NAME"
    xtmoe qemu docker-test "$QEMU_NAME"
    xtmoe qemu stop "$QEMU_NAME"
    xtmoe qemu backup "$QEMU_NAME" "$QEMU_BACKUP"
    [[ -s $QEMU_BACKUP ]] || die 'QEMU 备份为空'
    xtmoe qemu remove --yes "$QEMU_NAME"
    xtmoe qemu restore "$QEMU_BACKUP" "$QEMU_RESTORE_NAME"
    xtmoe qemu start "$QEMU_RESTORE_NAME"
    xtmoe qemu wait-ready --timeout 600 "$QEMU_RESTORE_NAME"
    xtmoe qemu exec "$QEMU_RESTORE_NAME" -- grep -q '^ID=ubuntu' /etc/os-release
    xtmoe qemu stop "$QEMU_RESTORE_NAME"
    xtmoe qemu remove --yes "$QEMU_RESTORE_NAME"
    trap - EXIT INT TERM
    say 'SMOKE PASS: QEMU install/SSH/systemd/Docker/backup/restore/remove'
}

proot_test() {
    doctor_test
    mkdir -p "$WORK_DIR"
    trap cleanup_proot EXIT INT TERM

    xtmoe proot install ubuntu:24.04 "$PROOT_NAME"
    xtmoe proot exec "$PROOT_NAME" -- /bin/sh -lc \
        'grep -q "^ID=ubuntu" /etc/os-release && printf smoke-ok > /root/.xtmoe-smoke'
    [[ $(xtmoe proot exec "$PROOT_NAME" -- cat /root/.xtmoe-smoke) == smoke-ok ]] || die 'PRoot 文件读写失败'

    xtmoe proot stop "$PROOT_NAME" || true
    xtmoe proot backup "$PROOT_NAME" "$BACKUP_FILE"
    [[ -s $BACKUP_FILE ]] || die 'PRoot 备份为空'
    xtmoe proot remove --yes "$PROOT_NAME"
    xtmoe proot restore "$BACKUP_FILE"
    [[ $(xtmoe proot exec "$PROOT_NAME" -- cat /root/.xtmoe-smoke) == smoke-ok ]] || die 'PRoot 恢复校验失败'
    xtmoe proot remove --yes "$PROOT_NAME"
    trap - EXIT INT TERM
    say 'SMOKE PASS: PRoot install/exec/backup/restore/remove'
}

smoke_host_selinux() {
    local mode backend
    for backend in su tsu; do
        command -v "$backend" >/dev/null 2>&1 || continue
        if mode=$("$backend" -c /system/bin/getenforce 2>/dev/null); then
            case "$mode" in Enforcing|Permissive|Disabled) printf '%s' "$mode"; return 0 ;; esac
        fi
    done
    return 1
}

chroot_test() {
    local systemd_state install_status selinux_before selinux_after
    [[ ${XTMOE_SMOKE_ACCEPT_CHROOT_RISK:-} == YES ]] || die 'Chroot 测试需要设置 XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES'
    doctor_test
    mkdir -p "$WORK_DIR" "$HOST_SHARE"
    printf 'host-bind-ok\n' >"$HOST_SHARE/probe.txt"
    trap cleanup_chroot EXIT INT TERM

    xtmoe chroot prepare
    selinux_before=$(smoke_host_selinux) || die '无法记录安装前宿主 SELinux 模式'
    set +e
    # Validate the normal first-install path, not a test-only --yes shortcut.
    xtmoe chroot install ubuntu 24.04 "$CHROOT_NAME" </dev/null
    install_status=$?
    set -e
    selinux_after=$(smoke_host_selinux) || die '无法记录安装后宿主 SELinux 模式'
    [[ $selinux_before == "$selinux_after" ]] || die "宿主 SELinux 模式发生变化：$selinux_before -> $selinux_after；停止测试，不自动改变模式"
    [[ $install_status == 0 || $install_status == 2 ]] || die "Chroot 初始化失败，状态：$install_status"
    xtmoe list --all --no-prompt | grep -Fq "$CHROOT_NAME" || die '统一列表没有显示新 Chroot'
    xtmoe chroot network-check "$CHROOT_NAME"
    xtmoe chroot systemd-exec "$CHROOT_NAME" -- /bin/bash -lc 'test ! -L /etc/resolv.conf && grep -qx "nameserver 1.1.1.1" /etc/resolv.conf && grep -qx "nameserver 8.8.8.8" /etc/resolv.conf && grep -qx "hosts: files dns" /etc/nsswitch.conf && apt-get -o APT::Update::Error-Mode=any update'
    xtmoe chroot cgroup-check "$CHROOT_NAME" || true
    [[ $(xtmoe chroot systemd-exec "$CHROOT_NAME" -- readlink -f /bin/sh) == /usr/bin/bash ]] || die '/bin/sh 未切换为 Bash'
    systemd_state=$(xtmoe chroot systemd-exec "$CHROOT_NAME" -- systemctl is-system-running || true)
    [[ $systemd_state == running || $systemd_state == degraded ]] || die "systemd 状态异常：$systemd_state"
    xtmoe chroot systemd-exec "$CHROOT_NAME" -- /bin/bash -lc 'test "$(cat /run/host/container-manager)" = xtmoe && tr "\0" "\n" </proc/1/environ | grep -qx container=xtmoe'
    xtmoe chroot systemd-exec "$CHROOT_NAME" -- /bin/bash -lc 'set -euo pipefail; findmnt -n -o VFS-OPTIONS /sys | grep -Eq "(^|,)ro(,|$)"; if test -e /sys/fs/selinux/enforce; then findmnt -n -o VFS-OPTIONS /sys/fs/selinux | grep -Eq "(^|,)ro(,|$)"; fi'
    xtmoe chroot systemd-exec "$CHROOT_NAME" -- /usr/sbin/iptables --version
    if [[ $install_status == 0 ]]; then
        xtmoe chroot docker-status "$CHROOT_NAME"
        xtmoe chroot systemd-exec "$CHROOT_NAME" -- docker info >/dev/null
        xtmoe chroot systemd-exec "$CHROOT_NAME" -- docker run --rm hello-world
    else
        if xtmoe chroot systemd-exec "$CHROOT_NAME" -- /bin/bash -lc 'command -v dockerd' >/dev/null 2>&1; then
            die '内核硬阻断时不应安装 dockerd'
        fi
        say 'Docker 按预期被内核能力门控跳过'
    fi
    xtmoe chroot systemd-exec "$CHROOT_NAME" -- /bin/bash -lc \
        'grep -q "^ID=ubuntu" /etc/os-release && getent hosts archive.ubuntu.com >/dev/null && printf smoke-ok > /root/.xtmoe-smoke'
    xtmoe chroot bind "$CHROOT_NAME" "$HOST_SHARE" /mnt/xtmoe-smoke ro
    xtmoe chroot systemd-stop "$CHROOT_NAME"
    xtmoe chroot systemd-start "$CHROOT_NAME"
    selinux_after=$(smoke_host_selinux) || die '无法记录重新启动后的宿主 SELinux 模式'
    [[ $selinux_before == "$selinux_after" ]] || die '重新启动改变了宿主 SELinux 模式；不自动修改模式'
    if [[ $install_status == 0 ]]; then
        xtmoe chroot systemd-exec "$CHROOT_NAME" -- timeout 60 /bin/bash -c 'until systemctl is-active --quiet docker.service && docker info >/dev/null 2>&1; do sleep 2; done'
    fi
    [[ $(xtmoe chroot systemd-exec "$CHROOT_NAME" -- cat /mnt/xtmoe-smoke/probe.txt) == host-bind-ok ]] || die 'Chroot 只读绑定读取失败'
    if xtmoe chroot systemd-exec "$CHROOT_NAME" -- touch /mnt/xtmoe-smoke/must-not-exist; then
        die 'Chroot 只读绑定仍可写入'
    fi
    [[ ! -e $HOST_SHARE/must-not-exist ]] || die '只读绑定在宿主产生了文件'

    xtmoe chroot stop "$CHROOT_NAME"
    [[ $(xtmoe chroot status "$CHROOT_NAME") == stopped ]] || die '统一 stop 未停止 systemd 并卸载 Chroot'
    xtmoe chroot backup "$CHROOT_NAME" "$CHROOT_BACKUP"
    [[ -s $CHROOT_BACKUP ]] || die 'Chroot 备份为空'
    xtmoe chroot remove --yes "$CHROOT_NAME"
    xtmoe chroot restore "$CHROOT_BACKUP" "$RESTORE_NAME"
    [[ $(xtmoe chroot exec "$RESTORE_NAME" -- cat /root/.xtmoe-smoke) == smoke-ok ]] || die 'Chroot 恢复校验失败'
    xtmoe chroot stop "$RESTORE_NAME"
    xtmoe chroot remove --yes "$RESTORE_NAME"
    trap - EXIT INT TERM
    say 'SMOKE PASS: Chroot install/systemd/Bash/DNS/bind/backup/restore/remove'
}

case "$MODE" in
    doctor) doctor_test ;;
    proot) proot_test ;;
    chroot) chroot_test ;;
    qemu) qemu_test ;;
    help|-h|--help) usage ;;
    *) usage; die "未知模式：$MODE" ;;
esac
