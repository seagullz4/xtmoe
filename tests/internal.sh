#!/usr/bin/env bash
# Test driver for library operations; never installed as a product command.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/src/bin/xtmoe"
operation=${1:?Missing test operation}; shift
case "$operation" in
    proot) proxy_load; proot_main "$@" ;;
    chroot) proxy_load; chroot_main "$@" ;;
    proxy) proxy_main "$@" ;;
    *) exit 2 ;;
esac
