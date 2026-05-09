#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BACKEND_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
PID_FILE="${BACKEND_ROOT}/pids/paddleocr_vl.pid"
cd "$SCRIPT_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🛑 停止 PaddleOCR-VL API 服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if ps -p "$pid" >/dev/null 2>&1; then
        echo -e "${YELLOW}停止 PaddleOCR-VL (PID: ${pid})...${NC}"
        kill "$pid" 2>/dev/null || true
        count=0
        while ps -p "$pid" >/dev/null 2>&1 && [ $count -lt 15 ]; do
            sleep 1
            count=$((count + 1))
        done
        if ps -p "$pid" >/dev/null 2>&1; then
            echo -e "${YELLOW}  强制停止 PaddleOCR-VL...${NC}"
            kill -9 "$pid" 2>/dev/null || true
        fi
        echo -e "${GREEN}  ✓ PaddleOCR-VL 已停止${NC}"
    else
        echo -e "${YELLOW}  ⚠️  PaddleOCR-VL 进程不存在 (PID: ${pid})${NC}"
    fi
    rm -f "$PID_FILE"
else
    echo -e "${YELLOW}  ⚠️  未找到 PaddleOCR-VL PID 文件${NC}"
fi

pkill -f "uvicorn api_paddleocr_vl_mineru:app" 2>/dev/null && echo -e "${GREEN}  ✓ 已清理遗留 uvicorn 进程${NC}" || true
pkill -f "api_paddleocr_vl_mineru.py" 2>/dev/null && echo -e "${GREEN}  ✓ 已清理遗留脚本进程${NC}" || true

echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ PaddleOCR-VL 停止流程完成${NC}"
echo -e "${BLUE}========================================${NC}\n"
