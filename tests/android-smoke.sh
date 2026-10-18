#!/data/data/com.termux/files/usr/bin/bash
# Real-device tests use fresh, timestamped containers, never user-owned names.
set -Eeuo pipefail
MODE=${1:-help}
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/src/bin/xtmoe"
STAMP=$(date +%Y%m%d%H%M%S)
NAME="xtmoe-v1-smoke-$STAMP"
RESTORED="xtmoe-v1-restored-$STAMP"
WORK_DIR="$HOME/.cache/xtmoe-tests/$NAME"

cleanup() {
    case "$MODE" in
        proot)
            for target in "$NAME" "$RESTORED"; do
                if proot_exists "$target"; then proot_main stop "$target" || true; proot_main remove --yes "$target"; fi
            done ;;
        chroot)
            for target in "$NAME" "$RESTORED"; do
                if [[ -f $(chroot_base)/$target/.xtmoe-chroot ]]; then
                    chroot_main stop "$target" || return 1
                    chroot_main remove --yes "$target" || return 1
                fi
            done ;;
    esac
}

case "$MODE" in
    help|-h|--help)
        printf '%s\n' 'Android v1.0.0 smoke（以 Termux 普通用户运行）' \
            'bash tests/android-smoke.sh doctor' \
            'XTMOE_SMOKE_ACCEPT_TEST_COST=YES bash tests/android-smoke.sh proot' \
            'XTMOE_SMOKE_ACCEPT_TEST_COST=YES bash tests/android-smoke.sh chroot' \
            '仅清理脚本生成的临时容器；失败保留日志，现有用户系统不清空。'
        exit 0 ;;
    doctor) main version; doctor; main proot help; main chroot help; exit ;;
    proot|chroot) ;;
    *) die '只支持 doctor、proot、chroot 测试' ;;
esac
[[ ${XTMOE_SMOKE_ACCEPT_TEST_COST:-} == YES ]] || die '测试会下载并创建临时系统；需设置 XTMOE_SMOKE_ACCEPT_TEST_COST=YES'
require_termux
mkdir -p "$WORK_DIR"
trap cleanup EXIT
case "$MODE" in
    proot)
        image=${XTMOE_SMOKE_NATIVE_IMAGE:-ubuntu:24.04}
        main proot install "$image" "$NAME"
        main proot exec "$NAME" -- /bin/bash -ec 'test "$(. /etc/os-release; printf %s "$ID")" = ubuntu; printf smoke-ok >/root/.xtmoe-smoke'
        [[ $(main proot exec "$NAME" -- cat /root/.xtmoe-smoke) == smoke-ok ]]
        main proot list
        main proot ps
        main proot status "$NAME"
        main proot stop "$NAME" || true
        main proot backup "$NAME" "$WORK_DIR/proot.tar.gz"
        main uninstall --yes proot "$NAME"
        proot_main restore "$WORK_DIR/proot.tar.gz"
        [[ $(main proot exec "$NAME" -- cat /root/.xtmoe-smoke) == smoke-ok ]]
        main proot stop "$NAME" || true
        main uninstall --yes proot "$NAME"
        ;;
    chroot)
        main chroot install ubuntu 24.04 "$NAME"
        chroot_main network-status "$NAME"
        chroot_main exec "$NAME" -- /bin/bash -ec 'test "$(. /etc/os-release; printf %s "$ID")" = ubuntu; getent hosts ports.ubuntu.com; printf smoke-ok >/root/.xtmoe-smoke'
        main list --all --no-prompt
        chroot_main exec "$NAME" -- /usr/bin/apt-get -o APT::Update::Error-Mode=any update
        if [[ $(chroot_meta_get "$NAME" systemd_requested) == 1 ]]; then
            chroot_systemd_verify "$NAME"
            chroot_main systemd-restart "$NAME"
        fi
        if [[ $(chroot_meta_get "$NAME" docker_state) == ready ]]; then
            chroot_main exec "$NAME" -- /usr/bin/timeout 120 /usr/bin/docker run --rm hello-world
        fi
        main chroot stop "$NAME"
        [[ $(main chroot status "$NAME") == stopped ]]
        chroot_main backup "$NAME" "$WORK_DIR/chroot.tar.gz"
        chroot_main restore "$WORK_DIR/chroot.tar.gz" "$RESTORED"
        [[ $(chroot_main exec "$RESTORED" -- cat /root/.xtmoe-smoke) == smoke-ok ]]
        main chroot stop "$RESTORED"
        main uninstall --yes chroot "$RESTORED"
        main uninstall --yes chroot "$NAME"
        ;;
esac
trap - EXIT
printf 'SMOKE_PASS %s %s\n' "$MODE" "$NAME"
