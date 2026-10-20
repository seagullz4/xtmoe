#!/data/data/com.termux/files/usr/bin/sh
# XTMOE installer. Run this file from a cloned source tree.
set -eu

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

STAGE_DIR=''
POINTER_DIR=''
LAUNCHER_TMP=''
cleanup() {
    if [ -n "$POINTER_DIR" ]; then
        rm -f -- "$POINTER_DIR/current"
        rmdir -- "$POINTER_DIR"
    fi
    [ -z "$LAUNCHER_TMP" ] || rm -f -- "$LAUNCHER_TMP"
    # Only a mktemp-created, unpublished staging directory is disposable.
    [ -z "$STAGE_DIR" ] || rm -rf -- "$STAGE_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

case "${PREFIX:-}" in
    */com.termux/files/usr|*/com.termux.*/*/usr) ;;
    *)
        [ "${XTMOE_ALLOW_NON_TERMUX:-0}" = 1 ] ||
            die '此安装器只能在 Termux 普通用户会话中运行。'
        ;;
esac

[ "$(id -u)" -ne 0 ] || die '不要使用 su/tsu 运行安装器；需要 Root 的操作会单独提权。'
if [ "${XTMOE_ALLOW_NON_TERMUX:-0}" != 1 ]; then
    android_api=$(getprop ro.build.version.sdk 2>/dev/null) || die '无法检测 Android API'
    case "$android_api" in ''|*[!0-9]*) die 'Android API 无效';; esac
    [ "$android_api" -ge 24 ] || die 'XTMOE v1.0.0 要求 Android 7.0 / API 24 或更新系统'
fi

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/src"
[ -r "$SOURCE_DIR/bin/xtmoe" ] || die "源文件不完整：$SOURCE_DIR/bin/xtmoe"
for module in common.sh capabilities.sh proxy.sh proot.sh proot-ssh.sh chroot.sh manager.sh xtmoe-root xtmoe-network xtmoe-uid-network.py xtmoe-docker-routing xtmoe-docker-routing.service; do
    [ -r "$SOURCE_DIR/lib/$module" ] || die "源文件不完整：$SOURCE_DIR/lib/$module"
done

XTMOE_PREFIX=${PREFIX:-"$HOME/.local"}
BIN_DIR="$XTMOE_PREFIX/bin"
LIB_DIR="$XTMOE_PREFIX/libexec/xtmoe"

if command -v pkg >/dev/null 2>&1 && [ "${XTMOE_SKIP_PACKAGES:-0}" != 1 ]; then
    say '安装基础依赖（bash、coreutils、curl、tar、util-linux、proot-distro）……'
    DEBIAN_FRONTEND=noninteractive pkg install -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        bash coreutils curl tar util-linux proot-distro socat python
fi

mkdir -p "$BIN_DIR" "$XTMOE_PREFIX/libexec"
LOCK_FILE="$XTMOE_PREFIX/libexec/.xtmoe-install.lock"
[ ! -L "$LOCK_FILE" ] || die '安装锁不能是符号链接'
command -v flock >/dev/null 2>&1 || die '缺少 flock，请安装 util-linux'
exec 9>"$LOCK_FILE"
flock -n 9 || die '另一个安装或更新正在进行，请稍后重试'
[ ! -L "$LIB_DIR" ] && [ ! -L "$LIB_DIR/releases" ] || die '安装目录不能是符号链接'
mkdir -p "$LIB_DIR/releases"
STAGE_DIR=$(mktemp -d "$LIB_DIR/releases/.stage.XXXXXX")
mkdir "$STAGE_DIR/bin" "$STAGE_DIR/lib"
cp -- "$SOURCE_DIR/bin/xtmoe" "$STAGE_DIR/bin/xtmoe"
chmod 0755 "$STAGE_DIR/bin/xtmoe"
for module in common.sh capabilities.sh proxy.sh proot.sh proot-ssh.sh chroot.sh manager.sh xtmoe-network xtmoe-uid-network.py xtmoe-docker-routing xtmoe-docker-routing.service; do
    cp -- "$SOURCE_DIR/lib/$module" "$STAGE_DIR/lib/$module"
    chmod 0644 "$STAGE_DIR/lib/$module"
done
cp -- "$SOURCE_DIR/lib/xtmoe-root" "$STAGE_DIR/xtmoe-root"
chmod 0755 "$STAGE_DIR/xtmoe-root"
printf '%s\n' "$SCRIPT_DIR" >"$STAGE_DIR/source-root"
chmod 0644 "$STAGE_DIR/source-root"

# Validate the whole bundle without touching the current installation.
bash -n "$STAGE_DIR/bin/xtmoe"
bash -n "$STAGE_DIR/xtmoe-root"
for module in "$STAGE_DIR"/lib/*; do
    case "$module" in *.service|*.py) continue ;; esac
    bash -n "$module"
done
SOURCE_VERSION=$(bash "$SOURCE_DIR/bin/xtmoe" version)
INSTALLED_VERSION=$(bash "$STAGE_DIR/bin/xtmoe" version)
[ "$SOURCE_VERSION" = "$INSTALLED_VERSION" ] || die '暂存版本校验失败；原安装未改变'

LAUNCHER_TMP=$(mktemp "$BIN_DIR/.xtmoe-launcher.XXXXXX")
cat >"$LAUNCHER_TMP" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
install_base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../libexec/xtmoe" && pwd -P)
release=$(realpath -e -- "$install_base/current")
[[ $release == "$install_base/releases/"* && -f $release/bin/xtmoe ]] || { printf 'XTMOE 安装指针无效，请重新运行安装器\n' >&2; exit 1; }
# Resolve current once: all imports and future Root helpers use this generation.
exec bash "$release/bin/xtmoe" "$@"
LAUNCHER
chmod 0755 "$LAUNCHER_TMP"
bash -n "$LAUNCHER_TMP"
RELEASE_NAME="release-${STAGE_DIR##*.stage.}"
RELEASE_DIR="$LIB_DIR/releases/$RELEASE_NAME"
[ ! -e "$RELEASE_DIR" ] && [ ! -L "$RELEASE_DIR" ] || die '版本目录冲突'
mv -T -- "$STAGE_DIR" "$RELEASE_DIR"
STAGE_DIR=''
POINTER_DIR=$(mktemp -d "$LIB_DIR/.pointer.XXXXXX")
ln -s "releases/$RELEASE_NAME" "$POINTER_DIR/current"
# Atomic commit point. Never rewrite or collect older generations: running
# commands and network watchers may still need their exact helper/library pair.
mv -Tf -- "$POINTER_DIR/current" "$LIB_DIR/current"
rmdir -- "$POINTER_DIR"
POINTER_DIR=''
mv -Tf -- "$LAUNCHER_TMP" "$BIN_DIR/xtmoe"
LAUNCHER_TMP=''

say "安装完成：$BIN_DIR/xtmoe"
say "版本：$INSTALLED_VERSION"
say "源码目录：$SCRIPT_DIR"
say '请执行：xtmoe doctor'
