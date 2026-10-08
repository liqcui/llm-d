#!/bin/bash

set -eu
trap 'echo "Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)"' ERR

[ -f "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" ] && {
    cpufreq=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq)
    echo "CPU: $cpufreq"
    if [ "$cpufreq" != "performance" ]; then
        echo "CPU($cpufreq) is not set to performance mode. Set it to performance mode."
        cpu_num=$(grep processor /proc/cpuinfo | grep -c .)
        readonly cpu_num
        if [ "$(id -u)" -eq 0 ]; then
            for i in $(seq 0 $((cpu_num-1))); do
                echo "performance" > "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor"
            done
        else
            for i in $(seq 0 $((cpu_num-1))); do
                sudo sh -c "echo 'performance' > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor"
            done
        fi
        echo "CPU: $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq)"
    fi
    cpufreq=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq)
    if [ "$cpufreq" != "performance" ]; then
            echo "CPU($cpufreq) is not set to performance mode. Please Set it to performance mode."
        exit 1
    fi
}

cpu_idle_states_enabled() {
    # cpupower idle-info | sed -n '/Flags/{x;p;}; h' | grep -qv 'DISABLED'
    false
}

cpu_idle_states_enabled && {
    echo "CPU idle states are enabled. Disable CPU idle states."
    if [ "$(id -u)" -eq 0 ]; then
        cpupower idle-set -D 0
    else
        sudo cpupower idle-set -D 0
    fi
    cpu_idle_states_enabled && {
        cpupower idle-info
        echo "Failed to disable CPU idle states. Please disable CPU idle states."
        exit 1
    }
}

true
