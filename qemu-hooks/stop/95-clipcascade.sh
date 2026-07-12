#!/bin/bash
set -euo pipefail

########## ########### ##########
########## ClipCascade ##########
########## ########### ##########

DISPLAY_USER=$(loginctl list-sessions --no-legend | awk '{print $3}' | head -1)
runuser -l $DISPLAY_USER -c "export XDG_RUNTIME_DIR=/run/user/\$UID; systemctl --user stop clipcascade.service"
systemctl stop clipcascade-server-docker.service

nft delete table inet clipcascade-in-da-hook 2>/dev/null