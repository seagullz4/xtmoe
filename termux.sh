#!/data/data/com.termux/files/usr/bin/sh
# XTMOE installer. Run this file from a cloned source tree.
set -eu

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

TEMP_FILES=''
cleanup() {
    for file in $TEMP_FILES; do
        rm -f -- "$file"
    done
}
trap cleanup EXIT HUP INT TERM

atomic_install() {
    source_file=$1
    target_file=$2
    file_mode=$3
    temporary_file="${target_file}.tmp.$$"
    TEMP_FILES="$TEMP_FILES $temporary_file"
    cp -- "$source_file" "$temporary_file"
    chmod "$file_mode" "$temporary_file"
    mv -f -- "$temporary_file" "$target_file"
}

case "${PREFIX:-}" in
    */com.termux/files/usr|*/com.termux.*/*/usr) ;;
    *)
        [ "${XTMOE_ALLOW_NON_TERMUX:-0}" = 1 ] ||
            die '此安装器只能在 Termux 普通用户会话中运行。'
        ;;
esac

[ "$(id -u)" -ne 0 ] || die '不要使用 su/tsu 运行安装器；需要 Root 的操作会单独提权。'

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/src"
[ -r "$SOURCE_DIR/bin/xtmoe" ] || die "源文件不完整：$SOURCE_DIR/bin/xtmoe"

XTMOE_PREFIX=${PREFIX:-"$HOME/.local"}
BIN_DIR="$XTMOE_PREFIX/bin"
LIB_DIR="$XTMOE_PREFIX/libexec/xtmoe"

if command -v pkg >/dev/null 2>&1 && [ "${XTMOE_SKIP_PACKAGES:-0}" != 1 ]; then
    say '安装基础依赖（bash、coreutils、curl、tar、util-linux、proot-distro）……'
    pkg install -y bash coreutils curl tar util-linux proot-distro
fi

mkdir -p "$BIN_DIR" "$LIB_DIR/lib"

# Libraries are replaced before the command entrypoint, so an interrupted
# update cannot leave a new command that imports missing old modules.
atomic_install "$SOURCE_DIR/lib/common.sh" "$LIB_DIR/lib/common.sh" 0644
atomic_install "$SOURCE_DIR/lib/proot.sh" "$LIB_DIR/lib/proot.sh" 0644
atomic_install "$SOURCE_DIR/lib/chroot.sh" "$LIB_DIR/lib/chroot.sh" 0644
atomic_install "$SOURCE_DIR/lib/xtmoe-root" "$LIB_DIR/xtmoe-root" 0755

SOURCE_ROOT_FILE="$LIB_DIR/source-root"
SOURCE_ROOT_TMP="${SOURCE_ROOT_FILE}.tmp.$$"
TEMP_FILES="$TEMP_FILES $SOURCE_ROOT_TMP"
printf '%s\n' "$SCRIPT_DIR" >"$SOURCE_ROOT_TMP"
chmod 0644 "$SOURCE_ROOT_TMP"
mv -f -- "$SOURCE_ROOT_TMP" "$SOURCE_ROOT_FILE"

atomic_install "$SOURCE_DIR/bin/xtmoe" "$BIN_DIR/xtmoe" 0755

SOURCE_VERSION=$(bash "$SOURCE_DIR/bin/xtmoe" version)
INSTALLED_VERSION=$(bash "$BIN_DIR/xtmoe" version)
[ "$SOURCE_VERSION" = "$INSTALLED_VERSION" ] ||
    die "版本校验失败：源码=$SOURCE_VERSION，安装=$INSTALLED_VERSION"

say "安装完成：$BIN_DIR/xtmoe"
say "版本：$INSTALLED_VERSION"
say "源码目录：$SCRIPT_DIR"
say '请执行：xtmoe doctor'

