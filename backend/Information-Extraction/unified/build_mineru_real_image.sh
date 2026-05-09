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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🏗️  构建真实 MinerU 镜像${NC}"
echo -e "${BLUE}========================================${NC}\n"

MINERU_REAL_DOCKER_DIR=$(read_env_value "MINERU_REAL_DOCKER_DIR" "/root/Agent-Project-Collection/cases/3_RAG—OCR/Multimodal_RAG_OCR/minerU/MinerU_2_5_4/docker")
MINERU_REAL_IMAGE_NAME=$(read_env_value "MINERU_REAL_IMAGE_NAME" "mineru-vllm:2.5.4")
MINERU_REAL_BASE_IMAGE=$(read_env_value "MINERU_REAL_BASE_IMAGE" "docker.io/vllm/vllm-openai:v0.10.1.1")
MINERU_REAL_BASE_IMAGE_CANDIDATES=$(read_env_value "MINERU_REAL_BASE_IMAGE_CANDIDATES" "docker.1ms.run/vllm/vllm-openai:v0.10.1.1,docker.m.daocloud.io/vllm/vllm-openai:v0.10.1.1,docker.m.daocloud.io/vllm/vllm-openai:v0.10.2,docker.io/vllm/vllm-openai:v0.10.1.1")
MINERU_REAL_PIP_INDEX_URL=$(read_env_value "MINERU_REAL_PIP_INDEX_URL" "https://mirrors.aliyun.com/pypi/simple")
MINERU_REAL_SKIP_MODELS_DOWNLOAD=$(read_env_value "MINERU_REAL_SKIP_MODELS_DOWNLOAD" "true")
MINERU_REAL_PULL_RETRIES=$(read_env_value "MINERU_REAL_PULL_RETRIES" "2")
MINERU_REAL_PULL_TIMEOUT=$(read_env_value "MINERU_REAL_PULL_TIMEOUT" "600")

try_pull_base_image() {
    local image=$1
    local retries=$2
    local timeout_seconds=$3
    local attempt=1

    while [ "$attempt" -le "$retries" ]; do
        echo -e "${YELLOW}尝试拉取基础镜像 (${attempt}/${retries}): ${image}${NC}"
        if command -v timeout >/dev/null 2>&1 && [ "${timeout_seconds}" -gt 0 ] 2>/dev/null; then
            timeout "${timeout_seconds}" docker pull "$image"
            pull_status=$?
        else
            docker pull "$image"
            pull_status=$?
        fi

        if [ "$pull_status" -eq 0 ]; then
            return 0
        fi

        if [ "$pull_status" -eq 124 ]; then
            echo -e "${YELLOW}  拉取超时 (${timeout_seconds}s)，准备切换或重试...${NC}"
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -le "$retries" ]; then
            echo -e "${YELLOW}  拉取失败，准备重试...${NC}"
            sleep 3
        fi
    done

    return 1
}

if [ ! -d "$MINERU_REAL_DOCKER_DIR" ]; then
    echo -e "${RED}❌ 错误: MinerU docker 目录不存在: ${MINERU_REAL_DOCKER_DIR}${NC}"
    exit 1
fi

if [ ! -f "${MINERU_REAL_DOCKER_DIR}/Dockerfile" ]; then
    echo -e "${RED}❌ 错误: Dockerfile 不存在: ${MINERU_REAL_DOCKER_DIR}/Dockerfile${NC}"
    exit 1
fi

pushd "$MINERU_REAL_DOCKER_DIR" >/dev/null
echo -e "${GREEN}✓ 构建目录: ${MINERU_REAL_DOCKER_DIR}${NC}"
echo -e "${GREEN}✓ 镜像名称: ${MINERU_REAL_IMAGE_NAME}${NC}\n"
echo -e "${GREEN}✓ 默认基础镜像: ${MINERU_REAL_BASE_IMAGE}${NC}"
echo -e "${GREEN}✓ 基础镜像候选: ${MINERU_REAL_BASE_IMAGE_CANDIDATES}${NC}\n"
echo -e "${GREEN}✓ PIP 源: ${MINERU_REAL_PIP_INDEX_URL}${NC}"
echo -e "${GREEN}✓ 构建时跳过模型下载: ${MINERU_REAL_SKIP_MODELS_DOWNLOAD}${NC}"
echo -e "${GREEN}✓ 单次拉取超时: ${MINERU_REAL_PULL_TIMEOUT}s${NC}\n"

chosen_base_image=""
candidates_csv="$MINERU_REAL_BASE_IMAGE_CANDIDATES"
if [[ ",${candidates_csv}," != *",${MINERU_REAL_BASE_IMAGE},"* ]]; then
    candidates_csv="${MINERU_REAL_BASE_IMAGE},${candidates_csv}"
fi

IFS=',' read -r -a candidate_images <<< "$candidates_csv"
for candidate in "${candidate_images[@]}"; do
    candidate_trimmed=$(echo "$candidate" | sed 's/^ *//;s/ *$//')
    [ -n "$candidate_trimmed" ] || continue
    if try_pull_base_image "$candidate_trimmed" "$MINERU_REAL_PULL_RETRIES" "$MINERU_REAL_PULL_TIMEOUT"; then
        chosen_base_image="$candidate_trimmed"
        break
    fi
done

if [ -z "$chosen_base_image" ]; then
    echo -e "\n${RED}❌ 未能从任何候选镜像源成功拉取基础镜像${NC}"
    echo -e "${YELLOW}已尝试候选:${NC}"
    for candidate in "${candidate_images[@]}"; do
        candidate_trimmed=$(echo "$candidate" | sed 's/^ *//;s/ *$//')
        [ -n "$candidate_trimmed" ] && echo -e "${BLUE}  - ${candidate_trimmed}${NC}"
    done
    exit 1
fi

echo -e "\n${GREEN}✓ 选定基础镜像: ${chosen_base_image}${NC}\n"

if ! docker build \
    --build-arg "VLLM_BASE_IMAGE=${chosen_base_image}" \
    --build-arg "MINERU_PIP_INDEX_URL=${MINERU_REAL_PIP_INDEX_URL}" \
    --build-arg "SKIP_MINERU_MODELS_DOWNLOAD=${MINERU_REAL_SKIP_MODELS_DOWNLOAD}" \
    -t "${MINERU_REAL_IMAGE_NAME}" \
    -f Dockerfile .; then
    echo -e "\n${RED}❌ MinerU 镜像构建失败${NC}"
    echo -e "${YELLOW}可在 backend/.env 中调整以下配置后重试:${NC}"
    echo -e "${BLUE}  MINERU_REAL_BASE_IMAGE=${chosen_base_image}${NC}"
    echo -e "${BLUE}  MINERU_REAL_BASE_IMAGE_CANDIDATES=docker.io/vllm/vllm-openai:v0.10.1.1,docker.m.daocloud.io/vllm/vllm-openai:v0.10.2${NC}"
    echo -e "${BLUE}  MINERU_REAL_SKIP_MODELS_DOWNLOAD=true${NC}"
    exit 1
fi
popd >/dev/null

echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ MinerU 镜像构建完成${NC}"
echo -e "${BLUE}========================================${NC}\n"
