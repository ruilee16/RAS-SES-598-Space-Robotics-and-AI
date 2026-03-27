#!/bin/bash
# ============================================================
#  mission_monitor.sh
#  Records everything needed to debug the mission while it runs.
#
#  Logs to: ~/ros2_ws/logs/mission_YYYYMMDD_HHMMSS/
#
#  Captures:
#    - ROS topic rates (fmu, drone, aruco, geometry)
#    - /rosout (all node log messages)
#    - vehicle_status (arming, nav_state)
#    - vehicle_odometry (position)
#    - RTPS/DDS errors from stderr
#    - CPU / RAM / network bandwidth (every 5s)
#    - Node list (every 10s)
#
#  Usage:
#    bash scripts/mission_monitor.sh
#    (run in its own terminal while the mission is active)
#
#  Stop with Ctrl+C — logs are saved automatically.
# ============================================================

ROS_DISTRO="${ROS_DISTRO:-jazzy}"
ROS2_WS="${ROS2_WS:-$HOME/ros2_ws}"

# Source ROS if not already sourced
if ! command -v ros2 &>/dev/null; then
    source "/opt/ros/${ROS_DISTRO}/setup.bash"
fi
if ! echo "$AMENT_PREFIX_PATH" | grep -q "ros2_ws"; then
    source "${ROS2_WS}/install/setup.bash" 2>/dev/null || true
fi

# ── Log directory ─────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/ros2_ws/logs/mission_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; RESET='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║        mission_monitor.sh                ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo -e "  Logging to: ${YELLOW}${LOG_DIR}${RESET}"
echo -e "  Press ${RED}Ctrl+C${RESET} to stop and save logs."
echo ""

# ── Write session header ──────────────────────────────────────
SESSION_LOG="$LOG_DIR/session_info.txt"
{
    echo "====== Mission Monitor Session ======"
    echo "Started  : $(date)"
    echo "Hostname : $(hostname)"
    echo "ROS      : ${ROS_DISTRO}"
    echo "Workspace: ${ROS2_WS}"
    echo ""
    echo "=== ROS nodes at start ==="
    ros2 node list 2>/dev/null || echo "(no nodes yet)"
    echo ""
    echo "=== ROS topics at start ==="
    ros2 topic list 2>/dev/null || echo "(no topics yet)"
    echo ""
    echo "=== px4_msgs branch ==="
    cd ~/ros2_ws/src/px4_msgs 2>/dev/null && git describe --tags 2>/dev/null || echo "unknown"
    echo ""
    echo "=== PX4 firmware version ==="
    cd ~/PX4-Autopilot 2>/dev/null && git describe --tags 2>/dev/null || echo "unknown"

} > "$SESSION_LOG"

# ── Background loggers ────────────────────────────────────────


# 2. Vehicle status (arming state, nav state) — every message
ros2 topic echo /fmu/out/vehicle_status_v1 2>/dev/null \
    > "$LOG_DIR/vehicle_status.log" &
PID_STATUS=$!

# 3. Vehicle odometry (position) — throttled to 2 Hz for readability
ros2 topic echo /fmu/out/vehicle_odometry --qos-reliability best_effort 2>/dev/null \
    > "$LOG_DIR/vehicle_odometry.log" &
PID_ODOM=$!

# 4. ArUco marker detections
ros2 topic echo /aruco/marker_pose 2>/dev/null \
    > "$LOG_DIR/aruco_detections.log" &
PID_ARUCO=$!

# 5. Cylinder geometry detections
ros2 topic echo /geometry/cylinder_center 2>/dev/null \
    > "$LOG_DIR/cylinder_detections.log" &
PID_GEOM=$!

# 6. STDERR capture — catches RTPS/DDS errors like payload size mismatch
# We do this by watching journald for the relevant processes
journalctl -f --no-pager 2>/dev/null \
    | grep -i "RTPS\|payload\|DDS\|px4\|xrce\|terrain_mapping" \
    > "$LOG_DIR/dds_errors.log" &
PID_JOURNAL=$!

# 7. System health — CPU, RAM, network every 5 seconds
IFACE=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
(
while true; do
    TS=$(date +%H:%M:%S)
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    MEM_USED_PCT=$(( 100 * (MEM_TOTAL - MEM_AVAIL) / MEM_TOTAL ))
    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)

    # Network TX rate
    if [ -n "$IFACE" ]; then
        TX1=$(grep "$IFACE" /proc/net/dev 2>/dev/null | awk '{print $10}')
        sleep 1
        TX2=$(grep "$IFACE" /proc/net/dev 2>/dev/null | awk '{print $10}')
        TX_KB=$(( (TX2 - TX1) / 1024 ))
    else
        sleep 1
        TX_KB=0
    fi

    echo "${TS}  CPU:${CPU}%  RAM:${MEM_USED_PCT}%  NET_TX:${TX_KB}KB/s"
    sleep 4
done
) > "$LOG_DIR/system_health.log" &
PID_SYSHEALTH=$!

# 8. Topic Hz rates — check every 30 seconds
(
while true; do
    TS=$(date +%H:%M:%S)
    echo "====== ${TS} ======"
    for topic in \
        /fmu/out/vehicle_odometry \
        /fmu/out/vehicle_status \
        /drone/front_rgb/throttled \
        /drone/front_depth/throttled \
        /drone/down_mono/throttled \
        /aruco/marker_pose \
        /geometry/cylinder_center
    do
        HZ=$(timeout 3 ros2 topic hz "$topic" 2>/dev/null \
            | grep "average rate" | awk '{print $3}' || echo "N/A")
        echo "  $topic: ${HZ} Hz"
    done
    echo ""
    sleep 27
done
) > "$LOG_DIR/topic_rates.log" &
PID_HZ=$!

# 9. Node list — snapshot every 10 seconds
(
while true; do
    echo "====== $(date +%H:%M:%S) ======"
    ros2 node list 2>/dev/null || echo "(no nodes)"
    echo ""
    sleep 10
done
) > "$LOG_DIR/node_list.log" &
PID_NODES=$!

# ── Live console summary ───────────────────────────────────────
echo -e "${GREEN}Monitoring started. Live summary:${RESET}"
echo -e "  (full details in ${YELLOW}${LOG_DIR}${RESET})"
echo ""

ALL_PIDS="$PID_ROSOUT $PID_STATUS $PID_ODOM $PID_ARUCO $PID_GEOM $PID_JOURNAL $PID_SYSHEALTH $PID_HZ $PID_NODES"

# Show a live tail of rosout filtered for important events
tail -f "$LOG_DIR/rosout.log" 2>/dev/null \
    | grep --line-buffered -i \
        "error\|fail\|warn\|arm\|takeoff\|land\|circle\|aruco\|cylinder\|RTPS\|payload\|state\|intrinsic" &
PID_TAIL=$!

# ── Cleanup on Ctrl+C ─────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping monitor and saving logs...${RESET}"

    kill $PID_TAIL $ALL_PIDS 2>/dev/null
    wait 2>/dev/null

    # Write session footer
    {
        echo ""
        echo "====== Session End ======"
        echo "Stopped: $(date)"
        echo ""
        echo "=== Final node list ==="
        ros2 node list 2>/dev/null || echo "(none)"
        echo ""
        echo "=== Log files ==="
        ls -lh "$LOG_DIR/"
    } >> "$SESSION_LOG"

    # Print summary
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}Logs saved to: ${LOG_DIR}${RESET}"
    echo ""
    echo "  Files:"
    ls -lh "$LOG_DIR/" | awk '{print "    " $0}'
    echo ""

    # Show error summary
    ERROR_COUNT=$(grep -c -i "error\|RTPS\|payload\|fail" \
        "$LOG_DIR/rosout.log" "$LOG_DIR/dds_errors.log" 2>/dev/null || echo 0)
    echo -e "  ${RED}Total errors/warnings captured: ${ERROR_COUNT}${RESET}"
    echo ""
    echo "  Quick error review:"
    grep -i "error\|RTPS\|payload\|fail" \
        "$LOG_DIR/rosout.log" 2>/dev/null | tail -10 || echo "    (none)"
    echo -e "${CYAN}════════════════════════════════════════════${RESET}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Keep running until Ctrl+C
wait $PID_TAIL