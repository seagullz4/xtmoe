#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/src/bin/xtmoe"
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

export HOME="$TEST_TMP/data/data/com.termux/files/home"
export PREFIX="$TEST_TMP/data/data/com.termux/files/usr"
export TERMUX_VERSION='test'
export XTMOE_HOME="$HOME"
export XTMOE_CONFIG_DIR="$HOME/.config/xtmoe"
export XTMOE_DATA_DIR="$HOME/.local/share/xtmoe"
export XTMOE_CACHE_DIR="$HOME/.cache/xtmoe"
export NO_COLOR=1
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
mkdir -p "$HOME" "$PREFIX/bin" "$TEST_TMP/mock-bin"

# Git Bash has no flock. Keep offline command dispatch testable there; Linux
# CI uses the actual binary. Lock contention is tested explicitly below.
if ! command -v flock >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/mock-bin/flock"
    chmod +x "$TEST_TMP/mock-bin/flock"
fi

cat >"$TEST_TMP/mock-bin/proot-distro" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then printf 'proot-distro test\n'; exit 0; fi
if [[ ${1:-} == install && ${2:-} == --help ]]; then printf '%s\n' '--name NAME --architecture ARCH'; exit 0; fi
if [[ ${1:-} == help ]]; then printf '%s\n' 'install login list ps reset remove'; exit 0; fi
if [[ ${1:-} == ps ]]; then printf '%s' "${MOCK_PROOT_PS:-PID CONTAINER TYPE USER UPTIME COMMAND\n}"; exit 0; fi
printf '%s\n' "$*" >>"$MOCK_LOG"
MOCK

cat >"$TEST_TMP/mock-bin/tsu" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} == -c ]] || exit 2
if [[ ${2:-} == 'id -u' ]]; then printf '0\n'; exit 0; fi
export XTMOE_TEST_ROOT=1
eval "$2"
MOCK

chmod +x "$TEST_TMP/mock-bin/proot-distro" "$TEST_TMP/mock-bin/tsu"
export PATH="$TEST_TMP/mock-bin:$PREFIX/bin:$PATH"
export MOCK_LOG="$TEST_TMP/proot.log"
: >"$MOCK_LOG"


# Dependencies are deterministic in offline host tests.
cat >"$TEST_TMP/mock-bin/getprop" <<'MOCK'
#!/usr/bin/env bash
case "$1" in ro.build.version.sdk) printf '33\n';; ro.build.version.release) printf '13\n';; esac
MOCK
cat >"$TEST_TMP/mock-bin/dpkg" <<'MOCK'
#!/usr/bin/env bash
printf 'aarch64\n'
MOCK
chmod +x "$TEST_TMP/mock-bin/getprop" "$TEST_TMP/mock-bin/dpkg"
export BOOTSTRAP_LOG="$TEST_TMP/bootstrap.log"
mkdir -p "$XTMOE_DATA_DIR/chroot/docker-gate"
touch "$XTMOE_DATA_DIR/chroot/docker-gate/.xtmoe-chroot"

assert_ok 'CLI help' bash "$CLI" help
assert_contains 'CLI exposes v1.0.0' 'XTMOE v1.0.0' "$TEST_TMP/stdout"
assert_ok 'CLI version' bash "$CLI" version
assert_contains 'Version is v1.0.0' 'xtmoe v1.0.0' "$TEST_TMP/stdout"
assert_ok 'PRoot shortcut help' bash "$CLI" proot help
assert_ok 'Chroot shortcut help' bash "$CLI" chroot help
for command in proxy uninstall-app enter; do
    assert_fail "Unpublished top-level action is rejected: $command" bash "$CLI" "$command"
done
for action in exec login backup repair network-status docker-start systemd-start; do
    assert_fail "Unpublished Chroot action is rejected: $action" bash "$CLI" chroot "$action" ubuntu
done
for action in raw restore remove reinstall; do
    assert_fail "Unpublished PRoot action is rejected: $action" bash "$CLI" proot "$action" ubuntu
done
assert_fail 'on refuses noninteractive input without waiting' bash "$CLI" on
assert_fail 'Uninstall validates exact mode' bash "$CLI" uninstall bogus ubuntu
assert_fail 'Container deletion requires confirmation' bash "$CLI" uninstall proot ubuntu

source "$ROOT_DIR/tests/audit.sh"
source "$ROOT_DIR/tests/chroot-init.sh"
source "$ROOT_DIR/tests/ssh.sh"
source "$ROOT_DIR/tests/proot-ssh.sh"
source "$ROOT_DIR/tests/docker-runtime.sh"
source "$ROOT_DIR/tests/menus.sh"
source "$ROOT_DIR/tests/proxy.sh"
source "$ROOT_DIR/tests/chroot-network.sh"
source "$ROOT_DIR/tests/capabilities.sh"

assert_ok 'Installer copies all required modules' env XTMOE_SKIP_PACKAGES=1 XTMOE_ALLOW_NON_TERMUX=1 sh "$ROOT_DIR/termux.sh"
assert_ok 'Installed version works' bash "$PREFIX/bin/xtmoe" version
assert_contains 'Installed version matches source' 'xtmoe v1.0.0' "$TEST_TMP/stdout"
for module in common.sh capabilities.sh proxy.sh proot.sh proot-ssh.sh chroot.sh manager.sh xtmoe-network; do
    [[ -f "$PREFIX/libexec/xtmoe/current/lib/$module" ]] && pass "Installed module $module" || fail "Missing module $module"
done
source "$ROOT_DIR/tests/install-safety.sh"
expected_modules=$(printf '%s\n' capabilities.sh chroot.sh common.sh manager.sh proot.sh proot-ssh.sh proxy.sh xtmoe-docker-routing xtmoe-docker-routing.service xtmoe-network | sort)
actual_modules=$(find "$ROOT_DIR/src/lib" -maxdepth 1 -type f -printf '%f\n' | sed '/^xtmoe-root$/d' | sort)
[[ $actual_modules == "$expected_modules" ]] && pass 'Only intended dual-mode modules are shipped' || fail 'Unexpected module inventory'

for doc in INSTALL PROOT CHROOT OPERATIONS TROUBLESHOOTING ROADMAP ARCHITECTURE ANDROID_VALIDATION PROXY COMPATIBILITY; do
    [[ -f "$ROOT_DIR/docs/$doc.md" ]] && pass "Documentation exists: $doc" || fail "Missing documentation: $doc"
done
printf '# tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
