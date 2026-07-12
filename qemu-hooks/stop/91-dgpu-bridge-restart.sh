#!/bin/bash
set -euo pipefail

########## ########### ##########
########## dGPU Bridge ##########
########## ########### ##########

sleep 1

systemctl restart gpu-temp-bridge.service 2>/dev/null || true
