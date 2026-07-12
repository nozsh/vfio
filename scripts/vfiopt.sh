#!/bin/bash
# vfiopt - switch GPU between vfio-pci and host driver

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

CONFIG="$SCRIPT_DIR/vfiopt.conf"
MODPROBE_VFIO="$SCRIPT_DIR/modprobe-vfio.conf"
DRACUT_VFIO="$SCRIPT_DIR/dracut-vfio.conf"

TARGET_MODPROBE="/etc/modprobe.d/vfio.conf"
TARGET_DRACUT="/etc/dracut.conf.d/vfio.conf"
VFIO_SCRIPT="/sbin/vfio-pci-override.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load config
if [[ ! -f "$CONFIG" ]]; then
    echo -e "${RED}Config not found: $CONFIG${NC}"
    echo "Create vfiopt.conf next to the script:"
    echo '  DGPU_DEVS="0000:01:00.0 0000:01:00.1"'
    exit 1
fi
source "$CONFIG"

if [[ -z "$DGPU_DEVS" ]]; then
    echo -e "${RED}DGPU_DEVS is not set in $CONFIG${NC}"
    exit 1
fi

get_current_mode() {
    local first_dev
    first_dev=$(echo "$DGPU_DEVS" | awk '{print $1}' | sed 's/0000://')
    lspci -k | grep -A3 "$first_dev" | grep "Kernel driver in use" | awk '{print $NF}'
}

show_status() {
    local mode
    mode=$(get_current_mode)
    echo ""
    echo -e "${BLUE}=== vfiopt ===${NC}"
    echo ""
    for DEV in $DGPU_DEVS; do
        local short
        short=$(echo "$DEV" | sed 's/0000://')
        lspci -k | grep -A3 "$short" | grep -v "^--$"
        echo ""
    done
    if [[ "$mode" == "vfio-pci" ]]; then
        echo -e "Current mode: ${GREEN}vfio-pci${NC} (GPU is passed through to VM)"
    elif [[ -n "$mode" ]]; then
        echo -e "Current mode: ${YELLOW}$mode${NC} (GPU is used by host)"
    else
        echo -e "Current mode: ${RED}unknown${NC}"
    fi
    echo ""
}

confirm() {
    echo -ne "${YELLOW}$1 [y/N]: ${NC}"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

rebuild_initramfs() {
    echo -e "${BLUE}Rebuilding initramfs...${NC}"
    sdbootutil --no-reuse-initrd add-all-kernels
    echo -e "${GREEN}Done.${NC}"
}

switch_to_vfio() {
    echo -e "${BLUE}Switching to vfio-pci mode...${NC}"
    echo ""

    if [[ ! -f "$VFIO_SCRIPT" ]]; then
        echo -e "${RED}Script $VFIO_SCRIPT not found.${NC}"
        echo "Create /sbin/vfio-pci-override.sh with the required PCI addresses."
        echo ""
        echo "Example:"
        echo '  #!/bin/sh'
        echo '  DEVS="0000:01:00.0 0000:01:00.1"'
        echo '  for DEV in $DEVS; do'
        echo '      echo "vfio-pci" > /sys/bus/pci/devices/$DEV/driver_override'
        echo '  done'
        echo '  modprobe -i vfio-pci'
        exit 1
    fi

    cp "$MODPROBE_VFIO" "$TARGET_MODPROBE"
    echo "  Copied: $TARGET_MODPROBE"

    cp "$DRACUT_VFIO" "$TARGET_DRACUT"
    echo "  Copied: $TARGET_DRACUT"

    echo ""
    rebuild_initramfs

    echo ""
    echo -e "${GREEN}Done. Reboot to apply the changes.${NC}"
}

switch_to_host() {
    echo -e "${BLUE}Switching to host mode...${NC}"
    echo ""

    [[ -f "$TARGET_MODPROBE" ]] && rm "$TARGET_MODPROBE" && echo "  Removed: $TARGET_MODPROBE"
    [[ -f "$TARGET_DRACUT" ]] && rm "$TARGET_DRACUT" && echo "  Removed: $TARGET_DRACUT"

    echo ""
    rebuild_initramfs

    echo ""
    echo -e "${GREEN}Done. Reboot to apply the changes.${NC}"
}

show_status

mode=$(get_current_mode)

if [[ "$mode" == "vfio-pci" ]]; then
    if confirm "Switch to host mode (GPU will be returned to the system)?"; then
        switch_to_host
    else
        echo "Cancelled."
    fi
else
    if confirm "Switch to vfio-pci mode (GPU will go to VM)?"; then
        switch_to_vfio
    else
        echo "Cancelled."
    fi
fi
