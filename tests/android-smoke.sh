#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

MODE=${1:-doctor}
STAMP=$(date +%Y%m%d%H%M%S)
PROOT_NAME="xtmoe-smoke-p-$STAMP"
CHROOT_NAME="xtmoe-smoke-c-$STAMP"
RESTORE_NAME="xtmoe-smoke-r-$STAMP"
WORK_DIR="${TMPDIR:-$HOME/.cache}/xtmoe-smoke-$STAMP"
BACKUP_FILE="$WORK_DIR/$PROOT_NAME.tar.gz"
CHROOT_BACKUP="$WORK_DIR/$CHROOT_NAME.tar.gz"
HOST_SHARE="$WORK_DIR/host-share"

say() { printf '%s\n' "$*"; }
die() { printf 'SMOKE FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Android 真机冒烟测试

  bash tests/android-smoke.sh doctor
  bash tests/android-smoke.sh proot
  XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot

proot 会创建、备份、恢复并删除一个名称带时间戳的临时容器。
chroot 会执行真实 Root 挂载和删除，仅在明确设置风险确认变量时运行。
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

doctor_test() {
    command -v xtmoe >/dev/null 2>&1 || die '未安装 xtmoe'
    [[ ${PREFIX:-} == */files/usr ]] || die '当前不是 Termux PREFIX'
    [[ $(id -u) -ne 0 ]] || die '请退出 su/tsu 后再运行测试'
    xtmoe version
    xtmoe doctor
    xtmoe proot help >/dev/null
    xtmoe chroot help >/dev/null
    say 'SMOKE PASS: doctor/help'
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

chroot_test() {
    [[ ${XTMOE_SMOKE_ACCEPT_CHROOT_RISK:-} == YES ]] || die 'Chroot 测试需要设置 XTMOE_SMOKE_ACCEPT_CHROOT_RISK=YES'
    doctor_test
    mkdir -p "$WORK_DIR" "$HOST_SHARE"
    printf 'host-bind-ok\n' >"$HOST_SHARE/probe.txt"
    trap cleanup_chroot EXIT INT TERM

    xtmoe chroot prepare
    xtmoe chroot install --yes ubuntu 24.04 "$CHROOT_NAME"
    [[ $(xtmoe chroot systemd-exec "$CHROOT_NAME" -- readlink -f /bin/sh) == /usr/bin/bash ]] || die '/bin/sh 未切换为 Bash'
    systemd_state=$(xtmoe chroot systemd-exec "$CHROOT_NAME" -- systemctl is-system-running || true)
    [[ $systemd_state == running || $systemd_state == degraded || $systemd_state == starting ]] || die "systemd 状态异常：$systemd_state"
    xtmoe chroot systemd-exec "$CHROOT_NAME" -- /bin/bash -lc \
        'grep -q "^ID=ubuntu" /etc/os-release && getent hosts archive.ubuntu.com >/dev/null && printf smoke-ok > /root/.xtmoe-smoke'
    xtmoe chroot bind "$CHROOT_NAME" "$HOST_SHARE" /mnt/xtmoe-smoke ro
    xtmoe chroot systemd-stop "$CHROOT_NAME"
    xtmoe chroot systemd-start "$CHROOT_NAME"
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
    help|-h|--help) usage ;;
    *) usage; die "未知模式：$MODE" ;;
esac
