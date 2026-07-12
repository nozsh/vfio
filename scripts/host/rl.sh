#!/usr/bin/env bash
# rl - creates symlinks in the Samba share instead of copying files
# Usage: rl <file|dir> [file|dir ...]

# ── Configuration ─────────────────────────────────────────────────────────────
# Format: ["disk_mount_point"]="its_dir_in_the_share"
# Order doesn't matter
declare -A DISKS=(
    ["/"]="$HOME/Public/KVM"
)
# ─────────────────────────────────────────────────────────────────────────────

BOLD=$'\e[1m'
DIM=$'\e[2m'
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
RESET=$'\e[0m'

usage() {
    cat <<USAGE

${BOLD}rl${RESET} - creates symlinks in the KVM Samba share instead of copying files

${BOLD}Usage:${RESET}
  rl <file|dir> [file|dir ...]

${BOLD}Examples:${RESET}
  rl ~/Downloads/game.iso
  rl /mnt/second/movies /mnt/second/music
  rl file1 file2 dir1

${BOLD}Configured disks:${RESET}
USAGE
    while IFS= read -r mount; do
        printf "  ${DIM}%-20s${RESET} → %s\n" "$mount" "${DISKS[$mount]}"
    done < <(printf '%s\n' "${!DISKS[@]}" | sort -r)
    echo
}

# Determines the share dir based on the file's path
resolve_share() {
    local target
    target=$(realpath "$1" 2>/dev/null) || { echo ""; return; }

    local best_mount=""
    local best_len=0

    for mount in "${!DISKS[@]}"; do
        local norm="${mount%/}"
        [[ -z "$norm" ]] && norm="/"

        local matches=0
        if [[ "$norm" == "/" ]]; then
            matches=1
        elif [[ "$target" == "$norm" || "$target" == "$norm/"* ]]; then
            matches=1
        fi

        if [[ $matches -eq 1 ]]; then
            local len=${#norm}
            if [[ $len -gt $best_len ]]; then
                best_len=$len
                best_mount=$mount
            fi
        fi
    done

    if [[ -n "$best_mount" ]]; then
        echo "${DISKS[$best_mount]}"
    else
        echo ""
    fi
}

# No arguments - show usage
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

errors=0

for arg in "$@"; do
    src=$(realpath "$arg" 2>/dev/null)
    if [[ -z "$src" || ! -e "$src" ]]; then
        echo "${RED}✗${RESET} Not found: $arg"
        (( errors++ ))
        continue
    fi

    share_dir=$(resolve_share "$src")
    if [[ -z "$share_dir" ]]; then
        echo "${RED}✗${RESET} No disk matches the path: $src"
        (( errors++ ))
        continue
    fi

    if [[ ! -d "$share_dir" ]]; then
        mkdir -p "$share_dir" || {
            echo "${RED}✗${RESET} Failed to create share dir: $share_dir"
            (( errors++ ))
            continue
        }
    fi

    name=$(basename "$src")
    link="$share_dir/$name"

    if [[ -e "$link" || -L "$link" ]]; then
        if [[ -L "$link" && "$(readlink "$link")" == "$src" ]]; then
            echo "${YELLOW}~${RESET} Already linked: $name → $share_dir"
        else
            echo "${RED}✗${RESET} Already exists (not a symlink to this source): $link"
            (( errors++ ))
        fi
        continue
    fi

    ln -s "$src" "$link" && \
        echo "${GREEN}✓${RESET} $name ${DIM}→${RESET} $share_dir" || {
        echo "${RED}✗${RESET} Failed to create symlink: $name"
        (( errors++ ))
    }
done

exit $errors
