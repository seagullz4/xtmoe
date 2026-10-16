#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

MODE=${1:-doctor}
STAMP=$(date +%Y%m%d%H%M%S)
PROOT_NAME="tmoe-smoke-p-$STAMP"
CHROOT_NAME="tmoe-smoke-c-$STAMP"
RESTORE_NAME="tmoe-smoke-r-$STAMP"
WORK_DIR="${TMPDIR:-$HOME/.cache}/tmoe-smoke-$STAMP"
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
  TMOE_SMOKE_ACCEPT_CHROOT_RISK=YES bash tests/android-smoke.sh chroot

proot 会创建、备份、恢复并删除一个名称带时间戳的临时容器。
chroot 会执行真实 Root 挂载和删除，仅在明确设置风险确认变量时运行。
EOF
}

cleanup_proot() {
    tmoe proot stop "$PROOT_NAME" >/dev/null 2>&1 || true
    tmoe proot remove --yes "$PROOT_NAME" >/dev/null 2>&1 || true
}

cleanup_chroot() {
    tmoe chroot stop "$CHROOT_NAME" >/dev/null 2>&1 || true
    tmoe chroot stop "$RESTORE_NAME" >/dev/null 2>&1 || true
    tmoe chroot remove --yes "$CHROOT_NAME" >/dev/null 2>&1 || true
    tmoe chroot remove --yes "$RESTORE_NAME" >/dev/null 2>&1 || true
}

doctor_test() {
    command -v tmoe >/dev/null 2>&1 || die '未安装 tmoe'
    [[ ${PREFIX:-} == */files/usr ]] || die '当前不是 Termux PREFIX'
    [[ $(id -u) -ne 0 ]] || die '请退出 su/tsu 后再运行测试'
    tmoe version
    tmoe doctor
    tmoe proot help >/dev/null
    tmoe chroot help >/dev/null
    say 'SMOKE PASS: doctor/help'
}

proot_test() {
    doctor_test
    mkdir -p "$WORK_DIR"
    trap cleanup_proot EXIT INT TERM

    tmoe proot install ubuntu:24.04 "$PROOT_NAME"
    tmoe proot exec "$PROOT_NAME" -- /bin/sh -lc \
        'grep -q "^ID=ubuntu" /etc/os-release && printf smoke-ok > /root/.tmoe-smoke'
    [[ $(tmoe proot exec "$PROOT_NAME" -- cat /root/.tmoe-smoke) == smoke-ok ]] || die 'PRoot 文件读写失败'

    tmoe proot stop "$PROOT_NAME" || true
    tmoe proot backup "$PROOT_NAME" "$BACKUP_FILE"
    [[ -s $BACKUP_FILE ]] || die 'PRoot 备份为空'
    tmoe proot remove --yes "$PROOT_NAME"
    tmoe proot restore "$BACKUP_FILE"
    [[ $(tmoe proot exec "$PROOT_NAME" -- cat /root/.tmoe-smoke) == smoke-ok ]] || die 'PRoot 恢复校验失败'
    tmoe proot remove --yes "$PROOT_NAME"
    trap - EXIT INT TERM
    say 'SMOKE PASS: PRoot install/exec/backup/restore/remove'
}

chroot_test() {
    [[ ${TMOE_SMOKE_ACCEPT_CHROOT_RISK:-} == YES ]] || die 'Chroot 测试需要设置 TMOE_SMOKE_ACCEPT_CHROOT_RISK=YES'
    doctor_test
    mkdir -p "$WORK_DIR" "$HOST_SHARE"
    printf 'host-bind-ok\n' >"$HOST_SHARE/probe.txt"
    trap cleanup_chroot EXIT INT TERM

    tmoe chroot prepare
    tmoe chroot install ubuntu 24.04 "$CHROOT_NAME"
    tmoe chroot exec "$CHROOT_NAME" -- /bin/sh -lc \
        'grep -q "^ID=ubuntu" /etc/os-release && getent hosts archive.ubuntu.com >/dev/null && printf smoke-ok > /root/.tmoe-smoke'
    tmoe chroot bind "$CHROOT_NAME" "$HOST_SHARE" /mnt/tmoe-smoke ro
    [[ $(tmoe chroot exec "$CHROOT_NAME" -- cat /mnt/tmoe-smoke/probe.txt) == host-bind-ok ]] || die 'Chroot 只读绑定读取失败'
    if tmoe chroot exec "$CHROOT_NAME" -- touch /mnt/tmoe-smoke/must-not-exist; then
        die 'Chroot 只读绑定仍可写入'
    fi
    [[ ! -e $HOST_SHARE/must-not-exist ]] || die '只读绑定在宿主产生了文件'

    tmoe chroot stop "$CHROOT_NAME"
    [[ $(tmoe chroot status "$CHROOT_NAME") == stopped ]] || die 'Chroot 未完全停止'
    tmoe chroot backup "$CHROOT_NAME" "$CHROOT_BACKUP"
    [[ -s $CHROOT_BACKUP ]] || die 'Chroot 备份为空'
    tmoe chroot remove --yes "$CHROOT_NAME"
    tmoe chroot restore "$CHROOT_BACKUP" "$RESTORE_NAME"
    [[ $(tmoe chroot exec "$RESTORE_NAME" -- cat /root/.tmoe-smoke) == smoke-ok ]] || die 'Chroot 恢复校验失败'
    tmoe chroot stop "$RESTORE_NAME"
    tmoe chroot remove --yes "$RESTORE_NAME"
    trap - EXIT INT TERM
    say 'SMOKE PASS: Chroot install/DNS/bind/backup/restore/remove'
}

case "$MODE" in
    doctor) doctor_test ;;
    proot) proot_test ;;
    chroot) chroot_test ;;
    help|-h|--help) usage ;;
    *) usage; die "未知模式：$MODE" ;;
esac
