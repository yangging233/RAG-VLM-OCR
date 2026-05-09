#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BACKEND_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
ENV_FILE="${BACKEND_ROOT}/.env"
cd "$SCRIPT_DIR"

read_env_value() {
    local key="$1"
    local default_value="${2:-}"
    local current_value="${!key:-}"

    if [ -n "$current_value" ]; then
        printf '%s' "$current_value"
        return
    fi

    if [ ! -f "$ENV_FILE" ]; then
        printf '%s' "$default_value"
        return
    fi

    python3 - "$ENV_FILE" "$key" "$default_value" <<'PY'
import re
import sys

env_file, key, default_value = sys.argv[1:]
value = default_value
pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$")

with open(env_file, "r", encoding="utf-8") as fh:
    for raw_line in fh:
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = pattern.match(raw_line)
        if not match:
            continue
        parsed = match.group(1).strip()
        if (parsed.startswith('"') and parsed.endswith('"')) or (parsed.startswith("'") and parsed.endswith("'")):
            parsed = parsed[1:-1]
        value = parsed

print(value, end="")
PY
}

probe_http_status() {
    local url=$1
    local status=""

    if command -v curl >/dev/null 2>&1; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || true)
        if [ -n "$status" ]; then
            printf '%s' "$status"
            return 0
        fi
    fi

    "${PYTHON_CMD:-python3}" - "$url" <<'PY'
import sys
from urllib.request import urlopen
from urllib.error import HTTPError, URLError

url = sys.argv[1]
try:
    with urlopen(url, timeout=5) as response:
        print(response.status, end="")
except HTTPError as exc:
    print(exc.code, end="")
except URLError:
    pass
PY
}

wait_for_http_service() {
    local url=$1
    local pid=$2
    local attempts=${3:-30}

    local count=0
    while [ $count -lt $attempts ]; do
        local status
        status=$(probe_http_status "$url")
        if [ "$status" = "200" ]; then
            return 0
        fi

        if ! ps -p "$pid" >/dev/null 2>&1; then
            return 1
        fi

        sleep 1
        count=$((count + 1))
    done

    return 1
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🚀 启动 PaddleOCR-VL API 服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

VL_MODEL_DIR=$(read_env_value "PADDLEOCR_VL_MODEL_DIR" "/home/data/nongwa/workspace/model/02_OcrRag/PaddleOCR-VL-0.9B")
LAYOUT_MODEL_DIR=$(read_env_value "PADDLEOCR_LAYOUT_MODEL_DIR" "/home/data/nongwa/workspace/model/02_OcrRag/PP-DocLayoutV2")
GPU_ID=$(read_env_value "PADDLEOCR_VL_GPU_ID" "1")
PORT=$(read_env_value "PADDLEOCR_VL_API_PORT" "8802")
HOST=$(read_env_value "PADDLEOCR_VL_API_HOST" "0.0.0.0")
WORKERS=$(read_env_value "PADDLEOCR_VL_WORKERS" "1")
BACKGROUND_MODE=$(read_env_value "PADDLEOCR_VL_BACKGROUND" "true")
AUTO_KILL_PORT=$(read_env_value "PADDLEOCR_VL_AUTO_KILL_PORT" "true")

if [ -n "${CONDA_PREFIX:-}" ] && [ -x "${CONDA_PREFIX}/bin/python" ] && [ "${CONDA_DEFAULT_ENV:-base}" != "base" ]; then
    PYTHON_CMD="${CONDA_PREFIX}/bin/python"
    echo -e "${GREEN}✓ 使用当前激活的Conda虚拟环境: ${CONDA_DEFAULT_ENV}${NC}"
elif [ -x "/root/miniconda3/envs/vlm_rag310/bin/python" ]; then
    PYTHON_CMD="/root/miniconda3/envs/vlm_rag310/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag310${NC}"
elif [ -x "/root/anaconda3/envs/vlm_rag310/bin/python" ]; then
    PYTHON_CMD="/root/anaconda3/envs/vlm_rag310/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag310${NC}"
elif [ -x "/root/miniconda3/envs/vlm_rag/bin/python" ]; then
    PYTHON_CMD="/root/miniconda3/envs/vlm_rag/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag${NC}"
elif [ -x "/root/anaconda3/envs/vlm_rag/bin/python" ]; then
    PYTHON_CMD="/root/anaconda3/envs/vlm_rag/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag${NC}"
elif [ -x "/home/data/nongwa/miniconda3/envs/ocr_rag/bin/python" ]; then
    PYTHON_CMD="/home/data/nongwa/miniconda3/envs/ocr_rag/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: ocr_rag${NC}"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
    echo -e "${YELLOW}⚠️  使用系统Python${NC}"
else
    echo -e "${RED}❌ 错误: 未找到Python${NC}"
    exit 1
fi

if [ ! -d "$VL_MODEL_DIR" ]; then
    echo -e "${RED}❌ 错误: VL 模型路径不存在: $VL_MODEL_DIR${NC}"
    echo -e "${YELLOW}请在 backend/.env 中配置 PADDLEOCR_VL_MODEL_DIR${NC}"
    exit 1
fi

if [ ! -d "$LAYOUT_MODEL_DIR" ]; then
    echo -e "${RED}❌ 错误: 布局模型路径不存在: $LAYOUT_MODEL_DIR${NC}"
    echo -e "${YELLOW}请在 backend/.env 中配置 PADDLEOCR_LAYOUT_MODEL_DIR${NC}"
    exit 1
fi

echo -e "${GREEN}✓ VL模型路径: $VL_MODEL_DIR${NC}"
echo -e "${GREEN}✓ 布局模型路径: $LAYOUT_MODEL_DIR${NC}"

echo -e "\n${YELLOW}检查依赖包...${NC}"
for pkg in paddleocr fastapi uvicorn PIL html2text; do
    if "$PYTHON_CMD" -c "import ${pkg}" 2>/dev/null; then
        echo -e "${GREEN}  ✓ ${pkg}${NC}"
    else
        echo -e "${RED}  ❌ ${pkg} 未安装${NC}"
        exit 1
    fi
done

if lsof -Pi :"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    OCCUPIED_PID=$(lsof -Pi :"${PORT}" -sTCP:LISTEN -t | head -n 1)
    if [ "${AUTO_KILL_PORT,,}" = "true" ]; then
        echo -e "${YELLOW}⚠️  端口 ${PORT} 已被占用，自动清理 PID ${OCCUPIED_PID}${NC}"
        kill "${OCCUPIED_PID}" 2>/dev/null || true
        sleep 2
    else
        echo -e "${RED}❌ 端口 ${PORT} 已被占用，请先手动清理${NC}"
        exit 1
    fi
fi

mkdir -p "${BACKEND_ROOT}/logs" "${BACKEND_ROOT}/pids"
LOG_FILE="${BACKEND_ROOT}/logs/paddleocr_vl.log"
PID_FILE="${BACKEND_ROOT}/pids/paddleocr_vl.pid"

export PADDLEOCR_VL_MODEL_DIR="$VL_MODEL_DIR"
export PADDLEOCR_LAYOUT_MODEL_DIR="$LAYOUT_MODEL_DIR"
export PADDLEOCR_VL_GPU_ID="$GPU_ID"
export PADDLEOCR_VL_API_PORT="$PORT"
export PADDLEOCR_VL_API_HOST="$HOST"
export CUDA_VISIBLE_DEVICES="$GPU_ID"

CMD=("$PYTHON_CMD" "-m" "uvicorn" "api_paddleocr_vl_mineru:app" "--host" "$HOST" "--port" "$PORT" "--workers" "$WORKERS")

echo -e "${BLUE}启动命令:${NC}"
printf '%s ' "${CMD[@]}"
printf '\n\n'

if [ "${BACKGROUND_MODE,,}" = "true" ]; then
    echo -e "${GREEN}🚀 以后台模式启动 PaddleOCR-VL 服务...${NC}"
    if command -v setsid >/dev/null 2>&1; then
        setsid "${CMD[@]}" > "$LOG_FILE" 2>&1 < /dev/null &
    else
        nohup "${CMD[@]}" > "$LOG_FILE" 2>&1 < /dev/null &
    fi
    pid=$!
    echo "$pid" > "$PID_FILE"

    if wait_for_http_service "http://localhost:${PORT}/health" "$pid" 60; then
        echo -e "${GREEN}✓ PaddleOCR-VL 服务已启动 (PID: ${pid})${NC}"
        echo -e "${BLUE}  健康检查: http://localhost:${PORT}/health${NC}"
        echo -e "${BLUE}  日志: ${LOG_FILE}${NC}"
        exit 0
    fi

    echo -e "${RED}❌ PaddleOCR-VL 服务启动失败，请查看日志: ${LOG_FILE}${NC}"
    rm -f "$PID_FILE"
    exit 1
fi

echo -e "${GREEN}🚀 前台启动 PaddleOCR-VL 服务...${NC}"
"${CMD[@]}"
