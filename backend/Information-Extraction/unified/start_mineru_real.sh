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

parse_url_field() {
    local raw_url=$1
    local field=$2

    python3 - "$raw_url" "$field" <<'PY'
import sys
from urllib.parse import urlparse

raw_url, field = sys.argv[1:]
parsed = urlparse(raw_url)

if field == "host":
    print(parsed.hostname or "", end="")
elif field == "port":
    port = parsed.port
    if port is None:
        port = 443 if parsed.scheme == "https" else 80
    print(port, end="")
elif field == "base":
    scheme = parsed.scheme or "http"
    host = parsed.hostname or ""
    port = parsed.port
    if port is None:
        print(f"{scheme}://{host}", end="")
    else:
        print(f"{scheme}://{host}:{port}", end="")
PY
}

is_local_host() {
    local host=$1
    [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ] || [ "$host" = "0.0.0.0" ]
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

    python3 - "$url" <<'PY'
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
    local attempts=${2:-60}

    local count=0
    while [ $count -lt $attempts ]; do
        local status
        status=$(probe_http_status "$url")
        if [ "$status" = "200" ]; then
            return 0
        fi
        sleep 2
        count=$((count + 1))
    done

    return 1
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

docker_image_exists() {
    local image_name=$1
    docker image inspect "$image_name" >/dev/null 2>&1
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🚀 启动真实 MinerU 服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

MINERU_REAL_DOCKER_DIR=$(read_env_value "MINERU_REAL_DOCKER_DIR" "/root/Agent-Project-Collection/cases/3_RAG—OCR/Multimodal_RAG_OCR/minerU/MinerU_2_5_4/docker")
MINERU_REAL_COMPOSE_FILE=$(read_env_value "MINERU_REAL_COMPOSE_FILE" "compose.yaml")
MINERU_REAL_ENABLE_API=$(read_env_value "MINERU_REAL_ENABLE_API" "true")
MINERU_REAL_ENABLE_VLLM_SERVER=$(read_env_value "MINERU_REAL_ENABLE_VLLM_SERVER" "false")
MINERU_REAL_ENABLE_GRADIO=$(read_env_value "MINERU_REAL_ENABLE_GRADIO" "false")
MINERU_REAL_GRADIO_PORT=$(read_env_value "MINERU_REAL_GRADIO_PORT" "7860")
MINERU_REAL_IMAGE_NAME=$(read_env_value "MINERU_REAL_IMAGE_NAME" "mineru-vllm:2.5.4")
MINERU_REAL_BASE_IMAGE=$(read_env_value "MINERU_REAL_BASE_IMAGE" "docker.io/vllm/vllm-openai:v0.10.1.1")
MINERU_REAL_BASE_IMAGE_CANDIDATES=$(read_env_value "MINERU_REAL_BASE_IMAGE_CANDIDATES" "docker.1ms.run/vllm/vllm-openai:v0.10.1.1,docker.m.daocloud.io/vllm/vllm-openai:v0.10.1.1,docker.m.daocloud.io/vllm/vllm-openai:v0.10.2,docker.io/vllm/vllm-openai:v0.10.1.1")
MINERU_REAL_PIP_INDEX_URL=$(read_env_value "MINERU_REAL_PIP_INDEX_URL" "https://mirrors.aliyun.com/pypi/simple")
MINERU_REAL_SKIP_MODELS_DOWNLOAD=$(read_env_value "MINERU_REAL_SKIP_MODELS_DOWNLOAD" "true")
MINERU_REAL_PULL_TIMEOUT=$(read_env_value "MINERU_REAL_PULL_TIMEOUT" "600")
MINERU_REAL_AUTO_BUILD=$(read_env_value "MINERU_REAL_AUTO_BUILD" "false")
MINERU_API_URL=$(read_env_value "MINERU_API_URL" "http://localhost:10010/file_parse")
VLLM_SERVER_URL=$(read_env_value "VLLM_SERVER_URL" "http://localhost:30000")
MINERU_BACKEND=$(read_env_value "MINERU_BACKEND" "pipeline")

API_HOST=$(parse_url_field "$MINERU_API_URL" host)
API_PORT=$(parse_url_field "$MINERU_API_URL" port)
API_BASE_URL=$(parse_url_field "$MINERU_API_URL" base)
VLLM_HOST=$(parse_url_field "$VLLM_SERVER_URL" host)
VLLM_PORT=$(parse_url_field "$VLLM_SERVER_URL" port)

if ! is_local_host "$API_HOST"; then
    echo -e "${RED}❌ 错误: MINERU_API_URL 指向非本机地址: ${MINERU_API_URL}${NC}"
    echo -e "${YELLOW}真实 MinerU 本地启动脚本仅支持本机端口映射。${NC}"
    exit 1
fi

if [ "${MINERU_BACKEND}" = "vlm-http-client" ] && [ "${MINERU_REAL_ENABLE_VLLM_SERVER,,}" != "true" ]; then
    echo -e "${YELLOW}⚠️  MINERU_BACKEND=vlm-http-client，自动启用 vLLM server profile${NC}"
    MINERU_REAL_ENABLE_VLLM_SERVER=true
fi

if [ ! -d "$MINERU_REAL_DOCKER_DIR" ]; then
    echo -e "${RED}❌ 错误: MinerU docker 目录不存在: $MINERU_REAL_DOCKER_DIR${NC}"
    echo -e "${YELLOW}请在 backend/.env 中配置 MINERU_REAL_DOCKER_DIR${NC}"
    exit 1
fi

COMPOSE_PATH="${MINERU_REAL_DOCKER_DIR}/${MINERU_REAL_COMPOSE_FILE}"
if [ ! -f "$COMPOSE_PATH" ]; then
    echo -e "${RED}❌ 错误: Compose 文件不存在: $COMPOSE_PATH${NC}"
    exit 1
fi

if [ ! -d "${MINERU_REAL_DOCKER_DIR}/models" ]; then
    echo -e "${RED}❌ 错误: MinerU 本地模型目录不存在: ${MINERU_REAL_DOCKER_DIR}/models${NC}"
    exit 1
fi

COMPOSE_CMD=$(detect_compose_cmd || true)
if [ -z "$COMPOSE_CMD" ]; then
    echo -e "${RED}❌ 错误: 未找到 docker compose 或 docker-compose${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Compose 目录: ${MINERU_REAL_DOCKER_DIR}${NC}"
echo -e "${GREEN}✓ API URL: ${MINERU_API_URL}${NC}"
echo -e "${GREEN}✓ VLLM URL: ${VLLM_SERVER_URL}${NC}"
echo -e "${GREEN}✓ 目标镜像: ${MINERU_REAL_IMAGE_NAME}${NC}"
echo -e "${GREEN}✓ 基础镜像源: ${MINERU_REAL_BASE_IMAGE}${NC}"
echo -e "${GREEN}✓ 基础镜像候选: ${MINERU_REAL_BASE_IMAGE_CANDIDATES}${NC}"
echo -e "${GREEN}✓ PIP 源: ${MINERU_REAL_PIP_INDEX_URL}${NC}"
echo -e "${GREEN}✓ 构建时跳过模型下载: ${MINERU_REAL_SKIP_MODELS_DOWNLOAD}${NC}"
echo -e "${GREEN}✓ 单次拉取超时: ${MINERU_REAL_PULL_TIMEOUT}s${NC}"

if ! docker_image_exists "${MINERU_REAL_IMAGE_NAME}"; then
    if [ "${MINERU_REAL_AUTO_BUILD,,}" = "true" ]; then
        echo -e "${YELLOW}⚠️  本地镜像缺失，开始自动构建: ${MINERU_REAL_IMAGE_NAME}${NC}"
        MINERU_REAL_DOCKER_DIR="${MINERU_REAL_DOCKER_DIR}" \
        MINERU_REAL_IMAGE_NAME="${MINERU_REAL_IMAGE_NAME}" \
        MINERU_REAL_BASE_IMAGE="${MINERU_REAL_BASE_IMAGE}" \
        MINERU_REAL_BASE_IMAGE_CANDIDATES="${MINERU_REAL_BASE_IMAGE_CANDIDATES}" \
        MINERU_REAL_PIP_INDEX_URL="${MINERU_REAL_PIP_INDEX_URL}" \
        MINERU_REAL_SKIP_MODELS_DOWNLOAD="${MINERU_REAL_SKIP_MODELS_DOWNLOAD}" \
        MINERU_REAL_PULL_TIMEOUT="${MINERU_REAL_PULL_TIMEOUT}" \
        "${SCRIPT_DIR}/build_mineru_real_image.sh"
    else
        echo -e "${RED}❌ 本地镜像不存在: ${MINERU_REAL_IMAGE_NAME}${NC}"
        echo -e "${YELLOW}请先执行以下命令构建镜像，或在 backend/.env 中设置 MINERU_REAL_AUTO_BUILD=true${NC}"
        echo -e "${BLUE}  cd ${MINERU_REAL_DOCKER_DIR}${NC}"
        echo -e "${BLUE}  ./build_mineru_real_image.sh${NC}"
        echo -e "${YELLOW}当前会按 MINERU_REAL_BASE_IMAGE_CANDIDATES 顺序自动尝试多个基础镜像源。${NC}"
        exit 1
    fi
fi

PROFILES=()
if [ "${MINERU_REAL_ENABLE_VLLM_SERVER,,}" = "true" ]; then
    PROFILES+=("--profile" "vllm-server")
fi
if [ "${MINERU_REAL_ENABLE_API,,}" = "true" ]; then
    PROFILES+=("--profile" "api")
fi
if [ "${MINERU_REAL_ENABLE_GRADIO,,}" = "true" ]; then
    PROFILES+=("--profile" "gradio")
fi

if [ ${#PROFILES[@]} -eq 0 ]; then
    echo -e "${RED}❌ 错误: 没有启用任何 MinerU profile${NC}"
    exit 1
fi

OVERRIDE_FILE="${BACKEND_ROOT}/pids/mineru_real.compose.override.yaml"
mkdir -p "${BACKEND_ROOT}/pids"
cat > "$OVERRIDE_FILE" <<EOF
services:
  mineru-api:
    ports:
      - "${API_PORT}:8000"
  mineru-vllm-server:
    ports:
      - "${VLLM_PORT}:30000"
  mineru-gradio:
    ports:
      - "${MINERU_REAL_GRADIO_PORT}:7860"
EOF

echo -e "${BLUE}启动命令:${NC}"
echo -e "${YELLOW}${COMPOSE_CMD} -f ${COMPOSE_PATH} -f ${OVERRIDE_FILE} ${PROFILES[*]} up -d${NC}\n"

pushd "$MINERU_REAL_DOCKER_DIR" >/dev/null
run_compose "$COMPOSE_CMD" -f "$COMPOSE_PATH" -f "$OVERRIDE_FILE" "${PROFILES[@]}" up -d
popd >/dev/null

if [ "${MINERU_REAL_ENABLE_API,,}" = "true" ]; then
    if wait_for_http_service "${API_BASE_URL}/docs" 60; then
        echo -e "${GREEN}✓ MinerU API 已就绪: ${API_BASE_URL}${NC}"
    else
        echo -e "${YELLOW}⚠️  MinerU API 尚未通过 /docs 检查: ${API_BASE_URL}${NC}"
    fi
fi

if [ "${MINERU_REAL_ENABLE_VLLM_SERVER,,}" = "true" ]; then
    if wait_for_http_service "${VLLM_SERVER_URL}/health" 60; then
        echo -e "${GREEN}✓ MinerU vLLM 已就绪: ${VLLM_SERVER_URL}${NC}"
    else
        echo -e "${YELLOW}⚠️  MinerU vLLM 尚未通过 /health 检查: ${VLLM_SERVER_URL}${NC}"
    fi
fi

echo "$MINERU_REAL_DOCKER_DIR" > "${BACKEND_ROOT}/pids/mineru_real.compose_dir"
echo -e "${GREEN}✓ 真实 MinerU 启动流程已完成${NC}"
