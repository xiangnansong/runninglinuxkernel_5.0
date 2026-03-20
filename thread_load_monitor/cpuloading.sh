#!/bin/bash
# CPU Loading Monitor - Quick Start Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "CPU Loading Monitor - Quick Start"
echo "========================================"
echo

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root"
        echo "Usage: sudo $0"
        exit 1
    fi
}

build_module() {
    echo "[1/4] Building kernel module..."
    make clean 2>/dev/null || true
    make
    echo "Build completed!"
    echo
}

load_module() {
    echo "[2/4] Loading kernel module..."
    
    if lsmod | grep -q cpuloading_monitor; then
        echo "Module already loaded, unloading first..."
        rmmod cpuloading_monitor
    fi
    
    insmod cpuloading_monitor.ko "$@"
    echo "Module loaded successfully!"
    echo
}

show_status() {
    echo "[3/4] Module status:"
    echo "----------------------------------------"
    lsmod | grep cpuloading || echo "Module not loaded"
    echo "----------------------------------------"
    echo
    echo "Available proc interfaces:"
    echo "  /proc/cpuloading/stats  - Statistics summary"
    echo "  /proc/cpuloading/raw    - Raw data"
    echo "  /proc/cpuloading/json   - JSON format"
    echo "  /proc/cpuloading/csv    - CSV format"
    echo "  /proc/cpuloading/clear  - Clear records (write)"
    echo
}

collect_data() {
    echo "[4/4] Data collection:"
    echo "----------------------------------------"
    echo "Current statistics:"
    cat /proc/cpuloading/stats
    echo "----------------------------------------"
    echo
}

case "${1:-help}" in
    build)
        build_module
        ;;
    load)
        check_root
        shift
        load_module "$@"
        show_status
        ;;
    unload)
        check_root
        echo "Unloading module..."
        rmmod cpuloading_monitor
        echo "Module unloaded."
        ;;
    status)
        cat /proc/cpuloading/stats
        ;;
    collect)
        DURATION="${2:-10}"
        OUTPUT="${3:-cpu_data.json}"
        echo "Collecting data for $DURATION seconds..."
        sleep "$DURATION"
        cat /proc/cpuloading/json > "$OUTPUT"
        echo "Data saved to: $OUTPUT"
        ;;
    visualize)
        INPUT="${2:-cpu_data.json}"
        python3 visualize_cpu.py "$INPUT" --type summary
        ;;
    monitor)
        PID="$2"
        if [ -z "$PID" ]; then
            echo "Usage: $0 monitor <PID>"
            exit 1
        fi
        check_root
        build_module
        load_module "monitor_pid=$PID" "sample_interval_ms=500"
        show_status
        echo "Monitoring PID: $PID"
        echo "Press Ctrl+C to stop and collect data..."
        trap "cat /proc/cpuloading/json > cpu_pid_${PID}.json; echo 'Data saved to cpu_pid_${PID}.json'; rmmod cpuloading_monitor" EXIT
        sleep infinity
        ;;
    all)
        check_root
        build_module
        load_module
        show_status
        echo "Module is running. Use the following commands:"
        echo "  cat /proc/cpuloading/stats   - View statistics"
        echo "  cat /proc/cpuloading/json    - Get JSON data"
        echo "  echo 1 > /proc/cpuloading/clear - Clear records"
        ;;
    *)
        echo "Usage: $0 {build|load|unload|status|collect|visualize|monitor|all}"
        echo
        echo "Commands:"
        echo "  build           - Build the kernel module"
        echo "  load [params]   - Load the module with optional parameters"
        echo "  unload          - Unload the module"
        echo "  status          - Show current statistics"
        echo "  collect [sec]   - Collect data for N seconds (default: 10)"
        echo "  visualize [file]- Generate visualization"
        echo "  monitor <PID>   - Monitor specific PID and collect data"
        echo "  all             - Build, load, and show status"
        echo
        echo "Module Parameters:"
        echo "  sample_interval_ms=1000   - Sampling interval (ms)"
        echo "  monitor_pid=-1            - PID to monitor (-1 = all)"
        echo "  max_records=100000        - Max records to keep"
        echo
        echo "Examples:"
        echo "  sudo $0 load sample_interval_ms=500"
        echo "  sudo $0 monitor 1234"
        echo "  $0 collect 30 my_data.json"
        echo "  $0 visualize my_data.json"
        ;;
esac
