#!/usr/bin/env bash
set -Eeuo pipefail

ARCHIVE=${1:?用法：bash tests/rootfs-lifecycle.sh /path/to/ubuntu-base.tar.gz}
[[ -f $ARCHIVE ]] || { printf '镜像不存在：%s\n' "$ARCHIVE" >&2; exit 1; }
ARCHIVE=$(realpath -- "$ARCHIVE")
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT_DIR/share/termux-v2/lib/tmoe-root"
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT

PREFIX="$SANDBOX/prefix"
BASE="$SANDBOX/data/data/com.termux/files/home/.local/share/tmoe-termux/chroot"
BACKUP="$SANDBOX/ubuntu-test.tar.gz"
mkdir -p "$PREFIX/bin" "$BASE"

cat >"$PREFIX/bin/id" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then printf '0\n'; exit 0; fi
exec /usr/bin/id "$@"
MOCK
chmod +x "$PREFIX/bin/id"

root_helper() {
    PATH="$PREFIX/bin:$PATH" bash "$HELPER" "$PREFIX" "$@"
}

root_helper install "$BASE" ubuntu-test "$ARCHIVE" 223.5.5.5 1.1.1.1
[[ -x $BASE/ubuntu-test/rootfs/bin/sh ]]
grep -qx 'nameserver 223.5.5.5' "$BASE/ubuntu-test/rootfs/etc/resolv.conf"
grep -qx 'nameserver 1.1.1.1' "$BASE/ubuntu-test/rootfs/etc/resolv.conf"
[[ $(root_helper status "$BASE" ubuntu-test) == stopped ]]

if root_helper backup "$BASE" ubuntu-test "$BASE/ubuntu-test/inside.tar.gz" 0 0; then
    printf '内部备份路径应当被拒绝\n' >&2
    exit 1
fi

root_helper backup "$BASE" ubuntu-test "$BACKUP" 0 0
[[ -s $BACKUP ]]
root_helper remove "$BASE" ubuntu-test
[[ ! -e $BASE/ubuntu-test ]]

root_helper restore "$BASE" ubuntu-restored "$BACKUP"
[[ -x $BASE/ubuntu-restored/rootfs/bin/sh ]]
grep -qx 'nameserver 223.5.5.5' "$BASE/ubuntu-restored/rootfs/etc/resolv.conf"
root_helper remove "$BASE" ubuntu-restored
[[ ! -e $BASE/ubuntu-restored ]]

printf 'ROOTFS LIFECYCLE PASS\n'
