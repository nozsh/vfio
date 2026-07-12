#!/bin/bash
set -euo pipefail

########## ########### ##########
########## ClipCascade ##########
########## ########### ##########

CC_PORT=8080 # external clipcascade port from docker-compose file
MAX_ATTEMPTS=60 # 0.5s * 20 = 10s ; 30 = 15s ; 60 = 30s
DISPLAY_USER=$(loginctl list-sessions --no-legend | awk '{print $3}' | head -1)
CUR_ATTEMPTS=0

systemctl start clipcascade-server-docker.service

until [ "$(docker inspect -f '{{.State.Status}}' clipcascade 2>/dev/null)" == "running" ]; do # "clipcascade" container name from docker-compose file
    CUR_ATTEMPTS=$((CUR_ATTEMPTS + 1))

    if [ "$CUR_ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
        echo "ClipCascade container failed to start."
        exit 1
    fi

    sleep 0.5
done

CUR_ATTEMPTS=$(( (MAX_ATTEMPTS + 1) / 2 ))

until nc -z localhost $CC_PORT; do
    CUR_ATTEMPTS=$((CUR_ATTEMPTS + 1))

    if [ "$CUR_ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
        echo "ClipCascade no response."
        exit 1
    fi

    sleep 0.5
done

sleep 2

nft add table inet clipcascade-in-da-hook 2>/dev/null
nft add chain inet clipcascade-in-da-hook forward '{ type filter hook forward priority -10; policy accept; }' 2>/dev/null
nft flush chain inet clipcascade-in-da-hook forward
nft add rule inet clipcascade-in-da-hook forward iifname "virbr0" accept
nft add rule inet clipcascade-in-da-hook forward oifname "virbr0" accept

sleep 2

runuser -l $DISPLAY_USER -c "export XDG_RUNTIME_DIR=/run/user/\$UID; systemctl --user start clipcascade.service"