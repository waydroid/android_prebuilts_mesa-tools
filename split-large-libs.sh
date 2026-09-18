#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LIB_DIR="${LIB_DIR:-$REPO_ROOT/root/lib64}"
BIN_DIR="${BIN_DIR:-$REPO_ROOT/root/bin}"
MAX_SIZE_MIB="${1:-50}"
CHUNK_SIZE_MIB="${2:-45}"

if [[ ! "$MAX_SIZE_MIB" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$CHUNK_SIZE_MIB" =~ ^[1-9][0-9]*$ ]] ||
   (( CHUNK_SIZE_MIB >= MAX_SIZE_MIB )); then
    echo "Usage: $0 [maximum-file-size-MiB [chunk-size-MiB]]" >&2
    echo "The chunk size must be smaller than the maximum file size." >&2
    exit 2
fi

MAX_SIZE=$((MAX_SIZE_MIB * 1024 * 1024))
CHUNK_SIZE=$((CHUNK_SIZE_MIB * 1024 * 1024))
ATTRIBUTES="$REPO_ROOT/.gitattributes"
IGNORE="$REPO_ROOT/.gitignore"

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

remove_lfs_rule() {
    local path=$1
    local relative=${path#"$REPO_ROOT"/}
    local temporary

    [ -f "$ATTRIBUTES" ] || return 0
    temporary=$(mktemp "$REPO_ROOT/.gitattributes.tmp.XXXXXX")
    awk -v file="$relative" '$1 != file { print }' "$ATTRIBUTES" > "$temporary"
    mv -f "$temporary" "$ATTRIBUTES"
}

add_ignore_rule() {
    local path=$1
    local relative=/${path#"$REPO_ROOT"/}

    touch "$IGNORE"
    grep -Fqx -- "$relative" "$IGNORE" || printf '%s\n' "$relative" >> "$IGNORE"
}

install_chunks() {
    local source=$1
    local target=$2
    local expected=$3
    local work_dir reconstructed part
    local -a old_parts new_parts

    work_dir=$(mktemp -d "$LIB_DIR/.split.XXXXXX")
    trap 'rm -rf "$work_dir"' RETURN

    split -b "$CHUNK_SIZE" "$source" "$work_dir/part."
    new_parts=("$work_dir"/part.*)
    cat "${new_parts[@]}" > "$work_dir/reconstructed"

    if [ "$(sha256_file "$work_dir/reconstructed")" != "$expected" ]; then
        echo "error: chunk verification failed for $target" >&2
        exit 1
    fi

    shopt -s nullglob
    old_parts=("$target".part.*)
    shopt -u nullglob
    if ((${#old_parts[@]})); then
        rm -f -- "${old_parts[@]}"
    fi

    for part in "${new_parts[@]}"; do
        mv -f -- "$part" "$target.part.${part##*.}"
    done
    printf '%s  %s\n' "$expected" "${target##*/}" > "$target.sha256"
    remove_lfs_rule "$target"
    add_ignore_rule "$target"
    rm -rf "$work_dir"
    trap - RETURN
}

mkdir -p "$LIB_DIR"
shopt -s nullglob

# Normalize chunk sets made by older versions of this script.
for checksum in "$LIB_DIR"/*.sha256; do
    library=${checksum%.sha256}
    add_ignore_rule "$library"
    [ -e "$library" ] && continue

    parts=("$library".part.*)
    ((${#parts[@]})) || continue

    needs_split=false
    for part in "${parts[@]}"; do
        if (( $(wc -c < "$part") > CHUNK_SIZE )); then
            needs_split=true
            break
        fi
    done
    "$needs_split" || continue

    read -r expected _ < "$checksum"
    work_dir=$(mktemp -d "$LIB_DIR/.reassemble.XXXXXX")
    cat "${parts[@]}" > "$work_dir/library"
    if [ "$(sha256_file "$work_dir/library")" != "$expected" ]; then
        rm -rf "$work_dir"
        echo "error: existing chunks failed verification for $library" >&2
        exit 1
    fi
    install_chunks "$work_dir/library" "$library" "$expected"
    rm -rf "$work_dir"
done

# Split every unsplit file that exceeds the requested limit.
for library in "$LIB_DIR"/*; do
    [ -f "$library" ] || continue
    case $library in
        *.part.*|*.sha256) continue ;;
    esac
    (( $(wc -c < "$library") > MAX_SIZE )) || continue

    expected=$(sha256_file "$library")
    install_chunks "$library" "$library" "$expected"
    rm -f -- "$library"
done

shopt -u nullglob

# Regenerate every launcher that has a corresponding bundled binary.
for binary in "$BIN_DIR"/*; do
    [ -f "$binary" ] && [ -x "$binary" ] || continue
    wrapper="$REPO_ROOT/${binary##*/}"
    temporary=$(mktemp "$REPO_ROOT/.wrapper.tmp.XXXXXX")
    cat > "$temporary" <<'WRAPPER'
#!/bin/bash

set -e

DIR=$(dirname "$(realpath "$0")")
LIBS="$DIR/root/lib64"
BIN="$DIR/root/bin/$(basename "$0")"

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

shopt -s nullglob
CHECKSUMS=("$LIBS"/*.sha256)

for CHECKSUM in "${CHECKSUMS[@]}"; do
    LIBRARY=${CHECKSUM%.sha256}
    NAME=${LIBRARY##*/}

    if ! read -r EXPECTED _ < "$CHECKSUM" ||
       [[ ! "$EXPECTED" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "$(basename "$0"): invalid checksum file: $CHECKSUM" >&2
        exit 1
    fi

    if [ ! -f "$LIBRARY" ] || [ "$(sha256_file "$LIBRARY")" != "$EXPECTED" ]; then
        PARTS=("$LIBRARY".part.*)
        if ((${#PARTS[@]} == 0)); then
            echo "$(basename "$0"): no chunks found for $NAME" >&2
            exit 1
        fi

        TMP=$(mktemp "$LIBS/.${NAME}.tmp.XXXXXX")
        trap 'rm -f "$TMP"' EXIT HUP INT TERM
        cat "${PARTS[@]}" > "$TMP"

        if [ "$(sha256_file "$TMP")" != "$EXPECTED" ]; then
            echo "$(basename "$0"): reconstructed $NAME failed SHA-256 validation" >&2
            exit 1
        fi

        mv -f "$TMP" "$LIBRARY"
        trap - EXIT HUP INT TERM
    fi
done

exec env \
    LD_LIBRARY_PATH="$LIBS:${LD_LIBRARY_PATH:-}" \
    "$LIBS/ld-linux-x86-64.so.2" \
    "$BIN" "$@"
WRAPPER
    chmod 755 "$temporary"
    mv -f "$temporary" "$wrapper"
done
