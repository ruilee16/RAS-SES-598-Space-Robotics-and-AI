#!/bin/bash
# ============================================================
#  launch_px4_stack.sh
#  One-click launcher for the full PX4 + ROS2 stack
#
#  Opens 8 terminals in order:
#    1. PX4 SITL + Gazebo
#    2. MicroXRCE-DDS Agent  (PX4 <-> ROS2)
#    3. QGroundControl
#    4. cylinder_landing.launch.py  (bridge + throttles + env)
#    5. Log watcher  (mission state, battery, height)
#    6. mission.launch.py  (mission nodes, starts after 30s delay)
#    7. Mission monitor (logs everything to ~/ros2_ws/logs/)
#    8. Spare ROS2 terminal
#
#  BANDWIDTH FIX: cylinder_landing.launch.py uses our own
#  image_throttle nodes (built into the package) to cap all camera
#  streams to 5 Hz — no topic_tools install required.
#
#  Usage:
#    chmod +x launch_px4_stack.sh
#    ./launch_px4_stack.sh
# ============================================================

# ── USER CONFIG ──────────────────────────────────────────────
PX4_DIR="$HOME/PX4-Autopilot"
PX4_MODEL="gz_x500_depth_mono"

XRCE_AGENT="/usr/local/bin/MicroXRCEAgent"
XRCE_PORT="8888"

ROS2_WS="$HOME/ros2_ws"
ROS_DISTRO="jazzy"

QGC_APPIMAGE="$HOME/QGC/QGroundControl-x86_64.AppImage"
# ─────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║       PX4 Stack Launcher                 ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── PRE-FLIGHT CHECKS ────────────────────────────────────────
ERRORS=0
check() {
    if [ -e "$2" ]; then
        echo -e "  ${GREEN}✓${RESET}  $1: $2"
    else
        echo -e "  ${RED}✗${RESET}  $1 NOT FOUND: $2"
        ERRORS=$((ERRORS + 1))
    fi
}

echo -e "${YELLOW}Checking paths...${RESET}"
check "PX4-Autopilot"  "$PX4_DIR"
check "XRCE-DDS Agent" "$XRCE_AGENT"
check "ROS2 workspace" "$ROS2_WS"
check "QGC AppImage"   "$QGC_APPIMAGE"

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo -e "${RED}Fix the issues above before running.${RESET}"
    exit 1
fi

echo ""
echo -e "${GREEN}All checks passed — launching stack...${RESET}"
echo ""
sleep 1

# ── CLEANUP ──────────────────────────────────────────────────
echo -e "${YELLOW}Cleaning up stale processes...${RESET}"

# Helper: kill by pattern but never kill this script's own PID or its parent
safe_kill() {
    local pattern="$1"
    # Get PIDs matching pattern, exclude this script ($$) and its parent ($PPID)
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v "^$$\$" | grep -v "^$PPID\$" || true)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
    fi
}

# ROS / mission nodes
safe_kill "parameter_bridge"
safe_kill "image_throttle"
safe_kill "cylinder_mission"
safe_kill "aruco_tracker"
safe_kill "geometry_tracker"
safe_kill "MicroXRCEAgent"

# Gazebo — kill gz processes
safe_kill "gz sim"
safe_kill "gzserver"
safe_kill "gzclient"

# PX4 — kill after Gazebo so socket is released cleanly
safe_kill "bin/px4"
safe_kill "px4_sitl"
safe_kill "make px4_sitl"

# Wait for processes to fully exit
echo -e "${YELLOW}Waiting for processes to exit...${RESET}"
sleep 5
echo -e "${GREEN}Cleanup done.${RESET}"
echo ""

SRC="source /opt/ros/${ROS_DISTRO}/setup.bash && source ${ROS2_WS}/install/setup.bash"
# Path to this scripts folder (used by monitor and shutdown)
PKG_SCRIPTS="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# ── 2. MicroXRCE-DDS Agent ───────────────────────────────────
echo -e "${CYAN}[2/7]${RESET} MicroXRCE-DDS Agent on UDP port $XRCE_PORT"
gnome-terminal --title="XRCE-DDS Agent" -- bash -c "
    echo '=== MicroXRCE-DDS Agent ==='
    echo 'Bridging PX4 uORB <-> ROS2 on UDP:${XRCE_PORT}'
    source /opt/ros/${ROS_DISTRO}/setup.bash
    source ${ROS2_WS}/install/setup.bash 2>/dev/null || true
    ${XRCE_AGENT} udp4 -p ${XRCE_PORT}
    echo 'Agent exited. Press Enter to close.'
    read
"
sleep 2

# ── 1. PX4 SITL + Gazebo ─────────────────────────────────────
echo -e "${CYAN}[1/7]${RESET} PX4 SITL + Gazebo"
gnome-terminal --title="PX4 SITL" -- bash -c "
    echo '=== PX4 SITL + Gazebo ==='
    ${SRC}
    cd ${PX4_DIR}
    make px4_sitl ${PX4_MODEL}
    echo 'PX4 exited. Press Enter to close.'
    read
"
sleep 3



# ── 3. QGroundControl ────────────────────────────────────────
echo -e "${CYAN}[3/7]${RESET} QGroundControl"
gnome-terminal --title="QGroundControl" -- bash -c "
    chmod +x ${QGC_APPIMAGE}
    ${QGC_APPIMAGE}
    echo 'QGC exited. Press Enter to close.'
    read
"
sleep 2

# ── 4. cylinder_landing.launch.py (bridge + throttles + env) ─
echo -e "${CYAN}[4/7]${RESET} cylinder_landing.launch.py"
gnome-terminal --title="ROS2 — cylinder_landing" -- bash -c "
    echo '=== cylinder_landing.launch.py ==='
    echo 'Starts: Gz bridge + image throttle nodes + cylinder spawner'
    ${SRC}
    ros2 launch terrain_mapping_drone_control cylinder_landing.launch.py
    echo 'Launch exited. Press Enter to close.'
    read
"

# ── 5. Log watcher ───────────────────────────────────────────
echo -e "${CYAN}[5/7]${RESET} Mission log watcher"
gnome-terminal --title="Log Watcher" -- bash -c "
    ${SRC}
    echo '=== Watching mission logs ==='
    ros2 topic echo /rosout 2>/dev/null | grep --line-buffered -E \
        'intrinsics|battery|Arm command|Offboard|TAKEOFF|CIRCLE|SERVO|HOVER|ARUCO|LAND|height|Height|state'
    echo 'Watcher exited. Press Enter to close.'
    read
"

# ── Wait for sim to be ready ─────────────────────────────────
echo -e "${YELLOW}Waiting 30s for Gazebo + bridge to fully initialise...${RESET}"
sleep 20

# ── 6. mission.launch.py (mission nodes only) ────────────────
echo -e "${CYAN}[6/7]${RESET} mission.launch.py"
gnome-terminal --title="ROS2 — mission" -- bash -c "
    echo '=== mission.launch.py ==='
    echo 'Starts: aruco_tracker, geometry_tracker, cylinder_mission'
    ${SRC}
    ros2 launch terrain_mapping_drone_control mission.launch.py
    echo 'Mission exited. Press Enter to close.'
    read
"
sleep 2

# ── 7. Mission monitor ───────────────────────────────────────
echo -e "${CYAN}[7/8]${RESET} Mission monitor"
gnome-terminal --title="Mission Monitor" -- bash -c "
    ${SRC}
    echo '=== Mission Monitor ==='
    echo 'Recording all topics, errors, and system health...'
    echo 'Logs saved to: ~/ros2_ws/logs/'
    echo ''
    bash ${PKG_SCRIPTS}/mission_monitor.sh
    echo 'Monitor stopped. Press Enter to close.'
    read
"
sleep 1

# ── 8. Spare terminal ────────────────────────────────────────
echo -e "${CYAN}[8/8]${RESET} Spare terminal"
gnome-terminal --title="ROS2 — spare" -- bash -c "
    ${SRC}
    echo '=== ROS2 Terminal Ready ==='
    echo ''
    echo 'Useful commands:'
    echo '  ros2 topic list | grep -E "fmu|drone|aruco|geometry"'
    echo '  ros2 topic hz /drone/front_rgb/throttled  # should be ~5 Hz'
    echo '  ros2 topic echo /fmu/out/vehicle_odometry --once'
    echo '  ros2 topic echo /aruco/marker_pose'
    echo '  ros2 topic echo /geometry/cylinder_center'
    echo ''
    echo 'To shutdown cleanly:  bash ${PKG_SCRIPTS}/shutdown.sh'
    echo ''
    exec bash
"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║  All 8 terminals launched!               ║${RESET}"
echo -e "${GREEN}╠══════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}║  Expected startup order:                 ║${RESET}"
echo -e "${GREEN}║  1. Gazebo loads (~15-20s)               ║${RESET}"
echo -e "${GREEN}║  2. XRCE Agent shows connected           ║${RESET}"
echo -e "${GREEN}║  3. QGC connects automatically           ║${RESET}"
echo -e "${GREEN}║  4. Bridge + throttles come up (~30s)    ║${RESET}"
echo -e "${GREEN}║  5. Mission nodes start                  ║${RESET}"
echo -e "${GREEN}║  6. Monitor logs to ~/ros2_ws/logs/      ║${RESET}"
echo -e "${GREEN}║  Stop: bash scripts/shutdown.sh          ║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║  All 8 terminals launched!               ║${RESET}"
echo -e "${GREEN}╠══════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}║  Expected startup order:                 ║${RESET}"
echo -e "${GREEN}║  1. Gazebo loads (~15-20s)               ║${RESET}"
echo -e "${GREEN}║  2. XRCE Agent shows 'connected'         ║${RESET}"
echo -e "${GREEN}║  3. QGC connects automatically           ║${RESET}"
echo -e "${GREEN}║  4. Bridge + throttles come up (~30s)    ║${RESET}"
echo -e "${GREEN}║  5. mission.launch.py starts nodes       ║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${RESET}"
echo ""