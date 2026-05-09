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

detect_compose_cmd() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
        return 0
    fi

    return 1
}

run_compose() {
    local compose_cmd="$1"
    shift

    if [ "$compose_cmd" = "docker compose" ]; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🛑 停止真实 MinerU 服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

MINERU_REAL_DOCKER_DIR=$(read_env_value "MINERU_REAL_DOCKER_DIR" "/root/Agent-Project-Collection/cases/3_RAG—OCR/Multimodal_RAG_OCR/minerU/MinerU_2_5_4/docker")
MINERU_REAL_COMPOSE_FILE=$(read_env_value "MINERU_REAL_COMPOSE_FILE" "compose.yaml")
OVERRIDE_FILE="${BACKEND_ROOT}/pids/mineru_real.compose.override.yaml"

if [ ! -d "$MINERU_REAL_DOCKER_DIR" ]; then
    echo -e "${YELLOW}⚠️  MinerU docker 目录不存在，跳过停止: ${MINERU_REAL_DOCKER_DIR}${NC}"
    exit 0
fi

COMPOSE_PATH="${MINERU_REAL_DOCKER_DIR}/${MINERU_REAL_COMPOSE_FILE}"
if [ ! -f "$COMPOSE_PATH" ]; then
    echo -e "${YELLOW}⚠️  Compose 文件不存在，跳过停止: ${COMPOSE_PATH}${NC}"
    exit 0
fi

COMPOSE_CMD=$(detect_compose_cmd || true)
if [ -z "$COMPOSE_CMD" ]; then
    echo -e "${YELLOW}⚠️  未找到 docker compose 或 docker-compose，跳过停止${NC}"
    exit 0
fi

pushd "$MINERU_REAL_DOCKER_DIR" >/dev/null
if [ -f "$OVERRIDE_FILE" ]; then
    run_compose "$COMPOSE_CMD" -f "$COMPOSE_PATH" -f "$OVERRIDE_FILE" down || true
else
    run_compose "$COMPOSE_CMD" -f "$COMPOSE_PATH" down || true
fi
popd >/dev/null

rm -f "$OVERRIDE_FILE" "${BACKEND_ROOT}/pids/mineru_real.compose_dir"
echo -e "${GREEN}✓ 真实 MinerU 停止流程已完成${NC}"
