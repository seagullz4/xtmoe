#!/data/data/com.termux/files/usr/bin/bash

qemu_help() {
    cat <<'EOF'
QEMU 完整虚拟机模式（独立 Linux 内核；ARM64/x86_64 Ubuntu 24.04）

  xtmoe qemu prepare
  xtmoe qemu install [--yes] [--cpus N] [--memory MiB] [--disk-size GiB] [--ssh-port PORT] [名称]
  xtmoe qemu start [名称]
  xtmoe qemu wait-ready [--timeout SECONDS] [名称]
  xtmoe qemu console [名称]
  xtmoe qemu ssh [名称]
  xtmoe qemu exec <名称> -- <命令>
  xtmoe qemu status [名称]
  xtmoe qemu list
  xtmoe qemu stop [--force] [名称]
  xtmoe qemu update-system [名称]
  xtmoe qemu docker-status [名称]
  xtmoe qemu docker-test [名称]
  xtmoe qemu ports [名称]
  xtmoe qemu port-add <名称> <宿主端口> <客体端口> [tcp|udp]
  xtmoe qemu port-remove <名称> <宿主端口> [tcp|udp]
  xtmoe qemu backup <名称> [文件]
  xtmoe qemu restore <文件> [名称]
  xtmoe qemu reinstall [--yes] [名称]
  xtmoe qemu remove [--yes] <名称>

QEMU 默认使用同架构 Ubuntu Cloud Image。没有 KVM 时回退到 TCG，速度会明显变慢。
EOF
}

qemu_base() { printf '%s/qemu' "$XTMOE_DATA_DIR"; }
qemu_config_base() { printf '%s/qemu' "$XTMOE_CONFIG_DIR"; }
qemu_cache_base() { printf '%s/qemu/ubuntu/24.04' "$XTMOE_CACHE_DIR"; }
qemu_vm_dir() { require_name "$1"; printf '%s/%s' "$(qemu_base)" "$1"; }
qemu_config_file() { require_name "$1"; printf '%s/%s.conf' "$(qemu_config_base)" "$1"; }
qemu_ports_file() { require_name "$1"; printf '%s/%s.ports' "$(qemu_config_base)" "$1"; }

qemu_validate_config_file() {
    local file=$1 key value extra
    local -A seen=()
    [[ -f $file && ! -L $file ]] || return 1
    while IFS='=' read -r key value extra; do
        [[ -n $key && -n $value && -z $extra && ! ${seen[$key]+set} ]] || return 1
        seen[$key]=1
        case "$key" in
            arch) [[ $value == arm64 || $value == amd64 ]] || return 1 ;;
            cpus) [[ $value =~ ^[1-8]$ ]] || return 1 ;;
            memory) [[ $value =~ ^[1-9][0-9]{3,4}$ ]] && ((value >= 1024 && value <= 32768)) || return 1 ;;
            disk_size) [[ $value =~ ^[1-9][0-9]{1,2}$ ]] && ((value >= 10 && value <= 512)) || return 1 ;;
            ssh_port) [[ $value =~ ^[1-9][0-9]{0,4}$ ]] && ((value <= 65535)) || return 1 ;;
            state|init_state|docker_state) [[ $value =~ ^[a-z][a-z-]{0,63}$ ]] || return 1 ;;
            accelerator) [[ $value == tcg || $value == kvm ]] || return 1 ;;
            *) return 1 ;;
        esac
    done <"$file"
    for key in arch cpus memory disk_size ssh_port state; do
        [[ ${seen[$key]+set} ]] || return 1
    done
}

qemu_validate_ports_file() {
    local file=$1 ssh_port=$2 protocol host guest extra
    local -A seen=()
    [[ -f $file && ! -L $file ]] || return 1
    while IFS='|' read -r protocol host guest extra; do
        [[ -z $protocol && -z $host && -z $guest && -z $extra ]] && continue
        [[ $protocol == tcp || $protocol == udp ]] || return 1
        [[ $host =~ ^[1-9][0-9]{0,4}$ && $guest =~ ^[1-9][0-9]{0,4}$ && -z $extra ]] || return 1
        ((host <= 65535 && guest <= 65535)) || return 1
        [[ $host != "$ssh_port" && ! ${seen[$protocol/$host]+set} ]] || return 1
        seen[$protocol/$host]=1
    done <"$file"
}

qemu_arch() {
    case "$(uname -m)" in
        aarch64|arm64) printf 'arm64' ;;
        x86_64|amd64) printf 'amd64' ;;
        armv7l|armv8l|arm|i686|i386) die 'QEMU 完整虚拟机首版仅支持 ARM64 和 x86_64；当前设备不受支持。' ;;
        *) die "无法识别 QEMU 宿主架构：$(uname -m)" ;;
    esac
}

qemu_binary_for_arch() {
    case "$1" in
        arm64) printf 'qemu-system-aarch64' ;;
        amd64) printf 'qemu-system-x86_64' ;;
        *) die "不支持的 QEMU 架构：$1" ;;
    esac
}

qemu_package_for_arch() {
    case "$1" in
        arm64) printf 'qemu-system-aarch64-headless' ;;
        amd64) printf 'qemu-system-x86-64-headless' ;;
        *) die "不支持的 QEMU 架构：$1" ;;
    esac
}

qemu_require() {
    require_termux
    local arch binary
    arch=$(qemu_arch); binary=$(qemu_binary_for_arch "$arch")
    require_command "$binary" '执行 xtmoe qemu prepare'
    for binary in qemu-img ssh ssh-keygen socat xorriso ss timeout; do
        require_command "$binary" '执行 xtmoe qemu prepare'
    done
}

qemu_prepare() {
    (($# == 0)) || die 'xtmoe qemu prepare 不接受额外参数'
    require_termux
    require_command pkg '请使用官方 Termux 客户端'
    local arch package
    arch=$(qemu_arch); package=$(qemu_package_for_arch "$arch")
    info "安装 QEMU $arch 依赖；软件包较大，请保持网络稳定……"
    pkg install -y "$package" qemu-utils xorriso openssh socat curl coreutils iproute2
    qemu_require
    ok "QEMU 依赖已就绪：$(qemu_binary_for_arch "$arch")"
}

qemu_vm_exists() {
    local name=$1 dir config ports arch
    valid_name "$name" || return 1
    dir=$(qemu_vm_dir "$name")
    config=$(qemu_config_file "$name"); ports=$(qemu_ports_file "$name")
    [[ -d $dir && ! -L $dir && -f $dir/.xtmoe-qemu && ! -L $dir/.xtmoe-qemu ]] || return 1
    grep -qx 'xtmoe-qemu-format-1' "$dir/.xtmoe-qemu" || return 1
    [[ -f $dir/disk.qcow2 && ! -L $dir/disk.qcow2 && -f $dir/seed.iso && ! -L $dir/seed.iso ]] || return 1
    [[ -d $dir/ssh && ! -L $dir/ssh && -f $dir/ssh/id_ed25519 && ! -L $dir/ssh/id_ed25519 && -f $dir/ssh/id_ed25519.pub && ! -L $dir/ssh/id_ed25519.pub ]] || return 1
    [[ -f $config && ! -L $config && -f $ports && ! -L $ports ]] || return 1
    qemu_validate_config_file "$config" || return 1
    qemu_validate_ports_file "$ports" "$(qemu_config_get "$name" ssh_port)" || return 1
    arch=$(qemu_config_get "$name" arch)
    if [[ $arch == arm64 ]]; then
        [[ -f $dir/firmware-code.path && ! -L $dir/firmware-code.path && -f $dir/firmware-vars.fd && ! -L $dir/firmware-vars.fd ]]
    else
        [[ $arch == amd64 ]]
    fi
}

qemu_config_get() {
    local name=$1 key=$2 file
    file=$(qemu_config_file "$name")
    [[ -r $file ]] || return 1
    awk -F= -v expected="$key" '$1 == expected { sub(/^[^=]*=/, ""); print; found=1; exit } END { exit !found }' "$file"
}

qemu_write_config() {
    local name=$1 arch=$2 cpus=$3 memory=$4 disk_size=$5 ssh_port=$6 state=$7 file tmp
    file=$(qemu_config_file "$name"); tmp="$file.tmp.$$"
    mkdir -p "$(dirname -- "$file")"
    printf 'arch=%s\ncpus=%s\nmemory=%s\ndisk_size=%s\nssh_port=%s\nstate=%s\ninit_state=initializing\ndocker_state=unknown\n' \
        "$arch" "$cpus" "$memory" "$disk_size" "$ssh_port" "$state" >"$tmp"
    mv -f -- "$tmp" "$file"
}

qemu_config_set() {
    local name=$1 key=$2 value=$3 file tmp
    [[ $key =~ ^[a-z][a-z0-9_]*$ && $value != *$'\n'* ]] || die '非法 QEMU 配置数据。'
    file=$(qemu_config_file "$name"); tmp="$file.tmp.$$"
    [[ -r $file ]] || die "QEMU 配置不存在：$name"
    awk -F= -v expected="$key" '$1 != expected' "$file" >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv -f -- "$tmp" "$file"
}

qemu_validate_uint() {
    local value=$1 minimum=$2 maximum=$3 label=$4
    [[ $value =~ ^[1-9][0-9]{0,8}$ ]] || die "$label 必须是无前导零的正整数。"
    ((value >= minimum && value <= maximum)) || die "$label 必须在 $minimum 到 $maximum 之间。"
}

qemu_prompt_value() {
    local prompt=$1 default=$2 value
    printf '%s [%s]：' "$prompt" "$default" >&2
    IFS= read -r value
    printf '%s' "${value:-$default}"
}

qemu_port_in_use() {
    local port=$1 protocol=${2:-tcp}
    if command_exists ss; then
        case "$protocol" in
            tcp) ss -ltn 2>/dev/null ;;
            udp) ss -lun 2>/dev/null ;;
            *) return 1 ;;
        esac | awk -v p=":$port" '$4 ~ p "$" { found=1 } END { exit !found }'
    else
        return 1
    fi
}

qemu_port_reserved() {
    local port=$1 exclude=${2:-} file configured
    for file in "$(qemu_config_base)"/*.conf; do
        [[ -r $file ]] || continue
        [[ -n $exclude && $file == "$(qemu_config_file "$exclude")" ]] && continue
        configured=$(awk -F= '$1 == "ssh_port" { print $2; exit }' "$file")
        [[ $configured == "$port" ]] && return 0
    done
    for file in "$(qemu_config_base)"/*.ports; do
        [[ -r $file ]] || continue
        [[ -n $exclude && $file == "$(qemu_ports_file "$exclude")" ]] && continue
        awk -F'|' -v p="$port" '$2 == p { found=1 } END { exit !found }' "$file" && return 0
    done
    return 1
}

qemu_next_ssh_port() {
    local port
    for ((port = 2222; port <= 2299; port++)); do
        qemu_port_reserved "$port" && continue
        qemu_port_in_use "$port" tcp && continue
        printf '%s' "$port"
        return 0
    done
    die '2222–2299 没有可用的 QEMU SSH 端口。'
}

qemu_download_image() {
    local arch=$1 cache base_url filename sums image line
    cache="$(qemu_cache_base)/$arch"
    base_url='https://cloud-images.ubuntu.com/releases/24.04/release'
    case "$arch" in
        arm64) filename='ubuntu-24.04-server-cloudimg-arm64.img' ;;
        amd64) filename='ubuntu-24.04-server-cloudimg-amd64.img' ;;
    esac
    mkdir -p "$cache"
    sums="$cache/SHA256SUMS"; image="$cache/$filename"
    info '下载 Ubuntu Cloud Image 校验清单……' >&2
    curl -fL --retry 3 --connect-timeout 20 -o "$sums" "$base_url/SHA256SUMS"
    line=$(awk -v expected="$filename" '$2 == expected || $2 == "*" expected { print; exit }' "$sums")
    [[ -n $line ]] || die "SHA256SUMS 中没有 $filename"
    if [[ -s $image ]] && (cd "$cache" && printf '%s\n' "$line" | sha256sum -c -) >&2; then
        printf '%s' "$image"
        return 0
    fi
    [[ ! -e $image ]] || { warn "缓存镜像校验失败，将重新下载：$image"; rm -f -- "$image"; }
    info "下载 $filename（约 600 MiB）……" >&2
    curl -fL --retry 3 --connect-timeout 20 --continue-at - -o "$image" "$base_url/$filename"
    (cd "$cache" && printf '%s\n' "$line" | sha256sum -c -) >&2
    printf '%s' "$image"
}

qemu_create_seed() {
    local name=$1 dir=$2 public_key=$3 seed_dir
    seed_dir="$dir/.seed.$$"
    mkdir -p "$seed_dir"
    printf 'instance-id: xtmoe-%s\nlocal-hostname: %s\n' "$name" "$name" >"$seed_dir/meta-data"
    {
        printf '#cloud-config\n'
        printf 'users:\n  - default\n  - name: xtmoe\n    groups: [sudo]\n    shell: /bin/bash\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    lock_passwd: true\n    ssh_authorized_keys:\n      - %s\n' "$public_key"
        cat <<'CLOUD'
ssh_pwauth: false
disable_root: true
package_update: true
packages:
  - ca-certificates
  - curl
write_files:
  - path: /usr/local/sbin/xtmoe-firstboot
    permissions: '0755'
    content: |
      #!/bin/bash
      set -Eeuo pipefail
      trap 'touch /var/lib/xtmoe/bootstrap.failed' ERR
      install -m 0755 -d /etc/apt/keyrings /var/lib/xtmoe
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      . /etc/os-release
      arch=$(dpkg --print-architecture)
      printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "${UBUNTU_CODENAME:-$VERSION_CODENAME}" "$arch" >/etc/apt/sources.list.d/docker.sources
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      usermod -aG docker xtmoe
      systemctl enable --now containerd.service docker.service
      docker info >/var/lib/xtmoe/docker-info.txt
      touch /var/lib/xtmoe/bootstrap.done
runcmd:
  - [bash, -lc, '/usr/local/sbin/xtmoe-firstboot >/var/log/xtmoe-firstboot.log 2>&1']
CLOUD
    } >"$seed_dir/user-data"
    xorriso -as mkisofs -quiet -output "$dir/seed.iso" -volid cidata -joliet -rock \
        "$seed_dir/user-data" "$seed_dir/meta-data"
    rm -rf -- "$seed_dir"
}

qemu_find_firmware() {
    local candidate="$PREFIX/share/qemu/edk2-aarch64-code.fd"
    [[ -r $candidate ]] && { printf '%s' "$candidate"; return 0; }
    return 1
}

qemu_find_vars_firmware() {
    local candidate
    for candidate in \
        "$PREFIX/share/qemu/edk2-arm-vars.fd" \
        "$PREFIX/share/qemu/edk2-aarch64-vars.fd"; do
        [[ -r $candidate ]] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

qemu_install() (
    set -Eeuo pipefail
    local yes=0 cpus='' memory='' disk_size='' ssh_port='' name=ubuntu-qemu name_set=0
    local arch image dir partial public_key firmware vars_firmware available_kb cleanup_command total_memory_mb safe_memory_mb
    while (($#)); do
        case "$1" in
            --yes|-y) yes=1 ;;
            --cpus) cpus=${2:?--cpus 缺少值}; shift ;;
            --memory) memory=${2:?--memory 缺少值}; shift ;;
            --disk-size) disk_size=${2:?--disk-size 缺少值}; shift ;;
            --ssh-port) ssh_port=${2:?--ssh-port 缺少值}; shift ;;
            -*) die "未知 QEMU 安装参数：$1" ;;
            *) ((name_set == 0)) || die 'QEMU install 只接受一个名称'; name=$1; name_set=1 ;;
        esac
        shift
    done
    require_name "$name"; require_termux
    if [[ ! -t 0 || ${XTMOE_QEMU_INTERNAL_NONINTERACTIVE:-0} == 1 ]]; then
        [[ -n $cpus && -n $memory && -n $disk_size ]] || die '非交互安装必须提供 --cpus、--memory 和 --disk-size。'
    else
        cpus=$(qemu_prompt_value 'QEMU CPU 核数' "${cpus:-2}")
        memory=$(qemu_prompt_value 'QEMU 内存（MiB）' "${memory:-2048}")
        disk_size=$(qemu_prompt_value 'QEMU 磁盘（GiB）' "${disk_size:-20}")
        [[ -n $ssh_port ]] || ssh_port=$(qemu_next_ssh_port)
        ssh_port=$(qemu_prompt_value 'QEMU SSH 宿主端口' "$ssh_port")
    fi
    [[ -n $ssh_port ]] || ssh_port=$(qemu_next_ssh_port)
    qemu_validate_uint "$cpus" 1 8 'CPU 核数'
    qemu_validate_uint "$memory" 1024 32768 '内存 MiB'
    qemu_validate_uint "$disk_size" 10 512 '磁盘 GiB'
    qemu_validate_uint "$ssh_port" 1 65535 'SSH 端口'
    qemu_port_reserved "$ssh_port" && die "SSH 端口已被其他 XTMOE VM 使用：$ssh_port"
    qemu_port_in_use "$ssh_port" tcp && die "SSH 端口正在监听：$ssh_port"
    total_memory_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null || true)
    if [[ $total_memory_mb =~ ^[0-9]+$ && $total_memory_mb -gt 0 ]]; then
        safe_memory_mb=$((total_memory_mb * 3 / 4))
        ((memory <= safe_memory_mb)) || die "VM 内存 $memory MiB 超过当前可用内存安全上限 $safe_memory_mb MiB（MemAvailable 的 75%）。"
    fi
    ((yes)) && export XTMOE_YES=1
    confirm "创建 QEMU VM '$name'？将下载约 600 MiB 镜像并创建 ${disk_size} GiB 稀疏磁盘" || { info '已取消'; return 0; }
    if ! command_exists "$(qemu_binary_for_arch "$(qemu_arch)")" || ! command_exists xorriso || ! command_exists qemu-img || ! command_exists socat; then
        qemu_prepare
    fi
    qemu_require; ensure_dirs
    arch=$(qemu_arch); dir=$(qemu_vm_dir "$name")
    [[ ! -e $dir && ! -L $dir && ! -e $(qemu_config_file "$name") && ! -L $(qemu_config_file "$name") && ! -e $(qemu_ports_file "$name") && ! -L $(qemu_ports_file "$name") ]] || die "QEMU VM 或配置已存在：$name"
    available_kb=$(df -Pk "$XTMOE_HOME" | awk 'NR == 2 { print $4 }')
    [[ $available_kb =~ ^[0-9]+$ && $available_kb -ge 1048576 ]] || die '可用空间低于 1 GiB，拒绝创建 QEMU VM。'
    image=$(qemu_download_image "$arch")
    partial="$(qemu_base)/.${name}.partial.$$"
    mkdir -p "$partial/ssh" "$(qemu_config_base)"
    printf -v cleanup_command 'rm -rf -- %q; rm -f -- %q %q' "$partial" "$(qemu_config_file "$name")" "$(qemu_ports_file "$name")"
    # shellcheck disable=SC2064 # The validated path is intentionally frozen now.
    trap "$cleanup_command" EXIT
    info '创建独立 qcow2 系统盘……'
    qemu-img convert -p -O qcow2 "$image" "$partial/disk.qcow2"
    qemu-img resize "$partial/disk.qcow2" "${disk_size}G"
    if [[ -n ${XTMOE_QEMU_REUSE_KEY_DIR:-} && -r $XTMOE_QEMU_REUSE_KEY_DIR/id_ed25519 && -r $XTMOE_QEMU_REUSE_KEY_DIR/id_ed25519.pub ]]; then
        cp -- "$XTMOE_QEMU_REUSE_KEY_DIR/id_ed25519" "$XTMOE_QEMU_REUSE_KEY_DIR/id_ed25519.pub" "$partial/ssh/"
    else
        ssh-keygen -q -t ed25519 -N '' -C "xtmoe-qemu-$name" -f "$partial/ssh/id_ed25519"
    fi
    chmod 0600 "$partial/ssh/id_ed25519"
    public_key=$(<"$partial/ssh/id_ed25519.pub")
    [[ $public_key == ssh-ed25519\ * && $public_key != *$'\n'* ]] || die '生成的 SSH 公钥无效。'
    qemu_create_seed "$name" "$partial" "$public_key"
    if [[ $arch == arm64 ]]; then
        firmware=$(qemu_find_firmware || true)
        vars_firmware=$(qemu_find_vars_firmware || true)
        [[ -n $firmware && -n $vars_firmware ]] || die '缺少 ARM64 UEFI code/vars 固件；请重新执行 xtmoe qemu prepare。'
        printf '%s\n' "$firmware" >"$partial/firmware-code.path"
        cp -- "$vars_firmware" "$partial/firmware-vars.fd"
    fi
    printf 'xtmoe-qemu-format-1\n' >"$partial/.xtmoe-qemu"
    if [[ -n ${XTMOE_QEMU_REUSE_PORTS_FILE:-} && -r $XTMOE_QEMU_REUSE_PORTS_FILE ]]; then
        cp -- "$XTMOE_QEMU_REUSE_PORTS_FILE" "$(qemu_ports_file "$name")"
    else
        : >"$(qemu_ports_file "$name")"
    fi
    qemu_write_config "$name" "$arch" "$cpus" "$memory" "$disk_size" "$ssh_port" initializing
    mv -- "$partial" "$dir"
    trap - EXIT
    qemu_start "$name"
    qemu_wait_ready --timeout 1800 "$name"
)

qemu_pid_valid() {
    local name=$1 dir pid binary disk cmdline
    dir=$(qemu_vm_dir "$name"); disk="$dir/disk.qcow2"
    valid_name "$name" || return 1
    [[ -r $dir/qemu.pid && ! -L $dir/qemu.pid ]] || return 1
    IFS= read -r pid <"$dir/qemu.pid"
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    binary=$(basename -- "$(qemu_binary_for_arch "$(qemu_config_get "$name" arch)")")
    cmdline=$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
    grep -Fxq -- "file=$disk,format=qcow2,if=virtio" <<<"$cmdline" || return 1
    [[ ${cmdline%%$'\n'*} == "$binary" || ${cmdline%%$'\n'*} == */"$binary" ]]
}

qemu_build_netdev() {
    local name=$1 ssh_port protocol host guest result
    ssh_port=$(qemu_config_get "$name" ssh_port)
    result="user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
    while IFS='|' read -r protocol host guest; do
        [[ -n $protocol ]] || continue
        result+=",hostfwd=${protocol}:127.0.0.1:${host}-:${guest}"
    done <"$(qemu_ports_file "$name")"
    printf '%s' "$result"
}

qemu_start_with_accel() {
    local name=$1 accel=$2 arch dir binary cpus memory firmware netdev
    local -a args=()
    arch=$(qemu_config_get "$name" arch); cpus=$(qemu_config_get "$name" cpus); memory=$(qemu_config_get "$name" memory)
    dir=$(qemu_vm_dir "$name"); binary=$(qemu_binary_for_arch "$arch"); netdev=$(qemu_build_netdev "$name")
    args=(-name "xtmoe-$name" -smp "$cpus" -m "$memory" -display none -daemonize
        -pidfile "$dir/qemu.pid" -D "$dir/qemu.log"
        -chardev "socket,id=serial0,path=$dir/serial.sock,server=on,wait=off" -serial chardev:serial0
        -monitor "unix:$dir/monitor.sock,server=on,wait=off"
        -drive "file=$dir/disk.qcow2,format=qcow2,if=virtio"
        -drive "file=$dir/seed.iso,format=raw,if=virtio,readonly=on"
        -netdev "$netdev" -device "virtio-net-pci,netdev=net0")
    if [[ $arch == arm64 ]]; then
        args=(-machine virt "${args[@]}")
        firmware=$(<"$dir/firmware-code.path")
        args+=(-drive "if=pflash,format=raw,readonly=on,file=$firmware"
            -drive "if=pflash,format=raw,file=$dir/firmware-vars.fd")
    else
        args=(-machine q35 "${args[@]}")
    fi
    if [[ $accel == kvm ]]; then args+=(-accel kvm -cpu host); else args+=(-accel "tcg,thread=multi" -cpu max); fi
    "$binary" "${args[@]}"
}

qemu_start() {
    require_arg_range 0 1 "$#" 'xtmoe qemu start [名称]'
    local name=${1:-ubuntu-qemu} dir arch binary ssh_port accel=tcg protocol host guest
    require_name "$name"; qemu_require; qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"
    [[ $(qemu_config_get "$name" arch) == "$(qemu_arch)" ]] || die 'VM 架构与宿主不一致。'
    dir=$(qemu_vm_dir "$name")
    [[ $dir != *','* && $dir != *$'\n'* ]] || die 'QEMU 数据目录不能包含逗号或换行。'
    ((${#dir} + 13 < 104)) || die 'QEMU Unix socket 路径过长；请使用更短的 VM 名称或数据目录。'
    qemu_pid_valid "$name" && { ok "QEMU VM 已在运行：$name"; return 0; }
    dir=$(qemu_vm_dir "$name"); rm -f -- "$dir/qemu.pid" "$dir/serial.sock" "$dir/monitor.sock"
    ssh_port=$(qemu_config_get "$name" ssh_port)
    qemu_port_in_use "$ssh_port" tcp && die "SSH 端口正在监听，无法启动：$ssh_port"
    while IFS='|' read -r protocol host guest; do
        [[ -n $protocol ]] || continue
        qemu_port_in_use "$host" "$protocol" && die "端口映射的宿主端口正在监听，无法启动：$protocol/$host"
    done <"$(qemu_ports_file "$name")"
    arch=$(qemu_config_get "$name" arch); binary=$(qemu_binary_for_arch "$arch")
    if [[ -r /dev/kvm && -w /dev/kvm ]] && "$binary" -accel help 2>&1 | grep -qw kvm; then accel=kvm; fi
    info "启动 QEMU VM：$name（加速器：$accel）"
    if ! qemu_start_with_accel "$name" "$accel"; then
        [[ $accel == kvm ]] || die "QEMU 启动失败；查看 $dir/qemu.log"
        qemu_pid_valid "$name" && die 'KVM 启动返回异常但进程仍存在；拒绝重复启动。'
        rm -f -- "$dir/qemu.pid" "$dir/serial.sock" "$dir/monitor.sock"
        warn 'KVM 启动失败，回退到 TCG。'
        qemu_start_with_accel "$name" tcg || die "QEMU TCG 启动失败；查看 $dir/qemu.log"
        accel=tcg
    fi
    qemu_config_set "$name" accelerator "$accel"
    qemu_config_set "$name" state running
    ok "QEMU VM 已启动；SSH 端口：127.0.0.1:$ssh_port"
}

qemu_ssh_base_args() {
    local name=$1 dir port
    dir=$(qemu_vm_dir "$name"); port=$(qemu_config_get "$name" ssh_port)
    QEMU_SSH_ARGS=(-i "$dir/ssh/id_ed25519" -p "$port" -o BatchMode=yes
        -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2
        -o "UserKnownHostsFile=$dir/ssh/known_hosts" xtmoe@127.0.0.1)
}

qemu_probe() {
    local name=$1 seconds=$2 remote remaining
    shift 2
    if [[ -n ${QEMU_PROBE_DEADLINE:-} ]]; then
        remaining=$((QEMU_PROBE_DEADLINE - $(date +%s)))
        ((remaining > 0)) || return 124
        ((seconds <= remaining)) || seconds=$remaining
    fi
    qemu_ssh_base_args "$name"
    remote=$(shell_quote_args "$@")
    timeout --kill-after=2 "$seconds" ssh "${QEMU_SSH_ARGS[@]}" "$remote"
}

qemu_verify_docker() {
    local name=$1 budget=${2:-180} result
    if ! qemu_probe "$name" 15 sudo docker info; then
        qemu_config_set "$name" docker_state failed
        return 1
    fi
    qemu_config_set "$name" docker_state daemon-ready
    if qemu_probe "$name" "$budget" sudo docker run --rm hello-world; then
        qemu_config_set "$name" docker_state ready
        return 0
    else
        result=$?
    fi
    qemu_config_set "$name" docker_state container-unverified
    warn 'Docker daemon 可用，但 hello-world 下载或运行未通过。'
    return "$result"
}

qemu_wait_ready() {
    local timeout_seconds=1800 name=ubuntu-qemu name_set=0 start_time now remaining probe_seconds state
    while (($#)); do
        case "$1" in
            --timeout) timeout_seconds=${2:?--timeout 缺少值}; shift ;;
            -*) die "未知 wait-ready 参数：$1" ;;
            *) ((name_set == 0)) || die 'wait-ready 只接受一个 VM 名称'; name=$1; name_set=1 ;;
        esac
        shift
    done
    qemu_validate_uint "$timeout_seconds" 10 7200 '等待秒数'
    qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"
    qemu_pid_valid "$name" || die "QEMU VM 未运行：$name"
    local QEMU_PROBE_DEADLINE
    start_time=$(date +%s)
    QEMU_PROBE_DEADLINE=$((start_time + timeout_seconds))
    while true; do
        now=$(date +%s)
        if ((now - start_time >= timeout_seconds)); then
            qemu_config_set "$name" init_state initializing
            die "等待 QEMU 初始化超时；VM 保持运行，可执行 qemu console 或再次 wait-ready。"
        fi
        qemu_pid_valid "$name" || { qemu_config_set "$name" state failed; die 'QEMU 进程已退出；请查看 qemu.log。'; }
        remaining=$((timeout_seconds - (now - start_time)))
        probe_seconds=10; ((remaining >= probe_seconds)) || probe_seconds=$remaining
        if qemu_probe "$name" "$probe_seconds" test -f /var/lib/xtmoe/bootstrap.done 2>/dev/null; then
            qemu_config_set "$name" state running
            qemu_config_set "$name" init_state ready
            state=$(qemu_probe "$name" 10 systemctl is-system-running 2>/dev/null || true)
            [[ $state == running || $state == degraded ]] || { warn "systemd 状态异常：$state"; return 1; }
            now=$(date +%s); remaining=$((timeout_seconds - (now - start_time)))
            ((remaining > 0)) || return 1
            ((remaining <= 180)) || remaining=180
            qemu_verify_docker "$name" "$remaining" || return 1
            ok 'QEMU Ubuntu、systemd、Docker daemon 和 hello-world 已通过验证。'
            return 0
        fi
        if qemu_probe "$name" "$probe_seconds" test -f /var/lib/xtmoe/bootstrap.failed 2>/dev/null; then
            qemu_config_set "$name" state running
            qemu_config_set "$name" init_state ready
            qemu_config_set "$name" docker_state failed
            warn 'Ubuntu VM 可登录，但 Docker cloud-init 初始化失败；查看 /var/log/xtmoe-firstboot.log。'
            return 1
        fi
        if qemu_probe "$name" "$probe_seconds" test -f /var/lib/cloud/instance/boot-finished 2>/dev/null; then
            qemu_config_set "$name" init_state failed
            qemu_config_set "$name" docker_state failed
            warn 'cloud-init 已结束但未完成 XTMOE 初始化；请查看 cloud-init-output.log。'
            return 1
        fi
        info "等待 QEMU/cloud-init：$((now - start_time))/$timeout_seconds 秒"
        now=$(date +%s); remaining=$((timeout_seconds - (now - start_time)))
        ((remaining > 0)) || continue
        ((remaining <= 10)) || remaining=10
        sleep "$remaining"
    done
}

qemu_ssh() {
    require_arg_range 0 1 "$#" 'xtmoe qemu ssh [名称]'
    local name=${1:-ubuntu-qemu}
    qemu_pid_valid "$name" || die "QEMU VM 未运行：$name"
    qemu_ssh_base_args "$name"
    ssh -t "${QEMU_SSH_ARGS[@]}"
}

qemu_exec() {
    local name=${1:?缺少 VM 名称} remote
    shift; [[ ${1:-} == -- ]] && shift; (($#)) || die '缺少远程命令'
    qemu_pid_valid "$name" || die "QEMU VM 未运行：$name"
    qemu_ssh_base_args "$name"; remote=$(shell_quote_args "$@")
    ssh "${QEMU_SSH_ARGS[@]}" "$remote"
}

qemu_console() {
    require_arg_range 0 1 "$#" 'xtmoe qemu console [名称]'
    local name=${1:-ubuntu-qemu} socket
    qemu_pid_valid "$name" || die "QEMU VM 未运行：$name"
    socket="$(qemu_vm_dir "$name")/serial.sock"; [[ -S $socket ]] || die 'QEMU serial socket 不存在。'
    info '按 Ctrl+] 断开控制台；Ctrl+C 会传给客体前台程序。'
    socat STDIO,raw,echo=0,escape=0x1d "UNIX-CONNECT:$socket"
}

qemu_status_value() {
    local name=$1 dir state
    qemu_vm_exists "$name" || { printf 'not-installed'; return 1; }
    dir=$(qemu_vm_dir "$name")
    if qemu_pid_valid "$name"; then
        state=$(qemu_config_get "$name" init_state 2>/dev/null || printf initializing)
        if [[ $state == ready ]]; then printf 'ready'; else printf 'initializing'; fi
    elif [[ -e $dir/qemu.pid ]]; then
        printf 'stale-pid'
    else
        printf 'stopped'
    fi
}

qemu_status() {
    require_arg_range 0 1 "$#" 'xtmoe qemu status [名称]'
    local name=${1:-ubuntu-qemu}
    local state result=0
    state=$(qemu_status_value "$name") || result=$?
    printf '%s\n' "$state"
    return "$result"
}

qemu_names() {
    local dir entry
    dir=$(qemu_base); [[ -d $dir ]] || return 0
    for entry in "$dir"/*; do
        [[ -f $entry/.xtmoe-qemu ]] && basename -- "$entry"
    done | sort
}

qemu_list() {
    (($# == 0)) || die 'xtmoe qemu list 不接受额外参数'
    local name found=0
    while IFS= read -r name; do
        [[ -n $name ]] || continue; found=1
        printf '%-24s %-14s docker=%s\n' "$name" "$(qemu_status_value "$name")" "$(qemu_config_get "$name" docker_state 2>/dev/null || printf unknown)"
    done < <(qemu_names)
    ((found)) || info '没有 QEMU VM'
}

qemu_stop() {
    local force=0 name=ubuntu-qemu argument name_set=0 dir pid attempt
    for argument in "$@"; do
        case "$argument" in
            --force) force=1 ;;
            -*) die "未知 stop 参数：$argument" ;;
            *) ((name_set == 0)) || die 'stop 只接受一个 VM 名称'; name=$argument; name_set=1 ;;
        esac
    done
    qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"; dir=$(qemu_vm_dir "$name")
    if ! qemu_pid_valid "$name"; then rm -f -- "$dir/qemu.pid" "$dir/serial.sock" "$dir/monitor.sock"; ok 'QEMU VM 未运行'; return 0; fi
    IFS= read -r pid <"$dir/qemu.pid"
    if ((force)); then
        kill -TERM "$pid" 2>/dev/null || true
    else
        qemu_ssh_base_args "$name"
        timeout 10 ssh "${QEMU_SSH_ARGS[@]}" sudo poweroff >/dev/null 2>&1 ||
            printf 'system_powerdown\n' | timeout --kill-after=2 5 socat - "UNIX-CONNECT:$dir/monitor.sock" >/dev/null 2>&1 || true
    fi
    for ((attempt = 0; attempt < 300; attempt++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
        ((force)) || die 'QEMU VM 未在 30 秒内关机；确认后使用 stop --force。'
        qemu_pid_valid "$name" || die 'QEMU PID 身份已变化，拒绝发送强制信号。'
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f -- "$dir/qemu.pid" "$dir/serial.sock" "$dir/monitor.sock"
    qemu_config_set "$name" state stopped
    ok "QEMU VM 已停止：$name"
}

qemu_ports() {
    require_arg_range 0 1 "$#" 'xtmoe qemu ports [名称]'
    local name=${1:-ubuntu-qemu}
    printf 'tcp|%s|22\n' "$(qemu_config_get "$name" ssh_port)"
    [[ ! -s $(qemu_ports_file "$name") ]] || cat "$(qemu_ports_file "$name")"
}

qemu_port_add() {
    require_arg_range 3 4 "$#" 'xtmoe qemu port-add <名称> <宿主端口> <客体端口> [tcp|udp]'
    local name=$1 host=$2 guest=$3 protocol=${4:-tcp} file
    qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"; [[ $(qemu_status_value "$name") == stopped ]] || die '修改端口前必须停止 VM。'
    qemu_validate_uint "$host" 1 65535 '宿主端口'; qemu_validate_uint "$guest" 1 65535 '客体端口'
    [[ $protocol == tcp || $protocol == udp ]] || die '协议只能是 tcp 或 udp。'
    [[ $host != $(qemu_config_get "$name" ssh_port) ]] || die '宿主端口与 SSH 端口冲突。'
    qemu_port_reserved "$host" "$name" && die "宿主端口已被 XTMOE 使用：$host"; qemu_port_in_use "$host" "$protocol" && die "宿主端口正在监听：$protocol/$host"
    file=$(qemu_ports_file "$name"); awk -F'|' -v p="$protocol" -v h="$host" '$1 == p && $2 == h { found=1 } END { exit !found }' "$file" && die '端口映射已存在。'
    printf '%s|%s|%s\n' "$protocol" "$host" "$guest" >>"$file"; ok '端口映射已添加。'
}

qemu_port_remove() {
    require_arg_range 2 3 "$#" 'xtmoe qemu port-remove <名称> <宿主端口> [tcp|udp]'
    local name=$1 host=$2 protocol=${3:-tcp} file tmp
    qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"; [[ $(qemu_status_value "$name") == stopped ]] || die '修改端口前必须停止 VM。'
    qemu_validate_uint "$host" 1 65535 '宿主端口'
    [[ $protocol == tcp || $protocol == udp ]] || die '协议只能是 tcp 或 udp。'
    file=$(qemu_ports_file "$name"); tmp="$file.tmp.$$"
    awk -F'|' -v p="$protocol" -v h="$host" '!($1 == p && $2 == h)' "$file" >"$tmp"; mv -f -- "$tmp" "$file"; ok '端口映射已移除。'
}

qemu_update_system() { local name=${1:-ubuntu-qemu}; require_arg_range 0 1 "$#" 'xtmoe qemu update-system [名称]'; qemu_exec "$name" -- sudo bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y'; }
qemu_docker_status() {
    require_arg_range 0 1 "$#" 'xtmoe qemu docker-status [名称]'
    local name=${1:-ubuntu-qemu}
    qemu_pid_valid "$name" || die "QEMU VM 未运行：$name"
    if qemu_probe "$name" 15 sudo docker info; then
        [[ $(qemu_config_get "$name" docker_state) == ready ]] || qemu_config_set "$name" docker_state daemon-ready
    else
        qemu_config_set "$name" docker_state failed
        return 1
    fi
}
qemu_docker_test() {
    require_arg_range 0 1 "$#" 'xtmoe qemu docker-test [名称]'
    local name=${1:-ubuntu-qemu}
    qemu_pid_valid "$name" || die "QEMU VM 未运行：$name"
    qemu_verify_docker "$name"
}

qemu_backup() (
    set -Eeuo pipefail
    require_arg_range 1 2 "$#" 'xtmoe qemu backup <名称> [文件]'
    local name=$1 output=${2:-"$PWD/${1}-$(date +%Y%m%d-%H%M%S)-qemu.tar.gz"} dir partial canonical_output canonical_dir
    qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"; [[ $(qemu_status_value "$name") == stopped ]] || die '备份前必须停止 VM。'
    [[ ! -e $output && ! -L $output ]] || die "备份文件已存在：$output"; dir=$(qemu_vm_dir "$name")
    canonical_output=$(realpath -m -- "$output"); canonical_dir=$(realpath -m -- "$dir")
    [[ $canonical_output != "$canonical_dir" && $canonical_output != "$canonical_dir"/* ]] || die '备份文件不能写入被备份的 VM 目录。'
    mkdir -p -- "$(dirname -- "$output")"; partial="$output.partial.$$"
    [[ ! -e $partial && ! -L $partial ]] || die "临时备份路径已存在：$partial"
    local -a members=("$name/.xtmoe-qemu" "$name/disk.qcow2" "$name/seed.iso" "$name/ssh/id_ed25519" "$name/ssh/id_ed25519.pub")
    local entry cleanup_command
    for entry in ssh/known_hosts firmware-code.path firmware-vars.fd; do
        if [[ -f $dir/$entry && ! -L $dir/$entry ]]; then members+=("$name/$entry"); fi
    done
    printf -v cleanup_command 'rm -f -- %q' "$partial"
    # shellcheck disable=SC2064
    trap "$cleanup_command" EXIT
    warn 'QEMU 备份包含 VM 磁盘和 SSH 私钥，请安全保存。'
    (umask 077; tar --sparse -czpf "$partial" -C "$(qemu_base)" "${members[@]}" -C "$(qemu_config_base)" "$name.conf" "$name.ports")
    mv -- "$partial" "$output"; ok "QEMU 备份已写入：$output"
)

qemu_archive_name() {
    local archive=$1 listing details member name='' normalized
    local -A seen=()
    listing=$(tar --quoting-style=escape -tzf "$archive") || die '无法读取 QEMU 备份目录。'
    details=$(LC_ALL=C tar --numeric-owner -tvzf "$archive") || die '无法读取 QEMU 备份类型。'
    # QEMU backups contain files/directories only. Reject links and devices
    # before extraction, including link-based traversal into host directories.
    awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { bad=1 } END { exit bad }' <<<"$details" || die 'QEMU 备份不允许符号链接、硬链接或特殊文件。'
    while IFS= read -r member; do
        if [[ $member == */.xtmoe-qemu ]]; then
            [[ -z $name ]] || die '备份包含多个 VM 标记。'
            name=${member%/.xtmoe-qemu}; require_name "$name"
        fi
    done <<<"$listing"
    [[ -n $name ]] || die 'QEMU 备份缺少 VM 标记。'
    while IFS= read -r member; do
        normalized=${member%/}
        [[ ! ${seen[$normalized]+set} ]] || die 'QEMU 备份包含重复路径。'
        seen[$normalized]=1
        case "$member" in
            "$name/"|"$name/ssh/"|"$name/.xtmoe-qemu"|"$name/disk.qcow2"|"$name/seed.iso"|"$name/ssh/id_ed25519"|"$name/ssh/id_ed25519.pub"|"$name/ssh/known_hosts"|"$name/firmware-code.path"|"$name/firmware-vars.fd"|"$name.conf"|"$name.ports"|"$name/qemu.log") ;;
            *) die "QEMU 备份包含非预期路径：$member" ;;
        esac
    done <<<"$listing"
    printf '%s' "$name"
}

qemu_restore() (
    set -Eeuo pipefail
    require_arg_range 1 2 "$#" 'xtmoe qemu restore <文件> [名称]'
    local archive=$1 requested=${2:-} temp source_name target config_src ports_src cleanup_command restored_arch restored_port protocol host guest firmware
    [[ -f $archive && ! -L $archive ]] || die "备份文件不存在：$archive"
    temp=$(mktemp -d); printf -v cleanup_command 'rm -rf -- %q' "$temp"
    # shellcheck disable=SC2064 # The mktemp path is intentionally frozen now.
    trap "$cleanup_command" EXIT
    source_name=$(qemu_archive_name "$archive") || die 'QEMU 备份预检失败。'
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$temp"
    [[ -n $source_name && -f $temp/$source_name/.xtmoe-qemu ]] || die '不是有效的 XTMOE QEMU 备份。'
    grep -qx 'xtmoe-qemu-format-1' "$temp/$source_name/.xtmoe-qemu" || die 'QEMU 备份标记版本错误。'
    target=${requested:-$source_name}; require_name "$target"
    [[ ! -e $(qemu_vm_dir "$target") && ! -L $(qemu_vm_dir "$target") && ! -e $(qemu_config_file "$target") && ! -L $(qemu_config_file "$target") && ! -e $(qemu_ports_file "$target") && ! -L $(qemu_ports_file "$target") ]] || die "目标 VM 或配置已存在：$target"
    config_src="$temp/$source_name.conf"; ports_src="$temp/$source_name.ports"; [[ -r $config_src && -r $ports_src ]] || die 'QEMU 备份缺少配置。'
    [[ ! -L $temp/$source_name && ! -L $temp/$source_name/.xtmoe-qemu && ! -L $temp/$source_name/disk.qcow2 && ! -L $temp/$source_name/seed.iso ]] || die 'QEMU 备份包含非法符号链接。'
    [[ -f $temp/$source_name/disk.qcow2 && -f $temp/$source_name/seed.iso ]] || die 'QEMU 备份缺少磁盘或 seed ISO。'
    [[ -f $temp/$source_name/ssh/id_ed25519 && ! -L $temp/$source_name/ssh/id_ed25519 && -f $temp/$source_name/ssh/id_ed25519.pub && ! -L $temp/$source_name/ssh/id_ed25519.pub ]] || die 'QEMU 备份缺少安全的 SSH 身份文件。'
    [[ ! -L $config_src && ! -L $ports_src ]] || die 'QEMU 备份配置不能是符号链接。'
    qemu_validate_config_file "$config_src" || die 'QEMU 备份配置格式或资源无效。'
    restored_arch=$(awk -F= '$1 == "arch" { print $2; exit }' "$config_src")
    [[ $restored_arch == "$(qemu_arch)" ]] || die "备份架构与当前设备不一致：$restored_arch"
    restored_port=$(awk -F= '$1 == "ssh_port" { print $2; exit }' "$config_src")
    qemu_validate_ports_file "$ports_src" "$restored_port" || die 'QEMU 备份端口无效或重复。'
    qemu_validate_uint "$restored_port" 1 65535 '备份 SSH 端口'
    qemu_port_reserved "$restored_port" && die "备份 SSH 端口已被其他 VM 使用：$restored_port"
    qemu_port_in_use "$restored_port" tcp && die "备份 SSH 端口正在监听：$restored_port"
    while IFS='|' read -r protocol host guest; do
        [[ -n $protocol ]] || continue
        [[ $protocol == tcp || $protocol == udp ]] || die '备份包含非法端口协议。'
        qemu_validate_uint "$host" 1 65535 '备份宿主端口'; qemu_validate_uint "$guest" 1 65535 '备份客体端口'
        [[ $host != "$restored_port" ]] || die '备份端口与 SSH 端口冲突。'
        qemu_port_reserved "$host" && die "备份宿主端口已被其他 VM 使用：$host"
        qemu_port_in_use "$host" "$protocol" && die "备份宿主端口正在监听：$protocol/$host"
    done <"$ports_src"
    if [[ $restored_arch == arm64 ]]; then
        firmware=$(qemu_find_firmware) || die '当前设备缺少 ARM64 UEFI 固件。'
        [[ -f $temp/$source_name/firmware-vars.fd ]] || die 'ARM64 备份缺少 UEFI vars。'
        printf '%s\n' "$firmware" >"$temp/$source_name/firmware-code.path"
    fi
    mkdir -p "$(qemu_base)" "$(qemu_config_base)"
    chmod 0700 "$temp/$source_name/ssh"
    chmod 0600 "$temp/$source_name/ssh/id_ed25519"
    mv -- "$temp/$source_name" "$(qemu_vm_dir "$target")"
    mv -- "$config_src" "$(qemu_config_file "$target")"; mv -- "$ports_src" "$(qemu_ports_file "$target")"
    rm -f -- "$(qemu_vm_dir "$target")/qemu.pid" "$(qemu_vm_dir "$target")/serial.sock" "$(qemu_vm_dir "$target")/monitor.sock"
    qemu_config_set "$target" state stopped; trap - EXIT; rm -rf -- "$temp"; ok "QEMU VM 已恢复：$target"
)

qemu_remove() {
    local yes=0 name='' dir base parent
    while (($#)); do case "$1" in --yes|-y) yes=1 ;; *) [[ -z $name ]] || die 'remove 只接受一个名称'; name=$1 ;; esac; shift; done
    [[ -n $name ]] || die '缺少 VM 名称'; require_name "$name"; qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"
    dir=$(realpath -m -- "$(qemu_vm_dir "$name")"); base=$(realpath -m -- "$(qemu_base)"); parent=$(dirname -- "$dir")
    [[ $parent == "$base" && $dir != / ]] || die 'QEMU VM 路径越界，拒绝删除。'
    [[ $(qemu_status_value "$name") == stopped ]] || die '删除前必须停止 VM。'; ((yes)) && export XTMOE_YES=1
    confirm "永久删除 QEMU VM '$name'、磁盘和专用 SSH 密钥？" || { info '已取消'; return 0; }
    rm -rf --one-file-system -- "$dir"; rm -f -- "$(qemu_config_file "$name")" "$(qemu_ports_file "$name")"; ok "已删除 QEMU VM：$name"
}

qemu_reinstall() (
    set -Eeuo pipefail
    local yes=0 name=ubuntu-qemu argument cpus memory disk_size port preserve result name_set=0
    for argument in "$@"; do case "$argument" in --yes|-y) yes=1 ;; -*) die "未知 reinstall 参数：$argument" ;; *) ((name_set == 0)) || die 'reinstall 只接受一个名称'; name=$argument; name_set=1 ;; esac; done
    qemu_vm_exists "$name" || die "QEMU VM 不存在：$name"; [[ $(qemu_status_value "$name") == stopped ]] || die '重装前必须停止 VM。'
    cpus=$(qemu_config_get "$name" cpus); memory=$(qemu_config_get "$name" memory); disk_size=$(qemu_config_get "$name" disk_size); port=$(qemu_config_get "$name" ssh_port)
    ((yes)) && export XTMOE_YES=1; confirm "重装 QEMU VM '$name'？磁盘内全部数据都会删除且不会自动备份" || { info '已取消'; return 0; }
    qemu_require
    qemu_download_image "$(qemu_config_get "$name" arch)" >/dev/null
    preserve="$(qemu_base)/.${name}.reinstall.$$"
    [[ ! -e $preserve ]] || die "重装暂存目录已存在：$preserve"
    mv -- "$(qemu_vm_dir "$name")" "$preserve"
    mv -- "$(qemu_config_file "$name")" "$preserve/previous.conf"
    mv -- "$(qemu_ports_file "$name")" "$preserve/previous.ports"
    set +e
    ( set -Eeuo pipefail
      XTMOE_QEMU_INTERNAL_NONINTERACTIVE=1 XTMOE_QEMU_REUSE_KEY_DIR="$preserve/ssh" XTMOE_QEMU_REUSE_PORTS_FILE="$preserve/previous.ports" \
        qemu_install --yes --cpus "$cpus" --memory "$memory" --disk-size "$disk_size" --ssh-port "$port" "$name"
    )
    result=$?
    set -e
    if ((result != 0)); then
        warn "重装未完成；旧系统盘和配置完整保留在 $preserve。请先检查新 VM 与日志再决定恢复。"
        return "$result"
    fi
    rm -rf --one-file-system -- "$preserve"
)

qemu_main() {
    local action=${1:-help}; shift || true
    [[ $action == help || $action == -h || $action == --help ]] && { qemu_help; return; }
    require_termux
    case "$action" in
        prepare) qemu_prepare "$@" ;; install|add) qemu_install "$@" ;; start) qemu_start "$@" ;;
        wait-ready) qemu_wait_ready "$@" ;; console) qemu_console "$@" ;; ssh|login|shell) qemu_ssh "$@" ;;
        exec) qemu_exec "$@" ;; status) qemu_status "$@" ;; list|ls) qemu_list "$@" ;; stop) qemu_stop "$@" ;;
        update-system) qemu_update_system "$@" ;; docker-status) qemu_docker_status "$@" ;; docker-test) qemu_docker_test "$@" ;;
        ports) qemu_ports "$@" ;; port-add) qemu_port_add "$@" ;; port-remove) qemu_port_remove "$@" ;;
        backup) qemu_backup "$@" ;; restore) qemu_restore "$@" ;; reinstall) qemu_reinstall "$@" ;; remove|rm) qemu_remove "$@" ;;
        *) die "未知 QEMU 操作：$action" ;;
    esac
}
