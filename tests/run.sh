#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/src/bin/xtmoe"
ROOT_HELPER="$ROOT_DIR/src/lib/xtmoe-root"
README_FILE="$ROOT_DIR/README.md"
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
if [[ ${1:-} == install && ${2:-} == --help ]]; then printf '%s\n' '--name NAME'; exit 0; fi
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

assert_ok 'CLI help' bash "$CLI" help
assert_contains 'CLI help uses current version variable' 'XTMOE 0.4.0-dev' "$TEST_TMP/stdout"
assert_contains 'CLI help mentions PRoot' 'xtmoe proot' "$TEST_TMP/stdout"
assert_contains 'CLI help mentions unified wizard' 'xtmoe on' "$TEST_TMP/stdout"
assert_contains 'CLI help mentions unified list' 'xtmoe list' "$TEST_TMP/stdout"
assert_contains 'CLI help mentions QEMU' 'xtmoe qemu' "$TEST_TMP/stdout"
assert_contains 'CLI help mentions updater' 'xtmoe update' "$TEST_TMP/stdout"
assert_contains 'CLI help mentions program uninstall' 'xtmoe uninstall-app' "$TEST_TMP/stdout"
assert_ok 'CLI version' bash "$CLI" version
assert_contains 'CLI reports version 0.4.0-dev' 'xtmoe 0.4.0-dev' "$TEST_TMP/stdout"
assert_ok 'PRoot help' bash "$CLI" proot help
assert_ok 'Chroot setup function is defined' bash -c 'source "$1/src/lib/common.sh"; source "$1/src/lib/chroot.sh"; declare -F chroot_setup >/dev/null' _ "$ROOT_DIR"
assert_ok 'Chroot help' bash "$CLI" chroot help
assert_contains 'Chroot help mentions Docker readiness check' 'docker-check' "$TEST_TMP/stdout"
assert_contains 'Chroot help mentions nested systemd' 'systemd-check' "$TEST_TMP/stdout"
assert_contains 'Chroot help mentions Bash compatibility switch' 'use-bash-sh' "$TEST_TMP/stdout"
assert_contains 'Chroot help mentions Docker installer' 'docker-install' "$TEST_TMP/stdout"
assert_contains 'Chroot help mentions direct dockerd compatibility mode' 'docker-direct-install' "$TEST_TMP/stdout"
assert_contains 'Chroot help mentions repair workflow' 'repair' "$TEST_TMP/stdout"
assert_ok 'QEMU help' bash "$CLI" qemu help
assert_contains 'QEMU help mentions Docker test' 'docker-test' "$TEST_TMP/stdout"
old_prefix=$PREFIX
export PREFIX="$TEST_TMP/not-termux"
mkdir -p "$PREFIX/bin"
assert_fail 'Forged TERMUX_VERSION cannot bypass PREFIX validation' bash "$CLI" proot list
export PREFIX=$old_prefix
assert_fail 'QEMU non-interactive install requires explicit resources' bash "$CLI" qemu install --yes qemu-missing-resources
assert_ok 'QEMU architecture and package map on x86_64 test host' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    [[ $(qemu_arch) == amd64 ]]
    [[ $(qemu_binary_for_arch amd64) == qemu-system-x86_64 ]]
    [[ $(qemu_package_for_arch amd64) == qemu-system-x86-64-headless ]]
' _ "$ROOT_DIR"
assert_fail 'QEMU explicitly rejects ARM32' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    uname() { printf armv7l; }
    qemu_arch
' _ "$ROOT_DIR"

BOOTSTRAP_LOG="$TEST_TMP/bootstrap.log"
export BOOTSTRAP_LOG
assert_ok 'Fresh install bootstraps systemd and Bash by default' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_install_preflight() { :; }
    download_ubuntu_base() { printf /tmp/fake-ubuntu.tar.gz; }
    chroot_root() { :; }
    chroot_setup() { printf "setup\\n" >>"$BOOTSTRAP_LOG"; }
    chroot_use_bash_sh() { printf "bash\\n" >>"$BOOTSTRAP_LOG"; }
    chroot_systemd_start() { printf "start\\n" >>"$BOOTSTRAP_LOG"; }
    chroot_systemd_verify() { :; }
    chroot_install --yes --skip-docker ubuntu 24.04 bootstrap-demo
' _ "$ROOT_DIR"
[[ $(tr '\n' ' ' <"$BOOTSTRAP_LOG") == 'setup bash start ' ]] && pass 'Fresh install bootstrap order is correct' || fail 'Fresh install bootstrap order is correct'
: >"$BOOTSTRAP_LOG"
assert_ok 'Fresh install allows explicit bootstrap opt-out' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_install_preflight() { :; }
    download_ubuntu_base() { printf /tmp/fake-ubuntu.tar.gz; }
    chroot_root() { :; }
    chroot_setup() { printf "setup\\n" >>"$BOOTSTRAP_LOG"; }
    chroot_use_bash_sh() { printf "bash\\n" >>"$BOOTSTRAP_LOG"; }
    chroot_systemd_start() { printf "start\\n" >>"$BOOTSTRAP_LOG"; }
    chroot_install --yes --skip-systemd --skip-bash-sh ubuntu 24.04 bootstrap-skip
' _ "$ROOT_DIR"
[[ ! -s $BOOTSTRAP_LOG ]] && pass 'Explicit opt-out skips default bootstrap' || fail 'Explicit opt-out skips default bootstrap'

assert_ok 'PRoot install dispatch' bash "$CLI" proot install ubuntu:24.04 demo
assert_fail 'PRoot install rejects extra arguments' bash "$CLI" proot install ubuntu:24.04 demo extra
assert_contains 'PRoot install keeps image and name' 'install --name demo ubuntu:24.04' "$MOCK_LOG"
assert_ok 'PRoot exec dispatch' bash "$CLI" proot exec demo -- uname -a
assert_contains 'PRoot exec keeps argument boundary' 'login demo -- uname -a' "$MOCK_LOG"
mkdir -p "$PREFIX/var/lib/proot-distro/containers/demo/rootfs"
mkdir -p "$PREFIX/var/lib/proot-distro/containers/alpha/rootfs"
export MOCK_PROOT_PS=$'PID CONTAINER TYPE USER UPTIME COMMAND\n12345 demo login root 1m /bin/bash\n12346 demo run root 1m sleep\n'
assert_ok 'Wizard PRoot selector accepts a numbered existing container' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/proot.sh"
    source "$1/src/lib/chroot.sh"
    source "$1/src/lib/manager.sh"
    menu_select_container proot "test" <<<"2"
    [[ $MENU_SELECTED_NAME == demo ]]
' _ "$ROOT_DIR"
assert_ok 'Unified list shows running PRoot container' bash "$CLI" list --no-prompt
assert_contains 'Unified list includes running session count' 'running(2)' "$TEST_TMP/stdout"
assert_ok 'Unified enter dispatches to PRoot login' bash "$CLI" enter proot demo
assert_contains 'Unified enter preserves selected container' 'login demo' "$MOCK_LOG"
assert_ok 'PRoot status reports active sessions' bash "$CLI" proot status demo
assert_contains 'PRoot status counts active sessions' 'running sessions=2' "$TEST_TMP/stdout"
assert_ok 'PRoot system update dispatch' bash "$CLI" proot update-system demo
assert_ok 'PRoot reinstall accepts explicit confirmation' bash "$CLI" proot reinstall --yes demo
assert_contains 'PRoot reinstall uses backend reset' 'reset demo' "$MOCK_LOG"
unset MOCK_PROOT_PS
assert_fail 'PRoot invalid name rejected' bash "$CLI" proot install ubuntu:24.04 '../escape'
assert_fail 'PRoot non-interactive remove requires --yes' bash "$CLI" proot remove demo
assert_ok 'PRoot explicit remove accepted' bash "$CLI" proot remove --yes demo
assert_contains 'PRoot remove dispatched' 'remove demo' "$MOCK_LOG"
assert_fail 'Unified uninstall requires confirmation' bash "$CLI" uninstall proot demo
assert_ok 'Unified uninstall dispatches PRoot removal' bash "$CLI" uninstall --yes proot demo
assert_contains 'Unified uninstall removes requested image' 'remove demo' "$MOCK_LOG"
assert_fail 'Unified uninstall rejects unknown mode' bash "$CLI" uninstall virtual demo

mkdir -p "$XTMOE_DATA_DIR/chroot/demo/rootfs" "$XTMOE_DATA_DIR/chroot/alpha/rootfs" "$XTMOE_CONFIG_DIR/chroot" "$HOME/shared"
printf 'xtmoe-chroot-format-1\n' >"$XTMOE_DATA_DIR/chroot/demo/.xtmoe-chroot"
printf 'xtmoe-chroot-format-1\n' >"$XTMOE_DATA_DIR/chroot/alpha/.xtmoe-chroot"
assert_ok 'Wizard Chroot selector accepts a numbered existing container' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/proot.sh"
    source "$1/src/lib/chroot.sh"
    source "$1/src/lib/manager.sh"
    menu_select_container chroot "test" <<<"2"
    [[ $MENU_SELECTED_NAME == demo ]]
' _ "$ROOT_DIR"
mkdir -p "$XTMOE_DATA_DIR/qemu/qemu-demo/ssh" "$XTMOE_CONFIG_DIR/qemu"
printf 'xtmoe-qemu-format-1\n' >"$XTMOE_DATA_DIR/qemu/qemu-demo/.xtmoe-qemu"
printf 'disk\n' >"$XTMOE_DATA_DIR/qemu/qemu-demo/disk.qcow2"
printf 'seed\n' >"$XTMOE_DATA_DIR/qemu/qemu-demo/seed.iso"
printf 'private\n' >"$XTMOE_DATA_DIR/qemu/qemu-demo/ssh/id_ed25519"
printf 'public\n' >"$XTMOE_DATA_DIR/qemu/qemu-demo/ssh/id_ed25519.pub"
assert_ok 'QEMU config is written as validated data' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    qemu_write_config qemu-demo amd64 2 2048 20 2222 stopped
    : >"$(qemu_ports_file qemu-demo)"
    [[ $(qemu_config_get qemu-demo memory) == 2048 ]]
' _ "$ROOT_DIR"
assert_ok 'Wizard QEMU selector accepts a numbered existing VM' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/proot.sh"
    source "$1/src/lib/chroot.sh"
    source "$1/src/lib/qemu.sh"
    source "$1/src/lib/manager.sh"
    menu_select_container qemu "test" <<<"1"
    [[ $MENU_SELECTED_NAME == qemu-demo ]]
' _ "$ROOT_DIR"
assert_ok 'QEMU persistent port mapping validates and round-trips' bash "$CLI" qemu port-add qemu-demo 28080 80 tcp
assert_contains 'QEMU port mapping stores data, not shell' 'tcp|28080|80' "$XTMOE_CONFIG_DIR/qemu/qemu-demo.ports"
assert_ok 'QEMU persistent port mapping can be removed' bash "$CLI" qemu port-remove qemu-demo 28080 tcp
QEMU_ARG_LOG="$TEST_TMP/qemu-args.log"
export QEMU_ARG_LOG
assert_ok 'QEMU launch arguments preserve disk, NAT and TCG boundaries' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    qemu-system-x86_64() { printf "%s\n" "$@" >"$QEMU_ARG_LOG"; }
    qemu_start_with_accel qemu-demo tcg
' _ "$ROOT_DIR"
assert_contains 'QEMU launch uses exact managed disk' "file=$XTMOE_DATA_DIR/qemu/qemu-demo/disk.qcow2,format=qcow2,if=virtio" "$QEMU_ARG_LOG"
assert_contains 'QEMU launch binds SSH forwarding to localhost' 'user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22' "$QEMU_ARG_LOG"
assert_contains 'QEMU launch uses multithreaded TCG' 'tcg,thread=multi' "$QEMU_ARG_LOG"
assert_ok 'Chroot bind config accepted' bash "$CLI" chroot bind demo "$HOME/shared" /mnt/shared ro
assert_contains 'Chroot bind is data, not shell' "ro|$HOME/shared|/mnt/shared" "$XTMOE_CONFIG_DIR/chroot/demo.binds"
assert_fail 'Chroot duplicate target rejected' bash "$CLI" chroot bind demo "$HOME/shared" /mnt/shared rw
assert_fail 'Chroot relative target rejected' bash "$CLI" chroot bind demo "$HOME/shared" '../escape' rw
assert_fail 'Chroot invalid container name rejected' bash "$CLI" chroot bind '../escape' "$HOME/shared" /mnt/shared rw
assert_fail 'Chroot refuses whole host root bind' bash "$CLI" chroot bind demo / /mnt/host rw
assert_fail 'Chroot status rejects extra arguments' bash "$CLI" chroot status demo extra
assert_fail 'Chroot unbind rejects relative target' bash "$CLI" chroot unbind demo relative
assert_ok 'Chroot full install defaults to execution without reading a yes prompt' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_install_preflight() { :; }
    download_ubuntu_base() { printf /tmp/fixture.tar.gz; }
    chroot_root() { :; }
    confirm() { exit 9; }
    chroot_bootstrap() { [[ $* == *--accept-host-network-changes* ]]; }
    chroot_install ubuntu 24.04 consent-demo </dev/null
' _ "$ROOT_DIR"
assert_ok 'Chroot metadata updates atomically and remains readable' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_meta_initialize meta-demo 24.04 amd64 yes
    chroot_meta_set meta-demo state partial
    [[ $(chroot_meta_get meta-demo state) == partial ]]
    [[ $(grep -c "^state=" "$XTMOE_CONFIG_DIR/chroot/meta-demo.meta") == 1 ]]
' _ "$ROOT_DIR"
mkdir -p "$XTMOE_DATA_DIR/chroot/docker-gate/rootfs"
printf 'xtmoe-chroot-format-1\n' >"$XTMOE_DATA_DIR/chroot/docker-gate/.xtmoe-chroot"
assert_fail 'Non-interactive Chroot reinstall still requires destructive confirmation' bash "$CLI" chroot reinstall docker-gate
[[ -f $XTMOE_DATA_DIR/chroot/docker-gate/.xtmoe-chroot ]] && pass 'Rejected reinstall preserves existing Chroot' || fail 'Rejected reinstall preserves existing Chroot'
DOCKER_MUTATION_LOG="$TEST_TMP/docker-mutation.log"
export DOCKER_MUTATION_LOG
: >"$DOCKER_MUTATION_LOG"
assert_ok 'Docker hard gate returns partial status before package mutation' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    chroot_systemd_start() { :; }
    chroot_docker_kernel_check() { return 2; }
    chroot_systemd_exec() { printf "mutation\n" >>"$DOCKER_MUTATION_LOG"; }
    set +e
    chroot_docker_install --accept-host-network-changes docker-gate
    status=$?
    set -e
    [[ $status == 2 && ! -s $DOCKER_MUTATION_LOG ]]
' _ "$ROOT_DIR"
assert_ok 'Embedded Docker repository installer is valid Bash' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    parsed=0
    chroot_systemd_start() { :; }
    chroot_systemd_verify() { :; }
    chroot_docker_kernel_check() { :; }
    chroot_docker_dependencies() { :; }
    chroot_docker_compat_prepare() { :; }
    chroot_docker_check() { :; }
    chroot_systemd_exec() {
        if [[ ${3:-} == /bin/bash && ${4:-} == -lc ]]; then
            bash -n -c "$5"
            parsed=1
            return 1
        fi
        return 0
    }
    set +e
    chroot_docker_install --accept-host-network-changes docker-gate
    status=$?
    set -e
    [[ $status == 1 && $parsed == 1 ]]
' _ "$ROOT_DIR"
assert_ok 'Embedded direct Docker installer is valid Bash and avoids systemd management' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/chroot.sh"
    parsed=0
    chroot_docker_dependencies() { :; }
    chroot_docker_compat_prepare() { :; }
    chroot_exec() {
        [[ ${3:-} == /bin/bash && ${4:-} == -lc ]] || return 2
        bash -n -c "$5"
        parsed=1
    }
    chroot_systemd_stop() { :; }
    chroot_docker_direct_start() { :; }
    chroot_docker_direct_install --accept-host-network-changes docker-gate
    [[ $parsed == 1 ]]
' _ "$ROOT_DIR"

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
assert_ok 'Ubuntu Base index and starred checksum parsed' bash -c "source '$ROOT_DIR/src/lib/common.sh'; source '$ROOT_DIR/src/lib/chroot.sh'; download_ubuntu_base 24.04"
assert_contains 'Newest Ubuntu point release selected' 'ubuntu-base-24.04.5-base-amd64.tar.gz' "$TEST_TMP/stdout"
cached_ubuntu="$XTMOE_CACHE_DIR/ubuntu-base/24.04/ubuntu-base-24.04.5-base-amd64.tar.gz"
printf 'corrupted cache\n' >"$cached_ubuntu"
assert_ok 'Corrupted Ubuntu cache is downloaded again' bash -c "source '$ROOT_DIR/src/lib/common.sh'; source '$ROOT_DIR/src/lib/chroot.sh'; download_ubuntu_base 24.04"
cmp -s "$cached_ubuntu" "$MOCK_UBUNTU_ARCHIVE" && pass 'Redownloaded Ubuntu cache content verified' || fail 'Redownloaded Ubuntu cache content verified'
rm -f -- "$TEST_TMP/mock-bin/curl"

printf 'fake qemu cloud image\n' >"$TEST_TMP/qemu-cloud.img"
qemu_hash=$(sha256sum "$TEST_TMP/qemu-cloud.img" | awk '{print $1}')
printf '%s *ubuntu-24.04-server-cloudimg-amd64.img\n' "$qemu_hash" >"$TEST_TMP/qemu-sums"
export MOCK_QEMU_IMAGE="$TEST_TMP/qemu-cloud.img" MOCK_QEMU_SUMS="$TEST_TMP/qemu-sums"
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
    */SHA256SUMS) cp "$MOCK_QEMU_SUMS" "$output" ;;
    *.img) cp "$MOCK_QEMU_IMAGE" "$output" ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$TEST_TMP/mock-bin/curl"
assert_ok 'Ubuntu QEMU Cloud Image checksum is parsed and verified' bash -c "source '$ROOT_DIR/src/lib/common.sh'; source '$ROOT_DIR/src/lib/qemu.sh'; qemu_download_image amd64"
qemu_cached="$XTMOE_CACHE_DIR/qemu/ubuntu/24.04/amd64/ubuntu-24.04-server-cloudimg-amd64.img"
cmp -s "$qemu_cached" "$MOCK_QEMU_IMAGE" && pass 'QEMU Cloud Image cache content verified' || fail 'QEMU Cloud Image cache content verified'
printf 'corrupt\n' >"$qemu_cached"
assert_ok 'Corrupted QEMU Cloud Image is downloaded again' bash -c "source '$ROOT_DIR/src/lib/common.sh'; source '$ROOT_DIR/src/lib/qemu.sh'; qemu_download_image amd64"
cmp -s "$qemu_cached" "$MOCK_QEMU_IMAGE" && pass 'QEMU Cloud Image redownload verified' || fail 'QEMU Cloud Image redownload verified'
rm -f -- "$TEST_TMP/mock-bin/curl"

assert_ok 'QEMU cloud-init seed disables passwords and provisions Docker' bash -c '
    source "$1/src/lib/common.sh"
    source "$1/src/lib/qemu.sh"
    seed_dir="$2/qemu-seed"
    mkdir -p "$seed_dir"
    xorriso() {
        local output="" user_data="" argument
        while (($#)); do
            case "$1" in
                -output) output=$2; shift 2 ;;
                */user-data) user_data=$1; shift ;;
                *) shift ;;
            esac
        done
        grep -Fq "ssh_pwauth: false" "$user_data"
        grep -Fq "https://download.docker.com/linux/ubuntu" "$user_data"
        grep -Fq "usermod -aG docker xtmoe" "$user_data"
        : >"$output"
    }
    qemu_create_seed seed-demo "$seed_dir" "ssh-ed25519 AAAATEST xtmoe-test"
    [[ -f $seed_dir/seed.iso ]]
' _ "$ROOT_DIR" "$TEST_TMP"

QEMU_BACKUP_TEST="$TEST_TMP/qemu-demo-backup.tar.gz"
assert_ok 'Synthetic QEMU backup includes disk, config and SSH identity' bash "$CLI" qemu backup qemu-demo "$QEMU_BACKUP_TEST"
assert_ok 'Synthetic QEMU remove requires managed stopped VM' bash "$CLI" qemu remove --yes qemu-demo
assert_ok 'Synthetic QEMU restore validates marker, architecture and ports' bash "$CLI" qemu restore "$QEMU_BACKUP_TEST" qemu-restored
assert_ok 'Restored QEMU VM reports stopped state' bash "$CLI" qemu status qemu-restored
assert_contains 'Restored QEMU VM state is stopped' 'stopped' "$TEST_TMP/stdout"
assert_ok 'Synthetic restored QEMU VM can be removed' bash "$CLI" qemu remove --yes qemu-restored

source "$ROOT_DIR/tests/audit.sh"
source "$ROOT_DIR/tests/chroot-init.sh"
source "$ROOT_DIR/tests/docker-runtime.sh"
source "$ROOT_DIR/tests/menus.sh"

cat >"$TEST_TMP/mock-bin/id" <<'MOCK'
#!/usr/bin/env bash
[[ ${XTMOE_TEST_ROOT:-0} == 1 && ${1:-} == -u ]] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
MOCK
chmod +x "$TEST_TMP/mock-bin/id"
cp "$(command -v bash)" "$PREFIX/bin/bash"
assert_fail 'Root helper rejects arbitrary base path' env XTMOE_TEST_ROOT=1 bash "$ROOT_HELPER" "$PREFIX" status /tmp demo
assert_contains 'Root helper reports protected path' '拒绝操作非 XTMOE Chroot 目录' "$TEST_TMP/stderr"
codec_input=$'/tmp/a b\\c\td'
assert_ok 'Mount table path codec handles spaces, tabs and backslashes' env XTMOE_TEST_ROOT=1 XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-path-codec "$codec_input"
[[ $(tail -n 1 "$TEST_TMP/stdout") == "$codec_input" ]] && pass 'Mount table path codec round-trips exactly' || fail 'Mount table path codec round-trips exactly'
assert_fail 'Root helper rejects manually configured host root bind' env XTMOE_TEST_ROOT=1 XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-mount-source-check /
assert_contains 'Root helper enforces dangerous source policy' '拒绝挂载整个宿主根目录或 /data' "$TEST_TMP/stderr"
if grep -Fq "trap 'exit 130' INT" "$ROOT_HELPER"; then
    fail 'Interactive login must not trap Ctrl+C as container exit'
else
    pass 'Interactive login leaves Ctrl+C to the container shell'
fi
assert_contains 'Interactive login allocates a PTY' '"$script_bin" -q -e /dev/null --' "$ROOT_HELPER"
assert_contains 'Systemd mounts proc inside its PID namespace' 'mount -t proc proc /proc' "$ROOT_HELPER"
assert_contains 'Systemd startup avoids inherited parent proc mount' 'mount_all "$config" 0' "$ROOT_HELPER"
assert_contains 'Systemd mounts are prepared by namespaced launcher' '_systemd-launch "$BASE" "$CONTAINER_NAME" "$config"' "$ROOT_HELPER"
assert_contains 'Systemd replaces launcher helper before process discovery' 'exec chroot "$ROOTFS" /usr/bin/env -i' "$ROOT_HELPER"
assert_contains 'Chroot login reuses running systemd session' 'systemd_login' "$ROOT_HELPER"
assert_contains 'Unified Chroot stop stops nested systemd' 'systemd_stop' "$ROOT_HELPER"
assert_contains 'Docker gate checks network namespace creation' 'namespace_check --net network' "$ROOT_HELPER"
assert_contains 'Docker gate requires pids controller' 'pids cgroup controller' "$ROOT_HELPER"
assert_contains 'Systemd stop orders Docker shutdown first' 'systemctl stop docker.service containerd.service' "$ROOT_HELPER"
assert_contains 'Direct Docker launch uses explicit iptables mode' '--iptables=true --host=unix:///var/run/docker.sock' "$ROOT_HELPER"
assert_contains 'Direct Docker bounds daemon API verification' 'direct_docker_exec /usr/bin/timeout 15 /usr/bin/docker info' "$ROOT_HELPER"
assert_contains 'Direct Docker run test verifies a real container' 'docker run --rm hello-world' "$ROOT_HELPER"

rootfs_fixture_lifecycle() {
    local fixture="$TEST_TMP/rootfs-fixture" archive="$TEST_TMP/rootfs-fixture.tar.gz"
    local base="$XTMOE_DATA_DIR/chroot"
    local backup="$TEST_TMP/rootfs-backup.tar.gz"
    mkdir -p "$fixture/usr/bin" "$fixture/etc" "$base"
    printf '#!/usr/bin/bash\nexit 0\n' >"$fixture/usr/bin/bash"
    chmod +x "$fixture/usr/bin/bash"
    ln -s /usr/bin/bash "$fixture/usr/bin/sh"
    ln -s usr/bin "$fixture/bin"
    printf 'ubuntu\n' >"$fixture/etc/hostname"
    printf '10.0.0.1 example.test example\n127.0.0.1 android-test\n' >"$fixture/etc/hosts"
    tar -czpf "$archive" -C "$fixture" .

    local repair_rootfs="$TEST_TMP/existing-rootfs"
    mkdir -p "$repair_rootfs/etc"
    printf 'old-host\n' >"$repair_rootfs/etc/hostname"
    printf '10.0.0.1 existing.test\n' >"$repair_rootfs/etc/hosts"
    env XTMOE_TEST_ROOT=1 XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-hosts-config "$repair_rootfs"
    grep -qx 'localhost' "$repair_rootfs/etc/hostname"
    grep -qE '^127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' "$repair_rootfs/etc/hosts"
    grep -qx '10.0.0.1 existing.test' "$repair_rootfs/etc/hosts"

    local escape_rootfs="$TEST_TMP/escape-rootfs" outside_exec="$TEST_TMP/outside-exec" root_link="$TEST_TMP/root-link"
    mkdir -p "$escape_rootfs/usr/bin"
    printf '#!/usr/bin/bash\nexit 0\n' >"$outside_exec"
    chmod +x "$outside_exec"
    ln -s ../../../outside-exec "$escape_rootfs/usr/bin/sh"
    if [[ -L $escape_rootfs/usr/bin/sh ]] && env XTMOE_TEST_ROOT=1 XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-rootfs-shell-check "$escape_rootfs"; then
        return 1
    fi
    ln -s / "$root_link"
    if [[ -L $root_link ]] && env XTMOE_TEST_ROOT=1 XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-mount-source-check "$root_link"; then
        return 1
    fi

    export XTMOE_TEST_ROOT=1
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" install "$base" fixture "$archive" 223.5.5.5
    if [[ -L $base/fixture/rootfs/usr/bin/sh ]]; then
        [[ $(readlink "$base/fixture/rootfs/usr/bin/sh") == /usr/bin/bash ]]
    else
        [[ -x $base/fixture/rootfs/usr/bin/sh ]]
    fi
    env XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-rootfs-shell-check "$base/fixture/rootfs"
    grep -qx 'xtmoe-chroot-format-1' "$base/fixture/.xtmoe-chroot"
    grep -qx 'localhost' "$base/fixture/rootfs/etc/hostname"
    grep -qE '^127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' "$base/fixture/rootfs/etc/hosts"
    grep -qE '^::1[[:space:]]+localhost([[:space:]]|$)' "$base/fixture/rootfs/etc/hosts"
    grep -qx '10.0.0.1 example.test example' "$base/fixture/rootfs/etc/hosts"
    grep -qx 'hosts: files dns' "$base/fixture/rootfs/etc/nsswitch.conf"
    grep -qx 'nameserver 223.5.5.5' "$base/fixture/rootfs/etc/resolv.conf"
    [[ $(PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" status "$base" fixture) == stopped ]]
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" stop "$base" fixture
    if PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" stop "$base" missing; then
        return 1
    fi
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
    env XTMOE_INTERNAL_TEST=1 bash "$ROOT_HELPER" "$PREFIX" _internal-rootfs-shell-check "$base/restored/rootfs"
    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" remove "$base" restored

    local bad_fixture="$TEST_TMP/bad-rootfs" bad_archive="$TEST_TMP/bad-rootfs.tar.gz"
    mkdir -p "$bad_fixture/rootfs/usr/bin"
    printf '#!/usr/bin/bash\nexit 0\n' >"$bad_fixture/rootfs/usr/bin/bash"
    chmod +x "$bad_fixture/rootfs/usr/bin/bash"
    ln -s /usr/bin/bash "$bad_fixture/rootfs/usr/bin/sh"
    printf 'not-a-valid-marker\n' >"$bad_fixture/.xtmoe-chroot"
    tar -czpf "$bad_archive" -C "$bad_fixture" .
    if PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" restore "$base" bad-marker "$bad_archive"; then
        return 1
    fi
    ln -s "$backup" "$backup.link"
    if [[ -L $backup.link ]]; then
        if PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" restore "$base" bad-link "$backup.link"; then
            return 1
        fi
    fi

    PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT_HELPER" "$PREFIX" install "$base" uninstall-demo "$archive" 223.5.5.5
    unset XTMOE_TEST_ROOT
    PATH="$TEST_TMP/mock-bin:$PATH" XTMOE_YES=1 bash "$CLI" uninstall chroot uninstall-demo
    [[ ! -e $base/uninstall-demo ]]
}
assert_ok 'Synthetic rootfs lifecycle and unified Chroot uninstall' rootfs_fixture_lifecycle
rm -f -- "$TEST_TMP/mock-bin/id"

export XTMOE_SKIP_PACKAGES=1
export XTMOE_ALLOW_NON_TERMUX=1
assert_ok 'Local installer completes' sh "$ROOT_DIR/termux.sh"
[[ -x "$PREFIX/bin/xtmoe" ]] && pass 'Installer creates executable command' || fail 'Installer creates executable command'
[[ -r "$PREFIX/libexec/xtmoe/lib/chroot.sh" ]] && pass 'Installer copies libraries' || fail 'Installer copies libraries'
[[ -r "$PREFIX/libexec/xtmoe/lib/manager.sh" ]] && pass 'Installer copies unified manager module' || fail 'Installer copies unified manager module'
[[ -r "$PREFIX/libexec/xtmoe/lib/qemu.sh" ]] && pass 'Installer copies QEMU module' || fail 'Installer copies QEMU module'
[[ -r "$PREFIX/libexec/xtmoe/lib/xtmoe-docker-routing" && -r "$PREFIX/libexec/xtmoe/lib/xtmoe-docker-routing.service" ]] && pass 'Installer copies Docker routing helper and service' || fail 'Installer copies Docker routing helper and service'
[[ $(<"$PREFIX/libexec/xtmoe/source-root") == "$ROOT_DIR" ]] && pass 'Installer records source root' || fail 'Installer records source root'
if compgen -G "$PREFIX/bin/xtmoe.tmp.*" >/dev/null || compgen -G "$PREFIX/libexec/xtmoe/*.tmp.*" >/dev/null; then
    fail 'Installer leaves no temporary files'
else
    pass 'Installer leaves no temporary files'
fi

cp "$PREFIX/bin/xtmoe" "$PREFIX/bin/xtmoe.saved"
printf '#!/usr/bin/env bash\nprintf "xtmoe 0.0.0-stale\\n"\n' >"$PREFIX/bin/xtmoe"
chmod +x "$PREFIX/bin/xtmoe"
assert_fail 'Doctor rejects stale installed command' bash "$CLI" doctor
assert_contains 'Doctor explains source/install mismatch' '源码与已安装命令版本不一致' "$TEST_TMP/stderr"
mv -f -- "$PREFIX/bin/xtmoe.saved" "$PREFIX/bin/xtmoe"

cat >"$TEST_TMP/mock-bin/git" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_GIT_LOG"
case "$*" in
    *'status --porcelain'*)
        [[ ${MOCK_GIT_DIRTY:-0} == 1 ]] && printf ' M src/bin/xtmoe\n'
        exit 0
        ;;
    *'pull --ff-only'*) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TEST_TMP/mock-bin/git"
export MOCK_GIT_LOG="$TEST_TMP/git.log"
: >"$MOCK_GIT_LOG"
assert_ok 'Self-update refreshes source and installed copy' bash "$PREFIX/bin/xtmoe" update
assert_contains 'Self-update uses fast-forward-only pull' 'pull --ff-only' "$MOCK_GIT_LOG"
export MOCK_GIT_DIRTY=1
assert_fail 'Self-update refuses dirty tracked source' bash "$PREFIX/bin/xtmoe" update
unset MOCK_GIT_DIRTY
rm -f -- "$TEST_TMP/mock-bin/git"

assert_ok 'Doctor verifies installed and source versions' bash "$PREFIX/bin/xtmoe" doctor
assert_contains 'Doctor reports installed command path' '已安装命令：' "$TEST_TMP/stdout"
assert_contains 'Doctor reports source root' '源码目录：' "$TEST_TMP/stdout"

proot_actions=$(grep -rhoE 'xtmoe[[:space:]]+proot[[:space:]]+[a-z-]+' "$README_FILE" "$ROOT_DIR/docs" | awk '{print $3}' | sort -u)
for action in $proot_actions; do
    case "$action" in
        install|login|exec|list|ps|stop|backup|restore|update-system|reinstall|status|remove|raw) ;;
        *) fail "Documentation references unknown PRoot action: $action" ;;
    esac
done
pass 'Documented PRoot actions map to CLI'

chroot_actions=$(grep -rhoE 'xtmoe[[:space:]]+chroot[[:space:]]+[a-z-]+' "$README_FILE" "$ROOT_DIR/docs" | awk '{print $3}' | sort -u)
for action in $chroot_actions; do
    case "$action" in
        prepare|install|login|exec|setup|init|repair|update-system|reinstall|network-check|cgroup-check|docker-check|docker-install|docker-start|docker-stop|docker-restart|docker-status|docker-logs|docker-direct-install|docker-direct-start|docker-direct-stop|docker-direct-status|docker-direct-logs|docker-direct-run-test|systemd-check|systemd-start|systemd-login|systemd-exec|systemd-status|systemd-stop|use-bash-sh|status|list|stop|bind|unbind|backup|restore|remove) ;;
        *) fail "Documentation references unknown Chroot action: $action" ;;
    esac
done
pass 'Documented Chroot actions map to CLI'

qemu_actions=$(grep -rhoE 'xtmoe[[:space:]]+qemu[[:space:]]+[a-z-]+' "$README_FILE" "$ROOT_DIR/docs" | awk '{print $3}' | sort -u)
for action in $qemu_actions; do
    case "$action" in
        prepare|install|start|wait-ready|console|ssh|exec|status|list|stop|update-system|docker-status|docker-test|ports|port-add|port-remove|backup|restore|reinstall|remove) ;;
        *) fail "Documentation references unknown QEMU action: $action" ;;
    esac
done
pass 'Documented QEMU actions map to CLI'

for doc in INSTALL PROOT CHROOT QEMU OPERATIONS TROUBLESHOOTING ROADMAP; do
    [[ -r "$ROOT_DIR/docs/$doc.md" ]] || fail "Missing documentation: $doc.md"
done
pass 'README documentation targets exist'

top_actions=$(grep -rhoE 'xtmoe[[:space:]]+[a-z][a-z-]*' "$README_FILE" "$ROOT_DIR/docs" "$ROOT_DIR/tests/README.md" | awk '{print $2}' | sort -u)
for action in $top_actions; do
    case "$action" in
        doctor|on|list|enter|proot|chroot|qemu|uninstall|update|uninstall-app|version|help) ;;
        *) fail "Documentation references unknown top-level action: $action" ;;
    esac
done
pass 'Documented top-level actions map to CLI'

if grep -R -q --include='*.sh' --include='*.md' 'xzmore' "$ROOT_DIR/src" "$ROOT_DIR/termux.sh"; then
    fail 'Runtime has no xzmore dependency'
else
    pass 'Runtime has no xzmore dependency'
fi

assert_fail 'Program uninstall requires confirmation' bash "$PREFIX/bin/xtmoe" uninstall-app
assert_ok 'Program uninstall preserves user data' bash "$PREFIX/bin/xtmoe" uninstall-app --yes
[[ ! -e "$PREFIX/bin/xtmoe" && ! -e "$PREFIX/libexec/xtmoe" ]] && pass 'Program uninstall removes installed files' || fail 'Program uninstall removes installed files'
[[ -d "$XTMOE_DATA_DIR" ]] && pass 'Program uninstall keeps container data directory' || fail 'Program uninstall keeps container data directory'

printf '# tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
