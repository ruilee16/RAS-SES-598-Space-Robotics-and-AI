#!/bin/bash
# ============================================================
#  shutdown.sh
#  Gracefully shuts down all live mission processes,
#  saves final logs, and closes gnome-terminal windows.
#
#  Usage:
#    bash scripts/shutdown.sh
#    bash scripts/shutdown.sh --force   # skip graceful wait
# ============================================================

FORCE=false
[ "$1" = "--force" ] && FORCE=true

ROS_DISTRO="${ROS_DISTRO:-jazzy}"
ROS2_WS="${ROS2_WS:-$HOME/ros2_ws}"
LOG_DIR="$HOME/ros2_ws/logs"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; RESET='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║          shutdown.sh                     ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Source ROS ────────────────────────────────────────────────
if ! command -v ros2 &>/dev/null; then
    source "/opt/ros/${ROS_DISTRO}/setup.bash" 2>/dev/null || true
fi
source "${ROS2_WS}/install/setup.bash" 2>/dev/null || true

# ── Save final snapshot before killing anything ───────────────
SHUTDOWN_LOG="$LOG_DIR/shutdown_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

echo -e "${YELLOW}Saving final state snapshot...${RESET}"
{
    echo "====== Shutdown Snapshot ======"
    echo "Time: $(date)"
    echo ""
    echo "=== Live ROS nodes ==="
    ros2 node list 2>/dev/null || echo "(none)"
    echo ""
    echo "=== Live ROS topics ==="
    ros2 topic list 2>/dev/null || echo "(none)"
    echo ""
    echo "=== Vehicle status (last known) ==="
    timeout 3 ros2 topic echo /fmu/out/vehicle_status_v1 \
        --once 2>/dev/null || echo "(unavailable)"
    echo ""
    echo "=== Vehicle position (last known) ==="
    timeout 3 ros2 topic echo /fmu/out/vehicle_odometry \
        --once --qos-reliability best_effort 2>/dev/null || echo "(unavailable)"
    echo ""
    echo "=== Running processes ==="
    ps aux | grep -E "px4|gz|MicroXRCE|ros2|terrain_mapping|cylinder|aruco|geometry" \
           | grep -v grep
} > "$SHUTDOWN_LOG" 2>&1
echo -e "  ${GREEN}✓${RESET}  Snapshot saved: $SHUTDOWN_LOG"

# ── Helper: graceful then force kill ─────────────────────────
graceful_kill() {
    local label="$1"
    local pattern="$2"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v "^$$\$" | grep -v "^$PPID\$" || true)
    if [ -z "$pids" ]; then
        echo -e "  ${CYAN}⊘${RESET}  $label (not running)"
        return
    fi
    echo -n -e "  ${YELLOW}→${RESET}  Stopping $label... "
    echo "$pids" | xargs kill -SIGINT 2>/dev/null || true
    if [ "$FORCE" = false ]; then
        sleep 2
        # Check if still alive, escalate to SIGTERM
        pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v "^$$\$" | grep -v "^$PPID\$" || true)
        if [ -n "$pids" ]; then
            echo "$pids" | xargs kill -SIGTERM 2>/dev/null || true
            sleep 1
        fi
        # Final check — SIGKILL
        pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v "^$$\$" | grep -v "^$PPID\$" || true)
        if [ -n "$pids" ]; then
            echo "$pids" | xargs kill -SIGKILL 2>/dev/null || true
        fi
    else
        echo "$pids" | xargs kill -SIGKILL 2>/dev/null || true
    fi
    echo -e "${GREEN}done${RESET}"
}

# ── Step 1: Stop mission nodes first (safest — drone lands) ──
echo ""
echo -e "${CYAN}── Step 1: Mission nodes ───────────────────${RESET}"
graceful_kill "cylinder_mission"   "cylinder_mission"
graceful_kill "aruco_tracker"      "aruco_tracker"
graceful_kill "geometry_tracker"   "geometry_tracker"
graceful_kill "image_throttle"     "image_throttle"
graceful_kill "pose_visualizer"    "pose_visualizer"
graceful_kill "feature_tracker"    "feature_tracker"

# ── Step 2: Stop ROS launch processes ────────────────────────
echo ""
echo -e "${CYAN}── Step 2: ROS launch / bridge ─────────────${RESET}"
graceful_kill "mission.launch"     "mission.launch"
graceful_kill "cylinder_landing"   "cylinder_landing"
graceful_kill "parameter_bridge"   "parameter_bridge"

# ── Step 3: Stop XRCE agent ───────────────────────────────────
echo ""
echo -e "${CYAN}── Step 3: XRCE-DDS Agent ──────────────────${RESET}"
graceful_kill "MicroXRCEAgent"     "MicroXRCEAgent"

# ── Step 4: Stop Gazebo ───────────────────────────────────────
echo ""
echo -e "${CYAN}── Step 4: Gazebo ──────────────────────────${RESET}"
graceful_kill "gz sim"             "gz sim"
graceful_kill "gzserver"           "gzserver"
graceful_kill "gzclient"           "gzclient"

# ── Step 5: Stop PX4 (last — after Gazebo releases socket) ───
echo ""
echo -e "${CYAN}── Step 5: PX4 ─────────────────────────────${RESET}"
graceful_kill "px4_sitl"           "px4_sitl"
graceful_kill "px4 binary"         "bin/px4"
graceful_kill "make px4_sitl"      "make px4_sitl"

# ── Step 6: Stop monitor if running ──────────────────────────
echo ""
echo -e "${CYAN}── Step 6: Monitor ─────────────────────────${RESET}"
graceful_kill "mission_monitor"    "mission_monitor"

# ── Step 7: Close gnome-terminal windows ─────────────────────
echo ""
echo -e "${CYAN}── Step 7: Terminal windows ────────────────${RESET}"
TERMINAL_TITLES=(
    "PX4 SITL"
    "XRCE-DDS Agent"
    "QGroundControl"
    "ROS2 — cylinder_landing"
    "Log Watcher"
    "ROS2 — mission"
    "ROS2 — spare"
    "Mission Monitor"
)
for title in "${TERMINAL_TITLES[@]}"; do
    WID=$(wmctrl -l 2>/dev/null | grep "$title" | awk '{print $1}')
    if [ -n "$WID" ]; then
        wmctrl -ic "$WID" 2>/dev/null
        echo -e "  ${GREEN}✓${RESET}  Closed: $title"
    fi
done

# ── Final wait and verify ─────────────────────────────────────
sleep 3
echo ""
echo -e "${CYAN}── Verification ────────────────────────────${RESET}"
STILL_RUNNING=$(pgrep -f "px4|gzserver|MicroXRCE|cylinder_mission|aruco_tracker" \
    2>/dev/null | grep -v "^$$\$" | grep -v "^$PPID\$" || true)
if [ -z "$STILL_RUNNING" ]; then
    echo -e "  ${GREEN}✓${RESET}  All processes stopped cleanly"
else
    echo -e "  ${YELLOW}⚠${RESET}  Some processes still running:"
    echo "$STILL_RUNNING" | while read pid; do
        echo "    PID $pid: $(ps -p $pid -o comm= 2>/dev/null)"
    done
    echo "  Run with --force to kill them immediately:"
    echo "    bash scripts/shutdown.sh --force"
fi

# ── Show log summary ──────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════${RESET}"
echo -e "${GREEN}Shutdown complete.${RESET}"
echo ""
echo "  Logs saved in: ${YELLOW}${LOG_DIR}${RESET}"
echo ""

# List all mission log sessions
if ls "$LOG_DIR"/mission_* &>/dev/null 2>&1; then
    echo "  Mission sessions:"
    for d in "$LOG_DIR"/mission_*/; do
        SIZE=$(du -sh "$d" 2>/dev/null | cut -f1)
        echo "    ${d}  (${SIZE})"
    done
    echo ""
fi

echo "  Shutdown log: ${YELLOW}${SHUTDOWN_LOG}${RESET}"
echo ""
echo "  To review errors from last session:"
echo "    grep -i 'error\|fail\|RTPS' ${LOG_DIR}/mission_*/rosout.log | tail -30"
echo -e "${CYAN}════════════════════════════════════════════${RESET}"