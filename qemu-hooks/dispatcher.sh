#!/bin/bash
GUEST_NAME="$1"
HOOK_NAME="$2"
STATE_NAME="$3"

BASEDIR="$(dirname $0)"
HOOKPATH="$BASEDIR/qemu.d/$GUEST_NAME/$HOOK_NAME/$STATE_NAME"

set -e

if [ -d "$HOOKPATH" ]; then
    for hook in "$HOOKPATH"/*.sh; do
        [ -x "$hook" ] && "$hook" "$@"
    done
fi
