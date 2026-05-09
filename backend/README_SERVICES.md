# 多模态RAG系统 - 服务管理指南

## 📋 服务列表

本系统包含4个微服务，提供完整的RAG功能：

| 服务名称 | 端口 | 功能描述 | 文件位置 |
|---------|------|---------|---------|
| PDF提取服务 | 8006 | PDF文档解析、图片提取 | `Information-Extraction/unified/unified_pdf_extraction_service.py` |
| 文本切分服务 | 8001 | Markdown文本智能切分 | `Text_segmentation/markdown_chunker_api.py` |
| 向量数据库服务 | 8000 | 文档向量化、Milvus存储与检索 | `Database/milvus_server/milvus_api.py` |
| 对话检索服务 | 8501 | RAG对话、重排序、LLM生成 | `chat/kb_chat.py` |

## 🚀 快速开始

### 1. 启动所有服务

```bash
cd /home/MuyuWorkSpace/01_TrafficProject/Multimodal_RAG/backend
./start_all_services.sh
```

### 2. 查看服务状态

```bash
./status_services.sh
```

### 3. 停止所有服务

```bash
./stop_all_services.sh
```

### 4. 运行 OCR V2 smoke test

```bash
python smoke_test_v2_pipeline.py --skip-chat
```

如果本机暂时没有真实 OCR sidecar，可先启用 mock：

```bash
ENABLE_MOCK_MINERU=true ./start_all_services.sh
python smoke_test_v2_pipeline.py --skip-chat
```

## 📊 服务访问地址

启动后可通过以下地址访问：

- **PDF提取服务**: http://localhost:8006
  - API文档: http://localhost:8006/docs
  
- **文本切分服务**: http://localhost:8001
  - API文档: http://localhost:8001/docs
  
- **向量数据库服务**: http://localhost:8000
  - API文档: http://localhost:8000/docs
  
- **对话检索服务**: http://localhost:8501
  - API文档: http://localhost:8501/docs

## 📝 日志管理

### 查看所有服务日志

```bash
tail -f logs/*.log
```

### 查看单个服务日志

```bash
# PDF提取服务
tail -f logs/pdf_extraction.log

# 文本切分服务
tail -f logs/chunker.log

# 向量数据库服务
tail -f logs/milvus_api.log

# 对话检索服务
tail -f logs/chat.log
```

### 清空日志

```bash
rm -rf logs/*.log
```

## 🔧 常用操作

### 重启所有服务

```bash
./stop_all_services.sh && ./start_all_services.sh
```

### 单独重启某个服务

```bash
# 1. 查看服务PID
cat pids/chat.pid

# 2. 停止该服务
kill $(cat pids/chat.pid)

# 3. 手动启动
cd chat
python kb_chat.py
```

### 检查端口占用

```bash
# 检查所有服务端口
lsof -i :8006  # PDF提取
lsof -i :8001  # 文本切分
lsof -i :8000  # 向量数据库
lsof -i :8501  # 对话检索
```

## 🐛 故障排查

### 服务启动失败

1. **查看日志文件**
   ```bash
   cat logs/[service_name].log
   ```

2. **检查端口是否被占用**
   ```bash
   lsof -i :[port]
   ```

3. **检查Python依赖**
   ```bash
   pip list | grep [package_name]
   ```

### 服务意外退出

1. 查看日志中的错误信息
2. 确认依赖服务（如Milvus）是否正常运行
3. 检查系统资源（内存、磁盘空间）

### 端口冲突

如果端口被占用，可以修改服务代码中的端口号：

- `unified_pdf_extraction_service.py`: 第624行 `port=8006`
- `markdown_chunker_api.py`: 第231行 `port=8001`
- `milvus_api.py`: 第714行 `port=8000`
- `kb_chat.py`: 第865行 `port=8501`

## 📦 目录结构

```
backend/
├── start_all_services.sh    # 启动脚本
├── stop_all_services.sh     # 停止脚本
├── status_services.sh       # 状态查看脚本
├── logs/                    # 日志目录（自动创建）
│   ├── pdf_extraction.log
│   ├── chunker.log
│   ├── milvus_api.log
│   └── chat.log
├── pids/                    # PID文件目录（自动创建）
│   ├── pdf_extraction.pid
│   ├── chunker.pid
│   ├── milvus_api.pid
│   └── chat.pid
└── [各服务目录]
```

## ⚙️ 环境要求

### Python依赖

每个服务需要的主要依赖：

**PDF提取服务:**
- fastapi
- PyMuPDF>=1.23.16,<1.24.0
- pymupdf4llm（可选增强，不纳入默认安装）
- pdf2image

**文本切分服务:**
- fastapi
- (自定义切分逻辑)

**向量数据库服务:**
- fastapi
- pymilvus
- requests (调用embedding API)

**对话检索服务:**
- fastapi
- openai (AsyncOpenAI)
- httpx (重排序)

### 系统依赖

- Python 3.8+
- Milvus 向量数据库（需单独部署）

## 🔐 配置说明

### 向量数据库配置

修改 `Database/milvus_server/milvus_api.py` 中的环境变量：

```python
MILVUS_HOST = os.getenv("MILVUS_HOST", "192.168.110.131")
MILVUS_PORT = os.getenv("MILVUS_PORT", "19530")
EMBEDDING_URL = os.getenv("EMBEDDING_URL", "https://api.jina.ai/v1/embeddings")
EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY", "your_api_key")
```

### LLM配置

对话服务通过API请求传入配置，不需要在代码中配置。

## 📞 联系与支持

如有问题，请查看各服务的日志文件进行排查。

---

**最后更新**: 2025-10-15
