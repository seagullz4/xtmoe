#!/data/data/com.termux/files/usr/bin/sh
# TMOE Termux v2 installer. Run this file from a cloned source tree.
set -eu

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

case "${PREFIX:-}" in
    */com.termux/files/usr|*/com.termux.*/*/usr) ;;
    *)
        [ "${TMOE_ALLOW_NON_TERMUX:-0}" = 1 ] ||
            die '此安装器只能在 Termux 普通用户会话中运行。'
        ;;
esac

[ "$(id -u)" -ne 0 ] || die '不要使用 su/tsu 运行安装器；需要 Root 的操作会单独提权。'

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/share/termux-v2"
[ -r "$SOURCE_DIR/bin/tmoe" ] || die "源文件不完整：$SOURCE_DIR/bin/tmoe"

TMOE_PREFIX=${PREFIX:-"$HOME/.local"}
BIN_DIR="$TMOE_PREFIX/bin"
LIB_DIR="$TMOE_PREFIX/libexec/tmoe-termux"

if command -v pkg >/dev/null 2>&1 && [ "${TMOE_SKIP_PACKAGES:-0}" != 1 ]; then
    say '安装基础依赖（bash、coreutils、curl、tar、proot-distro）……'
    pkg install -y bash coreutils curl tar proot-distro
fi

mkdir -p "$BIN_DIR" "$LIB_DIR/lib"
install -m 0755 "$SOURCE_DIR/bin/tmoe" "$BIN_DIR/tmoe"
install -m 0755 "$SOURCE_DIR/lib/tmoe-root" "$LIB_DIR/tmoe-root"
install -m 0644 "$SOURCE_DIR/lib/common.sh" "$LIB_DIR/lib/common.sh"
install -m 0644 "$SOURCE_DIR/lib/proot.sh" "$LIB_DIR/lib/proot.sh"
install -m 0644 "$SOURCE_DIR/lib/chroot.sh" "$LIB_DIR/lib/chroot.sh"

say "安装完成：$BIN_DIR/tmoe"
say '请执行：tmoe doctor'

