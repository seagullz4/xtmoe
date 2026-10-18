#!/usr/bin/env bash
# Sourced by run.sh: offline restore and complete-generation update checks.

for listing_case in broken partial unsafe extract-failure valid; do
    assert_ok "Restore listing/extraction gate: $listing_case" bash -c '
        set -Eeuo pipefail
        source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
        BASE="$2/restore-$3"; CONTAINER="$BASE/target"; mkdir -p "$BASE"
        archive="$BASE/input.tar.gz"; touch "$archive"
        tar() {
            if [[ $1 == -tzf ]]; then
                case "$RESTORE_TEST_CASE" in
                    broken) return 2 ;;
                    partial) printf "./rootfs/\n"; return 2 ;;
                    unsafe) printf "./rootfs/\n../escape\n" ;;
                    *) printf "./rootfs/\n" ;;
                esac
            else
                printf extract >>"$BASE/extracted"
                [[ $RESTORE_TEST_CASE != extract-failure ]] || return 2
                mkdir -p "${@: -1}/rootfs"
            fi
        }
        valid_container_tree() { [[ -d $1/rootfs ]]; }
        export RESTORE_TEST_CASE=$3
        if (restore_container "$archive"); then result=0; else result=$?; fi
        if [[ $3 == valid ]]; then
            [[ $result == 0 && -d $CONTAINER/rootfs ]] || exit 1
        else
            [[ $result != 0 && ! -e $CONTAINER ]] || exit 1
            if [[ $3 != extract-failure ]]; then [[ ! -e $BASE/extracted ]] || exit 1; fi
        fi
        [[ -z $(find "$BASE" -maxdepth 1 -name ".target.restore.*" -print) ]]
    ' _ "$ROOT_DIR" "$TEST_TMP" "$listing_case"
done

assert_ok 'Restore refuses a real truncated archive before creating extracted files' bash -c '
    set -Eeuo pipefail
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    BASE="$2/truncated-restore"; CONTAINER="$BASE/target"; mkdir -p "$BASE"
    printf "not-a-gzip-archive" >"$BASE/broken.tar.gz"
    if (restore_container "$BASE/broken.tar.gz"); then exit 1; fi
    [[ ! -e $CONTAINER && -z $(find "$BASE" -maxdepth 1 -name ".target.restore.*" -print) ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Restore accepts a real valid archive and removes its temporary listing' bash -c '
    set -Eeuo pipefail
    source <(awk "/^\\[\\[ .*id -u/ {skip=1} /^valid_name\\(\\)/ {skip=0} /^ACTION=/ {exit} !skip {print}" "$1/src/lib/xtmoe-root")
    BASE="$2/real-restore"; CONTAINER="$BASE/target"; fixture="$BASE/fixture"
    mkdir -p "$fixture/rootfs/bin"
    printf "xtmoe-chroot-format-1\n" >"$fixture/.xtmoe-chroot"
    printf "#!/bin/sh\nexit 0\n" >"$fixture/rootfs/bin/sh"; chmod +x "$fixture/rootfs/bin/sh"
    tar -czf "$BASE/valid.tar.gz" -C "$fixture" .
    restore_container "$BASE/valid.tar.gz"
    valid_container_tree "$CONTAINER"
    [[ ! -e $CONTAINER/list && -z $(find "$BASE" -maxdepth 1 -name ".target.restore.*" -print) ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Generation upgrade pins old CLI and helpers while new commands use the new bundle' bash -c '
    set -Eeuo pipefail
    old=$(realpath -e "$PREFIX/libexec/xtmoe/current")
    old_hash=$(sha256sum "$old/lib/common.sh")
    fixture="$2/generation-source"; mkdir -p "$fixture"
    cp -R "$1/src" "$fixture/src"; cp "$1/termux.sh" "$fixture/termux.sh"
    printf "\nXTMOE_GENERATION_MARKER=next\n" >>"$fixture/src/lib/common.sh"
    XTMOE_SKIP_PACKAGES=1 XTMOE_ALLOW_NON_TERMUX=1 sh "$fixture/termux.sh"
    next=$(realpath -e "$PREFIX/libexec/xtmoe/current")
    [[ $next != "$old" && $(sha256sum "$old/lib/common.sh") == "$old_hash" ]] || exit 1
    [[ -r $old/xtmoe-root && -r $old/lib/xtmoe-network ]] || exit 1
    [[ $(bash -c '\''source "$1/bin/xtmoe"; chroot_helper'\'' _ "$old") == "$old/lib/../xtmoe-root" ]] || exit 1
    [[ $(bash -c '\''source "$1/bin/xtmoe"; source_root'\'' _ "$old") == "$1" ]] || exit 1
    [[ $(bash -c '\''source "$1/bin/xtmoe"; printf "%s" "${XTMOE_GENERATION_MARKER:-old}"'\'' _ "$old") == old ]] || exit 1
    [[ $(bash -c '\''source "$1/bin/xtmoe"; printf "%s" "$XTMOE_GENERATION_MARKER"'\'' _ "$next") == next ]] || exit 1
    bash "$PREFIX/bin/xtmoe" version
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Invalid staged module leaves current installation unchanged and cleans staging' bash -c '
    set -Eeuo pipefail
    old=$(realpath -e "$PREFIX/libexec/xtmoe/current")
    launcher_hash=$(sha256sum "$PREFIX/bin/xtmoe")
    fixture="$2/invalid-source"; mkdir -p "$fixture"
    cp -R "$1/src" "$fixture/src"; cp "$1/termux.sh" "$fixture/termux.sh"
    printf "\nif then\n" >>"$fixture/src/lib/chroot.sh"
    if XTMOE_SKIP_PACKAGES=1 XTMOE_ALLOW_NON_TERMUX=1 sh "$fixture/termux.sh"; then exit 1; fi
    [[ $(realpath -e "$PREFIX/libexec/xtmoe/current") == "$old" && $(sha256sum "$PREFIX/bin/xtmoe") == "$launcher_hash" ]] || exit 1
    [[ -z $(find "$PREFIX/libexec/xtmoe/releases" -maxdepth 1 -name ".stage.*" -print) ]] || exit 1
    bash "$PREFIX/bin/xtmoe" version
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Installer rejects lock contention before staging or switching bundles' bash -c '
    set -Eeuo pipefail
    old=$(realpath -e "$PREFIX/libexec/xtmoe/current")
    fixture="$2/install-lock"; mkdir -p "$fixture"
    printf "#!/usr/bin/env bash\nexit 1\n" >"$fixture/flock"; chmod +x "$fixture/flock"
    if PATH="$fixture:$PATH" XTMOE_SKIP_PACKAGES=1 XTMOE_ALLOW_NON_TERMUX=1 sh "$1/termux.sh"; then exit 1; fi
    [[ $(realpath -e "$PREFIX/libexec/xtmoe/current") == "$old" ]]
' _ "$ROOT_DIR" "$TEST_TMP"

assert_ok 'Legacy installed modules stay untouched during generation migration' bash -c '
    set -Eeuo pipefail
    fixture="$2/legacy-install"; export PREFIX="$fixture/prefix"
    mkdir -p "$PREFIX/libexec/xtmoe/lib" "$PREFIX/bin"
    printf "legacy-helper\n" >"$PREFIX/libexec/xtmoe/xtmoe-root"
    printf "legacy-library\n" >"$PREFIX/libexec/xtmoe/lib/common.sh"
    XTMOE_SKIP_PACKAGES=1 XTMOE_ALLOW_NON_TERMUX=1 sh "$1/termux.sh"
    [[ $(<"$PREFIX/libexec/xtmoe/xtmoe-root") == legacy-helper && $(<"$PREFIX/libexec/xtmoe/lib/common.sh") == legacy-library ]] || exit 1
    bash "$PREFIX/bin/xtmoe" version
' _ "$ROOT_DIR" "$TEST_TMP"

for failure_phase in copy switch signal; do
    assert_ok "Installer failure before commit preserves current bundle: $failure_phase" bash -c '
        set -Eeuo pipefail
        old=$(realpath -e "$PREFIX/libexec/xtmoe/current")
        launcher_hash=$(sha256sum "$PREFIX/bin/xtmoe")
        fixture="$2/install-fault-$3"; mkdir -p "$fixture"
        export REAL_CP=$(command -v cp) REAL_MV=$(command -v mv) INSTALL_FAULT=$3
        cat >"$fixture/wrapper" <<"MOCK"
#!/usr/bin/env bash
case "${0##*/}" in
    cp)
        if [[ $* == *lib/chroot.sh* ]]; then
            if [[ $INSTALL_FAULT == signal ]]; then kill -TERM "$PPID"; exit 143; fi
            if [[ $INSTALL_FAULT == copy ]]; then exit 71; fi
        fi
        exec "$REAL_CP" "$@"
        ;;
    mv)
        if [[ $INSTALL_FAULT == switch && ${@: -1} == */xtmoe/current ]]; then exit 72; fi
        exec "$REAL_MV" "$@"
        ;;
esac
MOCK
        chmod +x "$fixture/wrapper"
        ln -s wrapper "$fixture/cp"; ln -s wrapper "$fixture/mv"
        if PATH="$fixture:$PATH" XTMOE_SKIP_PACKAGES=1 XTMOE_ALLOW_NON_TERMUX=1 sh "$1/termux.sh"; then exit 1; fi
        [[ $(realpath -e "$PREFIX/libexec/xtmoe/current") == "$old" && $(sha256sum "$PREFIX/bin/xtmoe") == "$launcher_hash" ]] || exit 1
        [[ -z $(find "$PREFIX/libexec/xtmoe/releases" -maxdepth 1 -name ".stage.*" -print) ]] || exit 1
        [[ -z $(find "$PREFIX/bin" -maxdepth 1 -name ".xtmoe-launcher.*" -print) ]] || exit 1
        bash "$PREFIX/bin/xtmoe" version
    ' _ "$ROOT_DIR" "$TEST_TMP" "$failure_phase"
done

assert_ok 'Updater lock rejection happens before any Git operation' bash -c '
    set -Eeuo pipefail
    source "$1/src/bin/xtmoe"
    require_termux() { :; }; require_command() { :; }; flock() { return 1; }
    git() { printf forbidden >"$2"; }
    if (update_main); then exit 1; fi
    [[ ! -e $2 ]]
' _ "$ROOT_DIR" "$TEST_TMP/update-must-not-call-git"

assert_ok 'Public update dispatch preserves --force' bash -c '
    set -Eeuo pipefail
    source "$1/src/bin/xtmoe"
    update_main() { [[ $# == 1 && $1 == --force ]]; }
    main update --force
' _ "$ROOT_DIR"

# Real Git repositories exercise fetching, divergence and destructive scope offline.
updater_fixture() {
    local fixture="$TEST_TMP/updater-$1"
    mkdir -p "$fixture/seed"
    git init -q --bare --initial-branch=main "$fixture/remote.git"
    git init -q --initial-branch=main "$fixture/seed"
    git -C "$fixture/seed" config user.name Fixture
    git -C "$fixture/seed" config user.email fixture@example.invalid
    git -C "$fixture/seed" config core.autocrlf false
    cp -R "$ROOT_DIR/src" "$fixture/seed/src"
    printf '#!/bin/sh\nprintf installed >>"$UPDATE_TEST_INSTALL_LOG"\n' >"$fixture/seed/termux.sh"
    printf 'ignored-local\n' >"$fixture/seed/.gitignore"
    git -C "$fixture/seed" add .
    git -C "$fixture/seed" commit -qm initial
    git -C "$fixture/seed" remote add origin "$fixture/remote.git"
    git -C "$fixture/seed" push -qu origin main
    git -c core.autocrlf=false clone -q "$fixture/remote.git" "$fixture/client"
    git -C "$fixture/client" config user.name Fixture
    git -C "$fixture/client" config user.email fixture@example.invalid
    printf remote-next >"$fixture/seed/remote-marker"
    git -C "$fixture/seed" add .
    git -C "$fixture/seed" commit -qm remote-next
    git -C "$fixture/seed" push -q
}

for update_case in clean dirty force fetch-failure invalid-remote no-upstream detached; do
    updater_fixture "$update_case"
    assert_ok "Real updater fetch, installation and scope: $update_case" bash -c '
        set -Eeuo pipefail
        source "$1/src/bin/xtmoe"
        fixture="$2/updater-$3"; client="$fixture/client"; seed="$fixture/seed"
        export UPDATE_TEST_INSTALL_LOG="$fixture/installed"
        require_termux() { :; }
        XTMOE_LIB_DIR="$fixture/bundle/lib"; mkdir -p "$XTMOE_LIB_DIR"
        printf "%s\n" "$client" >"$fixture/bundle/source-root"
        before=$(git -C "$client" rev-parse HEAD)
        case "$3" in
            clean)
                main update
                [[ $(git -C "$client" rev-parse HEAD) == $(git -C "$seed" rev-parse HEAD) && -e $fixture/installed ]]
                ;;
            dirty)
                printf local >"$client/untracked"
                if (main update) >"$fixture/update.log" 2>&1; then exit 1; fi
                grep -F "未提交修改" "$fixture/update.log" || exit 1
                [[ -e $client/untracked && $(git -C "$client" rev-parse HEAD) == "$before" && ! -e $fixture/installed ]] || exit 1
                rm "$client/untracked"
                printf local >>"$client/src/bin/xtmoe"
                if (main update) >"$fixture/update.log" 2>&1; then exit 1; fi
                grep -F "未提交修改" "$fixture/update.log" || exit 1
                [[ $(git -C "$client" rev-parse HEAD) == "$before" && ! -e $fixture/installed ]]
                ;;
            force)
                printf local-commit >"$client/local-commit"
                git -C "$client" add .; git -C "$client" commit -qm local-divergence
                git -C "$client" rm -q src/bin/xtmoe
                rm "$client/termux.sh"
                printf local >"$client/untracked"; printf ignored >"$client/ignored-local"
                printf container-data >"$fixture/container-data"
                main update --force
                [[ $(git -C "$client" rev-parse HEAD) == $(git -C "$seed" rev-parse HEAD) ]] || exit 1
                [[ -z $(git -C "$client" status --porcelain) && ! -e $client/untracked && ! -e $client/local-commit ]] || exit 1
                [[ $(<"$client/ignored-local") == ignored && $(<"$fixture/container-data") == container-data && -e $fixture/installed ]]
                ;;
            fetch-failure|invalid-remote|no-upstream|detached)
                printf local >>"$client/src/bin/xtmoe"
                printf keep >"$client/untracked"
                case "$3" in
                    fetch-failure) git -C "$client" remote set-url origin "$fixture/missing.git" ;;
                    invalid-remote)
                        git -C "$seed" rm -q src/lib/xtmoe-network
                        git -C "$seed" commit -qm invalid; git -C "$seed" push -q
                        ;;
                    no-upstream) git -C "$client" branch --unset-upstream ;;
                    detached) git -C "$client" checkout -q --detach ;;
                esac
                hash=$(sha256sum "$client/src/bin/xtmoe")
                if (main update --force) >"$fixture/update.log" 2>&1; then exit 1; fi
                case "$3" in
                    fetch-failure) grep -F "远端下载失败" "$fixture/update.log" ;;
                    invalid-remote) grep -F "远端缺少 XTMOE 文件" "$fixture/update.log" ;;
                    no-upstream) grep -F "当前分支没有配置远端" "$fixture/update.log" ;;
                    detached) grep -F "detached HEAD" "$fixture/update.log" ;;
                esac || exit 1
                [[ $(git -C "$client" rev-parse HEAD) == "$before" && $(sha256sum "$client/src/bin/xtmoe") == "$hash" && -e $client/untracked && ! -e $fixture/installed ]]
                ;;
        esac
    ' _ "$ROOT_DIR" "$TEST_TMP" "$update_case"
done
unset -f updater_fixture

assert_ok 'Unsupported update options fail before touching Git or installation' bash -c '
    set -Eeuo pipefail
    source "$1/src/bin/xtmoe"
    log="$2/invalid-update-option"
    git() { touch "$log"; }
    if (main update --force extra); then exit 1; fi
    if (main update --unknown); then exit 1; fi
    [[ ! -e $log ]]
' _ "$ROOT_DIR" "$TEST_TMP"
