#!/bin/bash
set -euo pipefail

########## ########### # ######### ##########
########## CPU Pinning & HugePages ##########
########## ########### # ######### ##########

VM_CPUS="2,3,4,5,6,7,10,11,12,13,14,15"
HOST_CPUS="0,1,8,9"

# Push host processes onto HOST_CPUS
systemctl set-property --runtime system.slice AllowedCPUs="$HOST_CPUS"
systemctl set-property --runtime user.slice   AllowedCPUs="$HOST_CPUS"
systemctl set-property --runtime init.scope   AllowedCPUs="$HOST_CPUS"

# Clear cache
sync
echo 3 > /proc/sys/vm/drop_caches

# Allocate hugepages iteratively
TARGET=16384 # = 32 GB * 512
STEP=1024    # If it stalls: 512 --> 256 --> 128 ; these are MiB * 4kb/2mb/1gb, smaller = slower but safer
CURRENT=0

while [ "$CURRENT" -lt "$TARGET" ]; do
    NEXT=$(( CURRENT + STEP ))
    [ "$NEXT" -gt "$TARGET" ] && NEXT=$TARGET
    echo $NEXT > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    ACTUAL=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    if [ "$ACTUAL" -lt "$NEXT" ]; then
        logger -t kvm-hook "WARNING: stuck at $ACTUAL out of $TARGET"
        break
    fi
    CURRENT=$ACTUAL
    sleep 0.1
done

ACTUAL=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
if [ "$ACTUAL" -lt "$TARGET" ]; then
    logger -t kvm-hook "WARNING: requested $TARGET hugepages, allocated $ACTUAL"
fi

# CPU governor -> performance
mkdir -p /run/kvm-hook-state
for cpu in $(echo $VM_CPUS | tr ',' ' '); do
    GOV_FILE="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor"
    EPP_FILE="/sys/devices/system/cpu/cpu${cpu}/cpufreq/energy_performance_preference"

    cat "$GOV_FILE" > "/run/kvm-hook-state/governor-cpu${cpu}"
    [ -f "$EPP_FILE" ] && cat "$EPP_FILE" > "/run/kvm-hook-state/epp-cpu${cpu}" 2>/dev/null || true

    echo performance > "$GOV_FILE" 2>/dev/null || true
    [ -f "$EPP_FILE" ] && echo performance > "$EPP_FILE" 2>/dev/null || true
done
