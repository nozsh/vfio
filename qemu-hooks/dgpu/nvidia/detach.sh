#!/bin/bash
set -euo pipefail

########## #### ###### ##########
########## dGPU Detach ##########
########## #### ###### ##########

NVIDIA_PCI="0000:01:00.0"
NVIDIA_AUDIO_PCI="0000:01:00.1"
NVIDIA_DRM_CARD=$(ls /sys/bus/pci/devices/${NVIDIA_PCI}/drm/ 2>/dev/null | grep '^card')
DISPLAY_USER=$(loginctl list-sessions --no-legend | awk '{print $3}' | head -1)
DISPLAY_UID=$(id -u "$DISPLAY_USER")

# Stop nvidia-persistenced (it holds /dev/nvidia0)
systemctl stop nvidia-persistenced 2>/dev/null || true
sleep 0.5

# Kill powerdevil (may hold the card's I2C bus) (KDE)
runuser -l "$DISPLAY_USER" -c "export XDG_RUNTIME_DIR=/run/user/${DISPLAY_UID}; systemctl --user stop plasma-powerdevil.service" 2>/dev/null || true

sleep 0.5

# Send a fake udev "card removed" event
if [ -n "$NVIDIA_DRM_CARD" ] && [ -f "/sys/bus/pci/devices/${NVIDIA_PCI}/drm/${NVIDIA_DRM_CARD}/uevent" ]; then
    echo -n "remove" > /sys/bus/pci/devices/${NVIDIA_PCI}/drm/${NVIDIA_DRM_CARD}/uevent
    sleep 1
fi

# Check that nothing else is still holding the card
LEFTOVER=$(lsof /dev/nvidia0 /dev/dri/${NVIDIA_DRM_CARD} 2>/dev/null | awk 'NR>1 {print $1, $2}' | sort -u || true)
if [ -n "$LEFTOVER" ]; then
    lsof /dev/nvidia0 /dev/dri/${NVIDIA_DRM_CARD} 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | xargs -r kill -9 2>/dev/null || true
    sleep 1
fi

# Unload NVIDIA modules
modprobe -r nvidia_drm
modprobe -r nvidia_modeset
modprobe -r nvidia_uvm
modprobe -r nvidia

# Bind to vfio-pci
modprobe vfio-pci

echo "vfio-pci" > /sys/bus/pci/devices/${NVIDIA_PCI}/driver_override
echo "${NVIDIA_PCI}" > /sys/bus/pci/drivers/vfio-pci/bind

# Audio
echo "${NVIDIA_AUDIO_PCI}" > /sys/bus/pci/drivers/snd_hda_intel/unbind 2>/dev/null || true
sleep 0.3
echo "vfio-pci" > /sys/bus/pci/devices/${NVIDIA_AUDIO_PCI}/driver_override
echo "${NVIDIA_AUDIO_PCI}" > /sys/bus/pci/drivers/vfio-pci/bind
