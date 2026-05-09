#!/bin/bash

# RAG系统 - 停止所有服务脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 获取脚本所在目录
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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🛑 停止多模态RAG系统所有服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 函数: 停止服务
stop_service() {
    local service_name=$1
    local pid_file="pids/${service_name}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        
        # 检查进程是否存在
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${YELLOW}停止 ${service_name} (PID: $pid)...${NC}"
            kill $pid 2>/dev/null || true
            
            # 等待进程结束
            local count=0
            while ps -p $pid > /dev/null 2>&1 && [ $count -lt 10 ]; do
                sleep 1
                count=$((count + 1))
            done
            
            # 如果还没结束，强制杀死
            if ps -p $pid > /dev/null 2>&1; then
                echo -e "${YELLOW}  强制停止 ${service_name}...${NC}"
                kill -9 $pid 2>/dev/null || true
            fi
            
            echo -e "${GREEN}  ✓ ${service_name} 已停止${NC}"
        else
            echo -e "${YELLOW}  ⚠️  ${service_name} 进程不存在 (PID: $pid)${NC}"
        fi
        
        rm -f "$pid_file"
    else
        echo -e "${YELLOW}  ⚠️  ${service_name} 未找到PID文件${NC}"
    fi
}

# 按相反顺序停止服务（先停止依赖较多的）
stop_service "chat"
stop_service "milvus_api"
stop_service "chunker"
stop_service "pdf_extraction"
stop_service "deepseek_ocr"
stop_service "paddleocr_vl"
stop_service "mock_mineru"

ENABLE_REAL_MINERU=$(read_env_value "ENABLE_REAL_MINERU" "${ENABLE_REAL_MINERU:-false}")
ENABLE_PADDLEOCR_VL=$(read_env_value "ENABLE_PADDLEOCR_VL" "${ENABLE_PADDLEOCR_VL:-false}")
ENABLE_DEEPSEEK_OCR=$(read_env_value "ENABLE_DEEPSEEK_OCR" "${ENABLE_DEEPSEEK_OCR:-false}")
if [ "${ENABLE_REAL_MINERU,,}" = "true" ] || [ -f "${SCRIPT_DIR}/pids/mineru_real.compose_dir" ]; then
    echo -e "${YELLOW}停止真实 MinerU sidecar...${NC}"
    (
        cd "${SCRIPT_DIR}/Information-Extraction/unified"
        ./stop_mineru_real.sh
    ) || true
fi

if [ "${ENABLE_PADDLEOCR_VL,,}" = "true" ] || [ -f "${SCRIPT_DIR}/pids/paddleocr_vl.pid" ]; then
    echo -e "${YELLOW}停止 PaddleOCR-VL sidecar...${NC}"
    (
        cd "${SCRIPT_DIR}/Information-Extraction/paddleocr"
        ./stop_paddleocr_vl.sh
    ) || true
fi

if [ "${ENABLE_DEEPSEEK_OCR,,}" = "true" ] || [ -f "${SCRIPT_DIR}/pids/deepseek_ocr.pid" ]; then
    echo -e "${YELLOW}停止 DeepSeek OCR sidecar...${NC}"
    (
        cd "${SCRIPT_DIR}/Information-Extraction/deepseekocr"
        ./stop_deepseek_ocr.sh
    ) || true
fi

# 清理可能遗留的进程
echo -e "\n${YELLOW}清理可能遗留的服务进程...${NC}"

# 查找并停止可能的遗留进程
pkill -f "unified_pdf_extraction_service.py" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 PDF提取服务${NC}" || true
pkill -f "markdown_chunker_api.py" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 文本切分服务${NC}" || true
pkill -f "milvus_api.py" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 向量数据库服务${NC}" || true
pkill -f "kb_chat.py" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 对话检索服务${NC}" || true
pkill -f "mock_mineru_api.py" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 mock MinerU sidecar${NC}" || true
pkill -f "uvicorn api_paddleocr_vl_mineru:app" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 PaddleOCR-VL sidecar${NC}" || true
pkill -f "api_server_mineru_format.py" 2>/dev/null && echo -e "${GREEN}  ✓ 清理 DeepSeek OCR sidecar${NC}" || true

echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ 所有服务已停止${NC}"
echo -e "${BLUE}========================================${NC}\n"

echo -e "${YELLOW}提示:${NC}"
echo -e "  日志文件保存在 ${GREEN}logs/${NC} 目录"
echo -e "  重新启动服务: ${GREEN}./start_all_services.sh${NC}\n"
