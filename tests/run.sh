#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/share/termux-v2/bin/tmoe"
ROOT_HELPER="$ROOT_DIR/share/termux-v2/lib/tmoe-root"
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; ((PASS += 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; ((FAIL += 1)); }

assert_ok() {
    local description=$1; shift
    if "$@" >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr"; then
        pass "$description"
    else
        cat "$TEST_TMP/stdout" "$TEST_TMP/stderr" >&2
        fail "$description"
    fi
}

assert_fail() {
    local description=$1; shift
    if "$@" >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_contains() {
    local description=$1 expected=$2 file=$3
    if grep -Fq -- "$expected" "$file"; then pass "$description"; else fail "$description"; fi
}

export HOME="$TEST_TMP/home"
export PREFIX="$TEST_TMP/prefix"
export TERMUX_VERSION='test'
export TMOE_HOME="$HOME"
export TMOE_CONFIG_DIR="$HOME/.config/tmoe-termux"
export TMOE_DATA_DIR="$HOME/.local/share/tmoe-termux"
export TMOE_CACHE_DIR="$HOME/.cache/tmoe-termux"
export NO_COLOR=1
mkdir -p "$HOME" "$PREFIX/bin" "$TEST_TMP/mock-bin"

cat >"$TEST_TMP/mock-bin/proot-distro" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then printf 'proot-distro test\n'; exit 0; fi
if [[ ${1:-} == install && ${2:-} == --help ]]; then printf '%s\n' '--name NAME'; exit 0; fi
printf '%s\n' "$*" >>"$MOCK_LOG"
MOCK

cat >"$TEST_TMP/mock-bin/tsu" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} == -c ]] || exit 2
if [[ ${2:-} == 'id -u' ]]; then printf '0\n'; exit 0; fi
eval "$2"
MOCK

chmod +x "$TEST_TMP/mock-bin/proot-distro" "$TEST_TMP/mock-bin/tsu"
export PATH="$TEST_TMP/mock-bin:$PATH"
export MOCK_LOG="$TEST_TMP/proot.log"
: >"$MOCK_LOG"

assert_ok 'CLI help' bash "$CLI" help
assert_contains 'CLI help mentions PRoot' 'tmoe proot' "$TEST_TMP/stdout"
assert_ok 'CLI version' bash "$CLI" version
assert_ok 'PRoot help' bash "$CLI" proot help
assert_ok 'Chroot help' bash "$CLI" chroot help
assert_ok 'Migration help' bash "$CLI" migrate help

assert_ok 'PRoot install dispatch' bash "$CLI" proot install ubuntu:24.04 demo
assert_contains 'PRoot install keeps image and name' 'install --name demo ubuntu:24.04' "$MOCK_LOG"
assert_ok 'PRoot exec dispatch' bash "$CLI" proot exec demo -- uname -a
assert_contains 'PRoot exec keeps argument boundary' 'login demo -- uname -a' "$MOCK_LOG"
assert_fail 'PRoot invalid name rejected' bash "$CLI" proot install ubuntu:24.04 '../escape'
assert_fail 'PRoot non-interactive remove requires --yes' bash "$CLI" proot remove demo
assert_ok 'PRoot explicit remove accepted' bash "$CLI" proot remove --yes demo
assert_contains 'PRoot remove dispatched' 'remove demo' "$MOCK_LOG"

mkdir -p "$TMOE_DATA_DIR/chroot/demo" "$TMOE_CONFIG_DIR/chroot" "$HOME/shared"
assert_ok 'Chroot bind config accepted' bash "$CLI" chroot bind demo "$HOME/shared" /mnt/shared ro
assert_contains 'Chroot bind is data, not shell' "ro|$HOME/shared|/mnt/shared" "$TMOE_CONFIG_DIR/chroot/demo.binds"
assert_fail 'Chroot duplicate target rejected' bash "$CLI" chroot bind demo "$HOME/shared" /mnt/shared rw
assert_fail 'Chroot relative target rejected' bash "$CLI" chroot bind demo "$HOME/shared" '../escape' rw
assert_fail 'Chroot invalid container name rejected' bash "$CLI" chroot bind '../escape' "$HOME/shared" /mnt/shared rw
assert_fail 'Chroot refuses whole host root bind' bash "$CLI" chroot bind demo / /mnt/host rw

mkdir -p "$HOME/.local/share/tmoe-linux/containers/proot/legacy-proot"
mkdir -p "$HOME/.local/share/tmoe-linux/containers/chroot/legacy-chroot"
mkdir -p "$HOME/.config/tmoe-linux"
assert_ok 'Legacy migration scan is readable' bash "$CLI" migrate scan
assert_contains 'Migration scan finds legacy PRoot' 'legacy-proot' "$TEST_TMP/stdout"
assert_contains 'Migration scan finds legacy Chroot' 'legacy-chroot' "$TEST_TMP/stdout"
assert_contains 'Migration scan reports mount state' '[未发现挂载]' "$TEST_TMP/stdout"

printf '<a>ubuntu-base-24.04.3-base-amd64.tar.gz</a>\n<a>ubuntu-base-24.04.5-base-amd64.tar.gz</a>\n' >"$TEST_TMP/ubuntu-index"
printf 'fake ubuntu base archive\n' >"$TEST_TMP/ubuntu-archive"
archive_hash=$(sha256sum "$TEST_TMP/ubuntu-archive" | awk '{print $1}')
printf '%s *ubuntu-base-24.04.5-base-amd64.tar.gz\n' "$archive_hash" >"$TEST_TMP/ubuntu-sums"
export MOCK_UBUNTU_INDEX="$TEST_TMP/ubuntu-index"
export MOCK_UBUNTU_ARCHIVE="$TEST_TMP/ubuntu-archive"
export MOCK_UBUNTU_SUMS="$TEST_TMP/ubuntu-sums"
cat >"$TEST_TMP/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
output='' url=''
while (($#)); do
    case "$1" in
        -o) output=$2; shift 2 ;;
        *) url=$1; shift ;;
    esac
done
case "$url" in
    */SHA256SUMS) cp "$MOCK_UBUNTU_SUMS" "$output" ;;
    */release/) cp "$MOCK_UBUNTU_INDEX" "$output" ;;
    *.tar.gz) cp "$MOCK_UBUNTU_ARCHIVE" "$output" ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$TEST_TMP/mock-bin/curl"
assert_ok 'Ubuntu Base index and starred checksum parsed' bash -c "source '$ROOT_DIR/share/termux-v2/lib/common.sh'; source '$ROOT_DIR/share/termux-v2/lib/chroot.sh'; download_ubuntu_base 24.04"
assert_contains 'Newest Ubuntu point release selected' 'ubuntu-base-24.04.5-base-amd64.tar.gz' "$TEST_TMP/stdout"
cached_ubuntu="$TMOE_CACHE_DIR/ubuntu-base/24.04/ubuntu-base-24.04.5-base-amd64.tar.gz"
printf 'corrupted cache\n' >"$cached_ubuntu"
assert_ok 'Corrupted Ubuntu cache is downloaded again' bash -c "source '$ROOT_DIR/share/termux-v2/lib/common.sh'; source '$ROOT_DIR/share/termux-v2/lib/chroot.sh'; download_ubuntu_base 24.04"
cmp -s "$cached_ubuntu" "$MOCK_UBUNTU_ARCHIVE" && pass 'Redownloaded Ubuntu cache content verified' || fail 'Redownloaded Ubuntu cache content verified'
rm -f -- "$TEST_TMP/mock-bin/curl"

cat >"$TEST_TMP/mock-bin/id" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} == -u ]] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
MOCK
chmod +x "$TEST_TMP/mock-bin/id"
assert_fail 'Root helper rejects arbitrary base path' bash "$ROOT_HELPER" "$PREFIX" status /tmp demo
assert_contains 'Root helper reports protected path' '拒绝操作非 TMOE Chroot 目录' "$TEST_TMP/stderr"

rootfs_fixture_lifecycle() {
    local fixture="$TEST_TMP/rootfs-fixture" archive="$TEST_TMP/rootfs-fixture.tar.gz"
    local base="$TEST_TMP/data/data/com.termux/files/home/.local/share/tmoe-termux/chroot"
    local backup="$TEST_TMP/rootfs-backup.tar.gz"
    mkdir -p "$fixture/bin" "$fixture/etc" "$base"
    printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sh"
    chmod +x "$fixture/bin/sh"
    tar -czpf "$archive" -C "$fixture" .

    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" install "$base" fixture "$archive" 223.5.5.5
    [[ -x $base/fixture/rootfs/bin/sh ]]
    grep -qx 'nameserver 223.5.5.5' "$base/fixture/rootfs/etc/resolv.conf"
    [[ $(PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" status "$base" fixture) == stopped ]]
    if PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" backup "$base" fixture "$base/fixture/inside.tar.gz" 0 0; then
        return 1
    fi
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" backup "$base" fixture "$backup" 0 0
    if PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" backup "$base" fixture "$backup" 0 0; then
        return 1
    fi
    ! compgen -G "$backup.partial.*" >/dev/null
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" remove "$base" fixture
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" restore "$base" restored "$backup"
    [[ -x $base/restored/rootfs/bin/sh ]]
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" remove "$base" restored
}
assert_ok 'Synthetic rootfs install/backup/restore/remove lifecycle' rootfs_fixture_lifecycle
rm -f -- "$TEST_TMP/mock-bin/id"

export TMOE_SKIP_PACKAGES=1
export TMOE_ALLOW_NON_TERMUX=1
assert_ok 'Local installer completes' sh "$ROOT_DIR/termux.sh"
[[ -x "$PREFIX/bin/tmoe" ]] && pass 'Installer creates executable command' || fail 'Installer creates executable command'
[[ -r "$PREFIX/libexec/tmoe-termux/lib/chroot.sh" ]] && pass 'Installer copies libraries' || fail 'Installer copies libraries'

proot_actions=$(grep -rhoE 'tmoe[[:space:]]+proot[[:space:]]+[a-z-]+' "$ROOT_DIR/Readme.md" "$ROOT_DIR/docs" | awk '{print $3}' | sort -u)
for action in $proot_actions; do
    case "$action" in
        install|login|exec|list|ps|stop|backup|restore|remove|raw) ;;
        *) fail "Documentation references unknown PRoot action: $action" ;;
    esac
done
pass 'Documented PRoot actions map to CLI'

chroot_actions=$(grep -rhoE 'tmoe[[:space:]]+chroot[[:space:]]+[a-z-]+' "$ROOT_DIR/Readme.md" "$ROOT_DIR/docs" | awk '{print $3}' | sort -u)
for action in $chroot_actions; do
    case "$action" in
        prepare|install|login|exec|setup|status|list|stop|bind|unbind|backup|restore|remove) ;;
        *) fail "Documentation references unknown Chroot action: $action" ;;
    esac
done
pass 'Documented Chroot actions map to CLI'

for doc in INSTALL PROOT CHROOT OPERATIONS TROUBLESHOOTING MIGRATION ROADMAP; do
    [[ -r "$ROOT_DIR/docs/$doc.md" ]] || fail "Missing documentation: $doc.md"
done
pass 'README documentation targets exist'

printf '# tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))

