#!/bin/bash

# RAG系统 - 启动所有服务脚本
# 包含: PDF提取、文本切分、向量数据库、对话检索

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 读取 .env 中的单个键，兼容 `KEY = value` 写法
read_env_value() {
    local key="$1"
    local default_value="${2:-}"
    local env_file="${SCRIPT_DIR}/.env"

    if [ ! -f "$env_file" ]; then
        printf '%s' "$default_value"
        return
    fi

    "${PYTHON_CMD:-python3}" - "$env_file" "$key" "$default_value" <<'PY'
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

# 创建必要的目录
mkdir -p logs
mkdir -p pids

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🚀 启动多模态RAG系统所有服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 检查并优先使用Conda虚拟环境
if [ -n "${CONDA_PREFIX:-}" ] && [ -x "${CONDA_PREFIX}/bin/python" ] && [ "${CONDA_DEFAULT_ENV:-base}" != "base" ]; then
    PYTHON_CMD="${CONDA_PREFIX}/bin/python"
    echo -e "${GREEN}✓ 使用当前激活的Conda虚拟环境: ${CONDA_DEFAULT_ENV}${NC}"
elif [ -x "/root/miniconda3/envs/vlm_rag310/bin/python" ]; then
    PYTHON_CMD="/root/miniconda3/envs/vlm_rag310/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag310 (/root/miniconda3/envs/vlm_rag310)${NC}"
elif [ -x "/root/anaconda3/envs/vlm_rag310/bin/python" ]; then
    PYTHON_CMD="/root/anaconda3/envs/vlm_rag310/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag310 (/root/anaconda3/envs/vlm_rag310)${NC}"
elif [ -x "/root/miniconda3/envs/vlm_rag/bin/python" ]; then
    PYTHON_CMD="/root/miniconda3/envs/vlm_rag/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag (/root/miniconda3/envs/vlm_rag)${NC}"
elif [ -x "/root/anaconda3/envs/vlm_rag/bin/python" ]; then
    PYTHON_CMD="/root/anaconda3/envs/vlm_rag/bin/python"
    echo -e "${GREEN}✓ 使用Conda虚拟环境: vlm_rag (/root/anaconda3/envs/vlm_rag)${NC}"
elif command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
    echo -e "${YELLOW}⚠️  使用系统Python (可能缺少依赖)${NC}"
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
    echo -e "${YELLOW}⚠️  使用系统Python (可能缺少依赖)${NC}"
else
    echo -e "${RED}❌ 错误: 未找到Python${NC}"
    exit 1
fi

echo -e "${YELLOW}Python路径: $PYTHON_CMD${NC}\n"

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

    "$PYTHON_CMD" - "$url" <<'PY'
import sys
from urllib.request import urlopen
from urllib.error import URLError, HTTPError

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
    local service_name=$1
    local health_url=$2
    local pid=$3
    local attempts=${4:-30}

    local count=0
    while [ $count -lt $attempts ]; do
        local status
        status=$(probe_http_status "$health_url")
        if [ "$status" = "200" ]; then
            return 0
        fi

        if ! ps -p "$pid" > /dev/null 2>&1; then
            return 1
        fi

        sleep 1
        count=$((count + 1))
    done

    echo -e "${YELLOW}  ⚠️  ${service_name} 健康检查未通过: ${health_url}${NC}"
    return 1
}

parse_url_field() {
    local raw_url=$1
    local field=$2

    "$PYTHON_CMD" - "$raw_url" "$field" <<'PY'
import sys
from urllib.parse import urlparse

raw_url, field = sys.argv[1:]
parsed = urlparse(raw_url)

if field == "scheme":
    print(parsed.scheme or "http", end="")
elif field == "host":
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
elif field == "path":
    print(parsed.path or "/", end="")
PY
}

check_tcp_service() {
    local host=$1
    local port=$2

    "$PYTHON_CMD" - "$host" "$port" <<'PY'
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

ensure_milvus_dependency() {
    local milvus_host
    local milvus_port
    milvus_host=$(read_env_value "MILVUS_HOST" "${MILVUS_HOST:-localhost}")
    milvus_port=$(read_env_value "MILVUS_PORT" "${MILVUS_PORT:-19530}")

    echo -e "${YELLOW}检查 Milvus 依赖 (${milvus_host}:${milvus_port})...${NC}"
    if check_tcp_service "$milvus_host" "$milvus_port"; then
        echo -e "${GREEN}  ✓ Milvus TCP 可达${NC}\n"
        return 0
    fi

    if is_local_host "$milvus_host" && check_milvus_via_docker "$milvus_port"; then
        echo -e "${YELLOW}  ⚠️  普通 TCP 探测失败，但 docker ps 显示 milvus-standalone 已运行且端口已映射。${NC}"
        echo -e "${GREEN}  ✓ 采用 Docker 健康态作为回退依据，继续启动后续服务${NC}\n"
        return 0
    fi

    echo -e "${RED}  ❌ Milvus 不可达: ${milvus_host}:${milvus_port}${NC}"
    echo -e "${YELLOW}  当前无法启动 milvus_api 服务，请先恢复 Milvus。${NC}"

    local milvus_script="${SCRIPT_DIR}/Database/milvus_server/start_milvus.sh"
    local milvus_compose="${SCRIPT_DIR}/Database/milvus_server/docker-compose.yaml"

    if [ "$milvus_host" = "localhost" ] || [ "$milvus_host" = "127.0.0.1" ] || [ "$milvus_host" = "0.0.0.0" ]; then
        echo -e "${BLUE}  可执行命令:${NC}"
        echo -e "    cd ${SCRIPT_DIR}/Database/milvus_server"
        echo -e "    ./start_milvus.sh"
        echo -e "${BLUE}  相关文件:${NC}"
        echo -e "    启动脚本: ${milvus_script}"
        echo -e "    Compose:  ${milvus_compose}"
        echo -e "${BLUE}  启动后预期端口:${NC}"
        echo -e "    Milvus gRPC: 19530"
        echo -e "    Milvus health: http://localhost:9091/healthz"
        echo -e "    Attu UI: http://localhost:8080"
    else
        echo -e "${BLUE}  请检查远端 Milvus 是否已启动，并确认 .env 中的 MILVUS_HOST/MILVUS_PORT 正确。${NC}"
    fi

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

print_ocr_sidecar_summary() {
    local mineru_url paddle_url deepseek_url
    mineru_url=$(read_env_value "MINERU_API_URL" "${MINERU_API_URL:-http://localhost:10010/file_parse}")
    paddle_url=$(read_env_value "PADDLEOCR_VL_API_URL" "${PADDLEOCR_VL_API_URL:-http://localhost:8802/parse}")
    deepseek_url=$(read_env_value "DEEPSEEK_OCR_API_URL" "${DEEPSEEK_OCR_API_URL:-http://localhost:8705/v1/ocr/pdf}")

    echo -e "${YELLOW}OCR sidecar 状态摘要:${NC}"

    for item in \
        "mineru|${mineru_url}|/health" \
        "paddleocr_vl|${paddle_url}|/health" \
        "deepseek|${deepseek_url}|/health"
    do
        IFS='|' read -r sidecar_name sidecar_url sidecar_health <<< "$item"
        local status
        status=$(check_sidecar_service "$sidecar_name" "$sidecar_url" "$sidecar_health" || true)

        case "$status" in
            healthy)
                echo -e "${GREEN}  ✓ ${sidecar_name}: ${sidecar_url}${NC}"
                ;;
            tcp-only)
                echo -e "${YELLOW}  ⚠️  ${sidecar_name}: ${sidecar_url} (仅 TCP 可达，未确认健康端点)${NC}"
                ;;
            *)
                echo -e "${YELLOW}  ⚠️  ${sidecar_name}: ${sidecar_url} (当前不可达)${NC}"
                ;;
        esac
    done

    echo ""
}

start_optional_sidecar() {
    local enabled=$1
    local label=$2
    local workdir=$3
    local script_name=$4

    if [ "${enabled,,}" != "true" ]; then
        return 0
    fi

    echo -e "${YELLOW}启动可选 OCR sidecar: ${label}${NC}"
    (
        cd "$workdir"
        ./"$script_name"
    )
    echo ""
}

# 函数: 启动服务
start_service() {
    local service_name=$1
    local service_path=$2
    local service_file=$3
    local port=$4
    local health_url=$5
    local pid_file="pids/${service_name}.pid"
    local log_file="logs/${service_name}.log"
    
    echo -e "${YELLOW}启动 ${service_name} (端口 ${port})...${NC}"
    
    # 检查服务文件是否存在
    if [ ! -f "${service_path}/${service_file}" ]; then
        echo -e "${RED}  ❌ 错误: 文件不存在 ${service_path}/${service_file}${NC}"
        return 1
    fi
    
    # 检查端口是否被占用
    if lsof -Pi :${port} -sTCP:LISTEN -t >/dev/null 2>&1 ; then
        echo -e "${YELLOW}  ⚠️  端口 ${port} 已被占用，正在清理...${NC}"
        
        # 获取占用端口的进程PID
        local occupied_pid=$(lsof -Pi :${port} -sTCP:LISTEN -t)
        
        if [ -n "$occupied_pid" ]; then
            echo -e "${YELLOW}  正在停止占用端口的进程 (PID: $occupied_pid)...${NC}"
            
            # 尝试优雅停止
            kill $occupied_pid 2>/dev/null || true
            
            # 等待进程结束
            local count=0
            while ps -p $occupied_pid > /dev/null 2>&1 && [ $count -lt 5 ]; do
                sleep 1
                count=$((count + 1))
            done
            
            # 如果还没结束，强制杀死
            if ps -p $occupied_pid > /dev/null 2>&1; then
                echo -e "${YELLOW}  强制停止进程...${NC}"
                kill -9 $occupied_pid 2>/dev/null || true
                sleep 1
            fi
            
            echo -e "${GREEN}  ✓ 端口 ${port} 已清理${NC}"
        fi
    fi
    
    # 启动服务。当前运行环境下，普通 nohup 可能不会彻底脱离父会话；
    # 优先使用 setsid + stdin 重定向，确保服务在脚本退出后仍然驻留。
    cd "${service_path}"
    if command -v setsid >/dev/null 2>&1; then
        setsid $PYTHON_CMD "${service_file}" > "${SCRIPT_DIR}/${log_file}" 2>&1 < /dev/null &
    else
        nohup $PYTHON_CMD "${service_file}" > "${SCRIPT_DIR}/${log_file}" 2>&1 < /dev/null &
    fi
    local pid=$!
    
    # 保存PID
    echo $pid > "${SCRIPT_DIR}/${pid_file}"
    
    # 等待服务启动并通过健康检查
    if wait_for_http_service "$service_name" "$health_url" "$pid" 30; then
        echo -e "${GREEN}  ✓ ${service_name} 启动成功 (PID: $pid)${NC}"
        echo -e "${BLUE}    日志: logs/${service_name}.log${NC}"
        echo -e "${BLUE}    访问: http://localhost:${port}${NC}"
    else
        echo -e "${RED}  ❌ ${service_name} 启动失败，请查看日志: logs/${service_name}.log${NC}"
        rm -f "${SCRIPT_DIR}/${pid_file}"
        return 1
    fi
    
    cd "${SCRIPT_DIR}"
    echo ""
}

ENABLE_MOCK_MINERU=$(read_env_value "ENABLE_MOCK_MINERU" "${ENABLE_MOCK_MINERU:-false}")
ENABLE_REAL_MINERU=$(read_env_value "ENABLE_REAL_MINERU" "${ENABLE_REAL_MINERU:-false}")
ENABLE_PADDLEOCR_VL=$(read_env_value "ENABLE_PADDLEOCR_VL" "${ENABLE_PADDLEOCR_VL:-false}")
ENABLE_DEEPSEEK_OCR=$(read_env_value "ENABLE_DEEPSEEK_OCR" "${ENABLE_DEEPSEEK_OCR:-false}")

if [ "${ENABLE_MOCK_MINERU,,}" = "true" ] && [ "${ENABLE_REAL_MINERU,,}" = "true" ]; then
    echo -e "${RED}❌ 不能同时启用 ENABLE_MOCK_MINERU=true 和 ENABLE_REAL_MINERU=true${NC}"
    echo -e "${YELLOW}请在 mock 集成验证 与 真实 MinerU 之间二选一。${NC}"
    exit 1
fi

ensure_milvus_dependency

if [ "${ENABLE_REAL_MINERU,,}" = "true" ]; then
    start_optional_sidecar "${ENABLE_REAL_MINERU}" "MinerU(real)" "${SCRIPT_DIR}/Information-Extraction/unified" "start_mineru_real.sh"
elif [ "${ENABLE_MOCK_MINERU,,}" = "true" ]; then
    echo -e "${YELLOW}启动 mock MinerU sidecar (端口 10010)...${NC}"
    (
        cd "${SCRIPT_DIR}/Information-Extraction/unified"
        ./start_mock_mineru.sh
    )

    mock_pid_file="${SCRIPT_DIR}/pids/mock_mineru.pid"
    if [ -f "$mock_pid_file" ] && wait_for_http_service "mock_mineru" "http://localhost:10010/" "$(cat "$mock_pid_file")" 15; then
        echo -e "${GREEN}  ✓ mock MinerU 已启动${NC}\n"
    else
        echo -e "${RED}  ❌ mock MinerU 启动失败，请查看 logs/mock_mineru.log${NC}"
        exit 1
    fi
else
    echo -e "${BLUE}提示: 未启用 mock MinerU。若需 mock 联调，可在 .env 或命令行中设置 ENABLE_MOCK_MINERU=true${NC}\n"
fi

start_optional_sidecar "${ENABLE_PADDLEOCR_VL}" "PaddleOCR-VL" "${SCRIPT_DIR}/Information-Extraction/paddleocr" "start_paddleocr_vl.sh"
start_optional_sidecar "${ENABLE_DEEPSEEK_OCR}" "DeepSeek OCR" "${SCRIPT_DIR}/Information-Extraction/deepseekocr" "start_deepseek_ocr.sh"

print_ocr_sidecar_summary

# 1. 启动PDF提取服务
start_service "pdf_extraction" \
    "Information-Extraction/unified" \
    "unified_pdf_extraction_service.py" \
    "8006" \
    "http://localhost:8006/health"

# 2. 启动文本切分服务
start_service "chunker" \
    "Text_segmentation" \
    "markdown_chunker_api.py" \
    "8001" \
    "http://localhost:8001/health"

# 3. 启动向量数据库服务
start_service "milvus_api" \
    "Database/milvus_server" \
    "milvus_api.py" \
    "8000" \
    "http://localhost:8000/health"

# 4. 启动对话检索服务
start_service "chat" \
    "chat" \
    "kb_chat.py" \
    "8501" \
    "http://localhost:8501/health"

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✅ 所有服务启动完成！${NC}"
echo -e "${BLUE}========================================${NC}\n"

echo -e "${YELLOW}服务列表:${NC}"
echo -e "  📄 PDF提取服务:     http://localhost:8006"
echo -e "  ✂️  文本切分服务:     http://localhost:8001"
echo -e "  🗄️  向量数据库服务:   http://localhost:8000"
echo -e "  💬 对话检索服务:     http://localhost:8501"

echo -e "\n${YELLOW}常用命令:${NC}"
echo -e "  查看服务状态: ${GREEN}./status_services.sh${NC}"
echo -e "  查看所有日志: ${GREEN}tail -f logs/*.log${NC}"
echo -e "  查看单个日志: ${GREEN}tail -f logs/chat.log${NC}"
echo -e "  停止所有服务: ${GREEN}./stop_all_services.sh${NC}"

echo -e "\n${BLUE}========================================${NC}\n"
