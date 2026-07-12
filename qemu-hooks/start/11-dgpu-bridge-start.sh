#!/bin/bash
set -euo pipefail

########## ########### ##########
########## dGPU Bridge ##########
########## ########### ##########

systemctl start gpu-temp-bridge.service 2>/dev/null || true
