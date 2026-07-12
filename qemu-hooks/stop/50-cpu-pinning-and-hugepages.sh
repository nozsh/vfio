#!/bin/bash
set -euo pipefail

########## ########### # ######### ##########
########## CPU Pinning & HugePages ##########
########## ########### # ######### ##########

ALL_CPUS="0-15"
VM_CPUS="2,3,4,5,6,7,10,11,12,13,14,15"

# Restore governor
for cpu in $(echo $VM_CPUS | tr ',' ' '); do
    GOV_FILE="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor"
    EPP_FILE="/sys/devices/system/cpu/cpu${cpu}/cpufreq/energy_performance_preference"

    if [ -f "/run/kvm-hook-state/governor-cpu${cpu}" ]; then
        cat "/run/kvm-hook-state/governor-cpu${cpu}" > "$GOV_FILE" 2>/dev/null || true
        rm -f "/run/kvm-hook-state/governor-cpu${cpu}"
    fi

    if [ -f "/run/kvm-hook-state/epp-cpu${cpu}" ]; then
        cat "/run/kvm-hook-state/epp-cpu${cpu}" > "$EPP_FILE" 2>/dev/null || true
        rm -f "/run/kvm-hook-state/epp-cpu${cpu}"
    fi
done
rmdir /run/kvm-hook-state 2>/dev/null || true

# Free hugepages
sleep 1
echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Return all cores to host
systemctl set-property --runtime system.slice AllowedCPUs="$ALL_CPUS"
systemctl set-property --runtime user.slice   AllowedCPUs="$ALL_CPUS"
systemctl set-property --runtime init.scope   AllowedCPUs="$ALL_CPUS"
