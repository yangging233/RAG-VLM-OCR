#!/bin/bash

# RAG系统 - 测试所有服务是否正常运行

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}🧪 测试多模态RAG系统所有服务${NC}"
echo -e "${BLUE}========================================${NC}\n"

read_env_value() {
    local key="$1"
    local default_value="${2:-}"
    local env_file="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.env"

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

    local probe_python=""
    if command -v python3 &> /dev/null; then
        probe_python="python3"
    elif command -v python &> /dev/null; then
        probe_python="python"
    else
        return 1
    fi

    "$probe_python" - "$url" <<'PY'
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

# 函数: 测试服务健康检查
test_service() {
    local service_name=$1
    local url=$2
    
    echo -e "${YELLOW}测试 ${service_name}...${NC}"
    
    response=$(probe_http_status "$url")
    if [ "$response" == "200" ]; then
        echo -e "${GREEN}  ✓ ${service_name} 正常 (HTTP 200)${NC}"
        echo -e "    访问地址: $url"
        return 0
    fi

    echo -e "${RED}  ✗ ${service_name} 异常 (HTTP ${response:-N/A})${NC}"
    echo -e "    访问地址: $url"
    return 1
}

success_count=0
total_count=4
ENABLE_MOCK_MINERU=$(read_env_value "ENABLE_MOCK_MINERU" "${ENABLE_MOCK_MINERU:-false}")

# 测试各个服务
test_service "PDF提取服务" "http://localhost:8006/health" && success_count=$((success_count + 1))
echo ""

test_service "文本切分服务" "http://localhost:8001/health" && success_count=$((success_count + 1))
echo ""

test_service "向量数据库服务" "http://localhost:8000/health" && success_count=$((success_count + 1))
echo ""

test_service "对话检索服务" "http://localhost:8501/health" && success_count=$((success_count + 1))
echo ""

if [ "${ENABLE_MOCK_MINERU:-false}" = "true" ]; then
    echo -e "${YELLOW}测试 mock MinerU sidecar...${NC}"
    response=$(probe_http_status "http://localhost:10010/")
    if [ "$response" == "200" ]; then
        echo -e "${GREEN}  ✓ mock MinerU 正常 (HTTP 200)${NC}"
        echo -e "    访问地址: http://localhost:10010/"
    else
        echo -e "${YELLOW}  ⚠️  mock MinerU 未就绪 (HTTP ${response:-N/A})${NC}"
        echo -e "    访问地址: http://localhost:10010/"
    fi
    echo ""
fi

# 显示测试结果
echo -e "${BLUE}========================================${NC}"
if [ $success_count -eq $total_count ]; then
    echo -e "${GREEN}✅ 所有服务测试通过 (${success_count}/${total_count})${NC}"
else
    echo -e "${YELLOW}⚠️  部分服务测试失败 (${success_count}/${total_count})${NC}"
fi
echo -e "${BLUE}========================================${NC}\n"

# 提示查看API文档
echo -e "${YELLOW}API文档地址:${NC}"
echo -e "  PDF提取:     http://localhost:8006/docs"
echo -e "  文本切分:    http://localhost:8001/docs"
echo -e "  向量数据库:  http://localhost:8000/docs"
echo -e "  对话检索:    http://localhost:8501/docs"
echo ""

exit $((total_count - success_count))
