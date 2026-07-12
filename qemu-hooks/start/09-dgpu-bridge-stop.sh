#!/bin/bash
set -euo pipefail

########## ########### ##########
########## dGPU Bridge ##########
########## ########### ##########

systemctl stop gpu-temp-bridge.service 2>/dev/null || true

sleep 1
