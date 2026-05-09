#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/../../logs"
PID_DIR="$SCRIPT_DIR/../../pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

PYTHON_CMD="/root/miniconda3/envs/vlm_rag310/bin/python"
LOG_FILE="$LOG_DIR/mock_mineru.log"
PID_FILE="$PID_DIR/mock_mineru.pid"

if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE")
  if ps -p "$old_pid" > /dev/null 2>&1; then
    echo "mock_mineru already running: PID $old_pid"
    exit 0
  fi
fi

if command -v setsid >/dev/null 2>&1; then
  setsid "$PYTHON_CMD" mock_mineru_api.py > "$LOG_FILE" 2>&1 < /dev/null &
else
  nohup "$PYTHON_CMD" mock_mineru_api.py > "$LOG_FILE" 2>&1 < /dev/null &
fi

pid=$!
echo "$pid" > "$PID_FILE"
echo "mock_mineru started: PID $pid"
