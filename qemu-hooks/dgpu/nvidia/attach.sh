#!/bin/bash
set -euo pipefail

########## #### ###### ##########
########## dGPU Attach ##########
########## #### ###### ##########

NVIDIA_PCI="0000:01:00.0"
NVIDIA_AUDIO_PCI="0000:01:00.1"
DISPLAY_USER=$(loginctl list-sessions --no-legend | awk '{print $3}' | head -1)
DISPLAY_UID=$(id -u "$DISPLAY_USER")

# Unbind from vfio-pci
echo "${NVIDIA_PCI}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
echo "${NVIDIA_AUDIO_PCI}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true

# Reset driver_override
echo "" > /sys/bus/pci/devices/${NVIDIA_PCI}/driver_override || true
echo "" > /sys/bus/pci/devices/${NVIDIA_AUDIO_PCI}/driver_override || true

# Load NVIDIA modules
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_uvm
modprobe nvidia_drm modeset=1

sleep 1

# Bind back to nvidia
echo "${NVIDIA_PCI}" > /sys/bus/pci/drivers/nvidia/bind || true
echo "${NVIDIA_AUDIO_PCI}" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null || true

# Restore nvidia-persistenced
systemctl start nvidia-persistenced 2>/dev/null || true

# Restore powerdevil (KDE)
runuser -l "$DISPLAY_USER" -c "export XDG_RUNTIME_DIR=/run/user/${DISPLAY_UID}; systemctl --user start plasma-powerdevil.service" 2>/dev/null || true
