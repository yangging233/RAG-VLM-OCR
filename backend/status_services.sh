#!/bin/bash

# RAG系统 - 查看所有服务状态脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

read_env_value() {
    local key="$1"
    local default_value="${2:-}"
    local env_file="${SCRIPT_DIR}/.env"
    local current_value="${!key:-}"

    if [ -n "$current_value" ]; then
        printf '%s' "$current_value"
        return
    fi

    if [ ! -f "$env_file" ]; then
        printf '%s' "$default_value"
        return
    fi

    python3 - "$env_file" "$key" "$default_value" <<'PY'
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

    if command -v curl &> /dev/null; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || true)
        if [ -n "$status" ] && [ "$status" != "000" ]; then
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

check_tcp_service() {
    local host=$1
    local port=$2
    python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=3):
        pass
except OSError:
    raise SystemExit(1)
PY
}

is_local_host() {
    local host=$1
    [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ] || [ "$host" = "0.0.0.0" ]
}

check_milvus_via_docker() {
    local expected_port=$1
    local docker_output=""

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    docker_output=$(docker ps --format '{{.Names}}|{{.Status}}|{{.Ports}}' 2>/dev/null || true)
    if [ -z "$docker_output" ]; then
        return 1
    fi

    while IFS='|' read -r name status ports; do
        [ "$name" = "milvus-standalone" ] || continue

        if [[ "$status" == *"(healthy)"* ]] || [[ "$status" == Up* ]]; then
            return 0
        fi
    done <<< "$docker_output"

    return 1
}

get_docker_ps_output() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    docker ps --format '{{.Names}}|{{.Status}}|{{.Ports}}' 2>/dev/null || true
}

find_docker_container_status() {
    local container_name=$1
    local docker_output=$2

    while IFS='|' read -r name status ports; do
        [ "$name" = "$container_name" ] || continue
        printf '%s|%s' "$status" "$ports"
        return 0
    done <<< "$docker_output"

    return 1
}

check_http_service() {
    local url=$1
    local expected_status=${2:-200}
    local status
    status=$(probe_http_status "$url")
    [ "$status" = "$expected_status" ]
}

check_sidecar_service() {
    local sidecar_name=$1
    local api_url=$2
    local health_path=${3:-/health}

    local base_url
    local host
    local port
    base_url=$(parse_url_field "$api_url" base)
    host=$(parse_url_field "$api_url" host)
    port=$(parse_url_field "$api_url" port)

    if [ -n "$health_path" ] && check_http_service "${base_url}${health_path}" "200"; then
        echo "healthy"
        return 0
    fi

    if [ "$sidecar_name" = "mineru" ] && check_http_service "${base_url}/" "200"; then
        echo "healthy"
        return 0
    fi

    if check_tcp_service "$host" "$port"; then
        echo "tcp-only"
        return 0
    fi

    echo "unavailable"
    return 1
}

print_service_status() {
    local service_name=$1
    local port=$2
    local health_url=$3
    local pid_file="pids/${service_name}.pid"
    local log_file="logs/${service_name}.log"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}服务: ${service_name}${NC}"

    local pid=""
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        echo -e "  PID文件: ${pid_file}"
        echo -e "  PID: ${pid}"
    else
        echo -e "  PID文件: 未找到"
    fi

    if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
        echo -e "${GREEN}  进程: 运行中${NC}"
        local cpu_mem
        cpu_mem=$(ps -p "$pid" -o %cpu,%mem --no-headers)
        echo -e "  资源: CPU $(echo "$cpu_mem" | awk '{print $1}')% / MEM $(echo "$cpu_mem" | awk '{print $2}')%"
    elif lsof -Pi :"${port}" -sTCP:LISTEN -t >/dev/null 2>&1; then
        local manual_pid
        manual_pid=$(lsof -Pi :"${port}" -sTCP:LISTEN -t | head -n 1)
        echo -e "${YELLOW}  进程: 手动启动 (PID ${manual_pid})${NC}"
    else
        echo -e "${RED}  进程: 未运行${NC}"
    fi

    if lsof -Pi :"${port}" -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${GREEN}  端口: ${port} (监听中)${NC}"
    else
        echo -e "${RED}  端口: ${port} (未监听)${NC}"
    fi

    local status
    status=$(probe_http_status "$health_url")
    if [ "$status" = "200" ]; then
        echo -e "${GREEN}  健康: HTTP 200 (${health_url})${NC}"
    else
        echo -e "${YELLOW}  健康: HTTP ${status:-N/A} (${health_url})${NC}"
    fi

    if [ -f "$log_file" ]; then
        local log_time
        log_time=$(stat -c %y "$log_file" 2>/dev/null | cut -d'.' -f1)
        echo -e "  日志: ${log_file}"
        echo -e "  更新: ${log_time}"
    fi
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}📊 多模态RAG系统服务状态${NC}"
echo -e "${BLUE}========================================${NC}\n"

MILVUS_HOST=$(read_env_value "MILVUS_HOST" "localhost")
MILVUS_PORT=$(read_env_value "MILVUS_PORT" "19530")
ENABLE_MOCK_MINERU=$(read_env_value "ENABLE_MOCK_MINERU" "false")
ENABLE_REAL_MINERU=$(read_env_value "ENABLE_REAL_MINERU" "false")
ENABLE_PADDLEOCR_VL=$(read_env_value "ENABLE_PADDLEOCR_VL" "false")
ENABLE_DEEPSEEK_OCR=$(read_env_value "ENABLE_DEEPSEEK_OCR" "false")

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}依赖: Milvus${NC}"
if check_tcp_service "$MILVUS_HOST" "$MILVUS_PORT"; then
    echo -e "${GREEN}  状态: TCP 可达 (${MILVUS_HOST}:${MILVUS_PORT})${NC}"
elif is_local_host "$MILVUS_HOST" && check_milvus_via_docker "$MILVUS_PORT"; then
    echo -e "${YELLOW}  状态: TCP 探测受限，但 docker ps 显示 milvus-standalone 正常 (${MILVUS_HOST}:${MILVUS_PORT})${NC}"
else
    echo -e "${RED}  状态: TCP 不可达 (${MILVUS_HOST}:${MILVUS_PORT})${NC}"
fi
echo ""

print_service_status "pdf_extraction" "8006" "http://localhost:8006/health"
print_service_status "chunker" "8001" "http://localhost:8001/health"
print_service_status "milvus_api" "8000" "http://localhost:8000/health"
print_service_status "chat" "8501" "http://localhost:8501/health"

if [ "${ENABLE_PADDLEOCR_VL,,}" = "true" ] || [ -f "pids/paddleocr_vl.pid" ]; then
    print_service_status "paddleocr_vl" "8802" "http://localhost:8802/health"
fi

if [ "${ENABLE_DEEPSEEK_OCR,,}" = "true" ] || [ -f "pids/deepseek_ocr.pid" ]; then
    print_service_status "deepseek_ocr" "8705" "http://localhost:8705/health"
fi

if [ "${ENABLE_MOCK_MINERU,,}" = "true" ] || [ -f "pids/mock_mineru.pid" ]; then
    print_service_status "mock_mineru" "10010" "http://localhost:10010/"
fi

if [ "${ENABLE_REAL_MINERU,,}" = "true" ] || [ -f "pids/mineru_real.compose_dir" ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}MinerU (real) Docker${NC}"

    MINERU_REAL_ENABLE_API=$(read_env_value "MINERU_REAL_ENABLE_API" "true")
    MINERU_REAL_ENABLE_VLLM_SERVER=$(read_env_value "MINERU_REAL_ENABLE_VLLM_SERVER" "false")
    MINERU_REAL_ENABLE_GRADIO=$(read_env_value "MINERU_REAL_ENABLE_GRADIO" "false")
    MINERU_REAL_GRADIO_PORT=$(read_env_value "MINERU_REAL_GRADIO_PORT" "7860")
    MINERU_API_URL=$(read_env_value "MINERU_API_URL" "http://localhost:10010/file_parse")
    VLLM_SERVER_URL=$(read_env_value "VLLM_SERVER_URL" "http://localhost:30000")
    DOCKER_OUTPUT=$(get_docker_ps_output)

    print_mineru_container() {
        local enabled=$1
        local container_name=$2
        local label=$3
        local url_hint=$4

        if [ "${enabled,,}" != "true" ]; then
            return 0
        fi

        local status_line
        status_line=$(find_docker_container_status "$container_name" "$DOCKER_OUTPUT" || true)
        if [ -n "$status_line" ]; then
            local status=${status_line%%|*}
            local ports=${status_line#*|}
            echo -e "${GREEN}  ${label}: ${status}${NC}"
            if [ -n "$ports" ]; then
                echo -e "    端口: ${ports}"
            fi
            if [ -n "$url_hint" ]; then
                echo -e "    地址: ${url_hint}"
            fi
        else
            echo -e "${YELLOW}  ${label}: 容器未运行或当前无法读取 docker ps${NC}"
            if [ -n "$url_hint" ]; then
                echo -e "    预期地址: ${url_hint}"
            fi
        fi
    }

    print_mineru_container "$MINERU_REAL_ENABLE_API" "mineru-api" "MinerU API" "$MINERU_API_URL"
    print_mineru_container "$MINERU_REAL_ENABLE_VLLM_SERVER" "mineru-vllm-server" "MinerU vLLM" "$VLLM_SERVER_URL"
    print_mineru_container "$MINERU_REAL_ENABLE_GRADIO" "mineru-gradio" "MinerU Gradio" "http://localhost:${MINERU_REAL_GRADIO_PORT}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}OCR Sidecars${NC}"

for item in \
    "mineru|$(read_env_value "MINERU_API_URL" "http://localhost:10010/file_parse")|/health" \
    "paddleocr_vl|$(read_env_value "PADDLEOCR_VL_API_URL" "http://localhost:8802/parse")|/health" \
    "deepseek|$(read_env_value "DEEPSEEK_OCR_API_URL" "http://localhost:8705/v1/ocr/pdf")|/health"
do
    IFS='|' read -r sidecar_name sidecar_url sidecar_health <<< "$item"
    sidecar_status=$(check_sidecar_service "$sidecar_name" "$sidecar_url" "$sidecar_health")
    case "$sidecar_status" in
        healthy)
            echo -e "${GREEN}  ${sidecar_name}: OK (${sidecar_url})${NC}"
            ;;
        tcp-only)
            echo -e "${YELLOW}  ${sidecar_name}: TCP reachable, health unknown (${sidecar_url})${NC}"
            ;;
        *)
            echo -e "${RED}  ${sidecar_name}: unavailable (${sidecar_url})${NC}"
            ;;
    esac
done

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

running_count=0
total_count=4

for service in pdf_extraction chunker milvus_api chat; do
    pid_file="pids/${service}.pid"
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            running_count=$((running_count + 1))
        fi
    elif lsof -Pi :"$(case "$service" in
        pdf_extraction) echo 8006 ;;
        chunker) echo 8001 ;;
        milvus_api) echo 8000 ;;
        chat) echo 8501 ;;
    esac)" -sTCP:LISTEN -t >/dev/null 2>&1; then
        running_count=$((running_count + 1))
    fi
done

echo -e "${BLUE}总计: ${running_count}/${total_count} 个核心服务运行中${NC}\n"

echo -e "${YELLOW}常用命令:${NC}"
echo -e "  启动所有服务: ${GREEN}./start_all_services.sh${NC}"
echo -e "  停止所有服务: ${GREEN}./stop_all_services.sh${NC}"
echo -e "  健康检查: ${GREEN}./test_services.sh${NC}"
echo -e "  查看实时日志: ${GREEN}tail -f logs/*.log${NC}"
echo -e "  重启所有服务: ${GREEN}./stop_all_services.sh && ./start_all_services.sh${NC}\n"

echo -e "${BLUE}========================================${NC}\n"
