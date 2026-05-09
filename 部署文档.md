# 多模态 RAG 系统 - 部署和启动文档

## 目录
- [系统概述](#系统概述)
- [环境要求](#环境要求)
- [后端部署](#后端部署)
- [前端部署](#前端部署)
- [环境配置](#环境配置)
- [启动服务](#启动服务)
- [验证部署](#验证部署)
- [常见问题](#常见问题)

---

## 系统概述

本项目是一个多模态 RAG（Retrieval-Augmented Generation）系统，包含以下服务：

**后端服务：**
- PDF 提取服务 (端口: 8006)
- 文本切分服务 (端口: 8001)
- 向量数据库服务 (端口: 8000)
- 对话检索服务 (端口: 8501)

**前端服务：**
- Web 界面 (默认端口: 5173)

**当前版本补充说明：**
- 前端已支持中英文切换，可在 `Settings -> General -> Language` 中切换
- 后端 `start_all_services.sh` 已修正为优先识别当前激活的 Conda 环境，并兼容 `Miniconda`
- 后端启动脚本现在会检查“端口是否真的监听成功”，避免进程存在但服务未真正启动时被误判为成功
- `milvus_api` 的文档详情/PDF/图片接口已改为优先读取 `.env` 中的 `UPLOAD_BASE_DIR` 和 `EXTRACTION_RESULTS_DIR`，并兼容历史目录结构，修复“新建知识库上传文档后点击查看提示文档不存在”的问题

---

## 环境要求

### 系统要求
- 操作系统: Linux / macOS / Windows (推荐 Linux)
- Python: 3.8+
- Node.js: 16.0+
- Conda: Anaconda 或 Miniconda

### 依赖工具
- Git
- Docker (用于 Milvus 向量数据库)
- npm 或 yarn

---

## 后端部署

### 1. 创建 Conda 虚拟环境

```bash
# 创建虚拟环境（Python 3.8-3.11 推荐）
conda create -n vlm_rag python=3.11 -y

# 激活虚拟环境
conda activate vlm_rag
```

### 2. 安装 Python 依赖

```bash
# 进入项目根目录
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG

# 进入后端目录
cd backend

# 建议先升级 pip
python -m pip install --upgrade pip

# 安装依赖包
pip install -r requirements.txt

# 如果安装较慢，可以使用国内镜像源
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

说明：
- 后端依赖已将 `pymilvus` 对齐到 `2.5.x`，与项目内置的 `Milvus 2.5.6` 部署配置一致。
- 不再手动锁定 `protobuf==4.25.1`，由 `pip` 自动解析兼容版本，避免 `pymilvus/protobuf` 冲突。
- 默认安装方案已移除 `pymupdf4llm`，并固定 `PyMuPDF<1.24.0` 以兼容 `langchain-chatchat`。
- `fastapi` 已固定为 `0.109.2`，以兼容 `langchain-chatchat 0.3.1.3` 的依赖约束。
- `langchain` 相关依赖已回退到 `0.1.x` 代际，并显式加入 `langchain-openai==0.0.6` 与 `openai==1.30.5`，避免和 `langchain-chatchat 0.3.1.3` 混用新旧版本。
- `python-multipart` 已固定为 `0.0.9`，以兼容 `langchain-chatchat 0.3.1.3`。
- `requests` 已固定为 `2.31.0`，以兼容 `langchain-chatchat 0.3.1.3` 对 `<2.32.0` 的约束。
- PDF 快速模式仍可用；若未安装 `pymupdf4llm`，系统会自动回退到纯 `PyMuPDF` 提取。

### 3. 安装主要依赖说明

项目依赖的主要包括：
- `fastapi`: Web 框架
- `uvicorn`: ASGI 服务器
- `pymilvus`: Milvus 向量数据库客户端（推荐 `2.5.x`）
- `langchain`: LLM 应用框架
- `openai`: OpenAI API 客户端
- `PyMuPDF`: PDF 解析与快速模式基础能力
- `pymupdf4llm`: 可选增强解析库（不纳入默认安装，避免与 `langchain-chatchat` 的 `PyMuPDF` 版本要求冲突）
- `pandas`, `numpy`: 数据处理

### 4. 启动 Milvus 数据库（如需要）

如果使用 Docker 部署 Milvus：

```bash
# 进入 Milvus 服务目录
cd Database/milvus_server

# 启动 Milvus (需要先有 docker-compose.yml 文件)
./start_milvus.sh
# 或使用 docker-compose
docker-compose up -d
```

---

## 前端部署

### 1. 进入前端目录

```bash
cd frontend
```

### 2. 安装依赖

```bash
# 使用 npm 安装
npm install

# 如果安装较慢，可以使用国内镜像
npm install --registry=https://registry.npmmirror.com
```

### 3. 依赖安装说明

前端项目使用：
- React 18
- TypeScript
- Vite 构建工具
- Tailwind CSS
- Radix UI 组件库

### 4. 当前前端脚本说明

当前前端脚本已调整为直接调用真实的 Node 入口，避免本地 `node_modules/.bin` 包装脚本异常导致 `npm run build` 或 `npm run dev` 失败。

常用命令：

```bash
# 启动开发环境
npm run dev

# 构建生产包
npm run build

# 预览构建结果
npm run preview
```

---

## 环境配置

### 后端环境配置

编辑 `backend/.env` 文件，配置以下参数：

```bash
# ============ 生成模型（多模态）服务配置 ============
# 选择使用 OpenAI 或其他模型服务
API_KEY=your_api_key_here
MODEL_NAME=qwen3-vl-plus  # 或 gpt-4o
MODEL_URL=https://dashscope.aliyuncs.com/compatible-mode/v1

# ============ 向量嵌入服务配置 ============
EMBEDDING_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
EMBEDDING_MODEL_NAME=text-embedding-v4
EMBEDDING_API_KEY=your_embedding_api_key

# ============ PDF 上传和提取服务配置 ============
# 上传文件根目录；服务会自动按 YYYY/MM/DD 创建子目录
UPLOAD_BASE_DIR=/your/path/to/Multimodal_RAG/uploads

# 提取结果根目录；每个文档会生成 output/<file_id>/...
EXTRACTION_RESULTS_DIR=/your/path/to/Multimodal_RAG/output

MAX_FILE_SIZE_MB=50

# 服务端口配置
INFOR_EXTRAC_SERVICE_PORT=8006
CHUNK_SERVICE_PORT=8001
MILVUS_API_PORT=8000
CHAT_SERVICE_PORT=8501

# ============ Milvus 向量数据库配置 ============
MILVUS_HOST=localhost
MILVUS_PORT=19530
```

**关键配置项说明：**

1. **API_KEY**: 必须配置，用于调用 LLM 服务
2. **UPLOAD_BASE_DIR** 和 **EXTRACTION_RESULTS_DIR**: 需要修改为你的实际路径，并且要指向“根目录”而不是某个 `file_id` 子目录
3. **UPLOAD_BASE_DIR** 推荐配置为项目根目录下的 `uploads/`，**EXTRACTION_RESULTS_DIR** 推荐配置为项目根目录下的 `output/`
4. 当前 `milvus_api` 已兼容历史目录结构 `backend/output/uploads` 与 `backend/output/extraction_results`，但新部署建议统一使用 `uploads/` 与 `output/`
5. 修改 `backend/.env` 后，需要重启 `pdf_extraction` 与 `milvus_api` 服务，最简单的方式是执行 `cd backend && ./restart_all_services.sh`
6. **MODEL_URL**: 如果使用 OpenAI 兼容网关，推荐直接填写完整接口根路径，例如 `https://your-gateway.example.com/v1`；不要只写域名根路径，否则聊天服务可能请求到站点首页而不是模型接口
7. **MILVUS_HOST/PORT**: 如果 Milvus 部署在其他机器，需要修改

### 前端环境配置

编辑 `frontend/.env` 文件：

```bash
# API 服务地址配置
VITE_MILVUS_API_URL=http://localhost:8000
VITE_CHAT_API_URL=http://localhost:8501
VITE_EXTRACTION_API_URL=http://localhost:8006
VITE_CHUNK_API_URL=http://localhost:8001
```

**配置说明：**
- 如果后端服务部署在其他机器，将 `localhost` 修改为对应的 IP 地址或域名
- 确保端口号与后端配置一致

---

## 启动服务

### 推荐启动顺序（完整版本）

建议按下面顺序启动，先后端，再前端。

#### 1. 激活 Python 环境

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG
conda activate vlm_rag
```

#### 2. 启动后端 4 个服务

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
./start_all_services.sh
```

#### 3. 单独启动前端

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/frontend
npm run dev
```

#### 4. 访问地址

```text
前端界面: http://localhost:5173
PDF提取服务: http://localhost:8006
文本切分服务: http://localhost:8001
向量数据库服务: http://localhost:8000
对话检索服务: http://localhost:8501
```

### 方式一：使用脚本一键启动所有后端服务（推荐）

```bash
# 进入后端目录
cd backend

# 确保脚本有执行权限
chmod +x start_all_services.sh

# 启动所有服务
./start_all_services.sh
```

启动脚本会自动：
- 优先检测并使用当前激活的 Conda 虚拟环境
- 若未激活环境，优先尝试 `/root/miniconda3/envs/vlm_rag/bin/python`
- 兼容 `/root/anaconda3/envs/vlm_rag/bin/python`
- 按顺序启动所有服务
- 检查端口占用并清理
- 检查端口是否真正监听成功，避免“假启动成功”
- 将日志输出到 `logs/` 目录
- 将进程 PID 保存到 `pids/` 目录

说明：
- 这个脚本只启动后端，不会启动前端
- 启动完后端后，仍需单独执行 `frontend` 目录下的 `npm run dev`

### 方式二：手动启动各个服务

如果需要单独启动某个服务：

```bash
# 激活虚拟环境
conda activate vlm_rag

# 启动 PDF 提取服务
cd backend/Information-Extraction/unified
python unified_pdf_extraction_service.py

# 启动文本切分服务
cd backend/Text_segmentation
python markdown_chunker_api.py

# 启动向量数据库 API 服务
cd backend/Database/milvus_server
python milvus_api.py

# 启动对话检索服务
cd backend/chat
python kb_chat.py
```

### 启动前端服务

```bash
# 进入前端目录
cd frontend

# 启动开发服务器
npm run dev
```

前端服务会在 `http://localhost:5173` 启动（或其他可用端口）。

注意：
- 前端界面地址是 `http://localhost:5173`
- `8000/8001/8006/8501` 都是后端接口端口，不是前端页面

---

## 验证部署

### 1. 检查后端服务状态

```bash
# 使用状态检查脚本
cd backend
./status_services.sh

# 或手动检查端口占用
netstat -tuln | grep -E '8000|8001|8006|8501'
```

### 2. 测试 API 接口

```bash
# 测试 Milvus API 服务
curl http://localhost:8000/health

# 测试 PDF 提取服务
curl http://localhost:8006/health

# 测试文本切分服务
curl http://localhost:8001/health

# 测试对话检索服务
curl http://localhost:8501/health
```

### 3. 访问前端界面

在浏览器中打开：`http://localhost:5173`

如果浏览器里看到的是一段 JSON，而不是前端界面，说明你访问到了后端接口端口，而不是前端端口。

示例：
- `http://localhost:8001` 返回 `Markdown文本切分API` 的健康检查 JSON
- `http://localhost:5173` 才是前端页面

### 4. 查看服务日志

```bash
# 查看所有服务日志
tail -f backend/logs/*.log

# 查看特定服务日志
tail -f backend/logs/chat.log
tail -f backend/logs/pdf_extraction.log
```

---



## 管理命令

### 停止所有服务

```bash
cd backend
./stop_all_services.sh
```

### 重启所有服务

```bash
cd backend
./restart_all_services.sh
```

### 查看服务状态

```bash
cd backend
./status_services.sh
```

---

## 常见问题

### 1. `pymilvus` 与 `protobuf` 版本冲突

如果安装时出现类似下面的错误：

```text
Cannot install pymilvus and protobuf==4.25.1 because these package versions have conflicting dependencies
```

说明当前环境里残留了旧的冲突版本，或仍在使用旧的依赖文件。可以执行下面的清理重装命令：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
pip uninstall -y pymilvus protobuf
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 2. `pymupdf4llm` 与 `langchain-chatchat` 的 `PyMuPDF` 版本冲突

如果安装时出现类似下面的错误：

```text
pymupdf4llm depends on pymupdf>=1.26.3
langchain-chatchat 0.3.1.3 depends on PyMuPDF<1.24.0 and >=1.23.16
```

请使用当前仓库中的新版 `requirements.txt`，并清理旧安装残留：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
pip uninstall -y pymupdf4llm PyMuPDF
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 3. `fastapi` 与 `langchain-chatchat` 版本冲突

如果安装时出现类似下面的错误：

```text
langchain-chatchat 0.3.1.3 depends on fastapi<0.110.0 and >=0.109.2
The user requested fastapi==0.119.0
```

说明当前环境仍在使用旧版依赖文件。请更新仓库后重新安装，必要时先清理本地残留：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
pip uninstall -y fastapi starlette
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 4. `langchain` 与 `langchain-chatchat` 版本冲突

如果安装时出现类似下面的错误：

```text
langchain-chatchat 0.3.1.3 depends on langchain==0.1.17
langchain-chatchat 0.3.1.3 depends on langchain-openai==0.0.6
```

说明当前环境仍在使用旧版依赖文件，或手动固定了过新的 `langchain` 版本。请清理相关包后重新安装：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
pip uninstall -y langchain langchain-text-splitters langchain-openai openai
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 5. `python-multipart` 与 `langchain-chatchat` 版本冲突

如果安装时出现类似下面的错误：

```text
langchain-chatchat 0.3.1.3 depends on python-multipart==0.0.9
The user requested python-multipart==0.0.20
```

请使用当前仓库中的新版 `requirements.txt`，然后直接重新安装：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 6. `requests` 与 `langchain-chatchat` 版本冲突

如果安装时出现类似下面的错误：

```text
langchain-chatchat 0.3.1.3 depends on requests<2.32.0 and >=2.31.0
The user requested requests==2.32.5
```

请使用当前仓库中的新版 `requirements.txt`，然后重新安装：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 7. `cd backend` 报错 `No such file or directory`

请先进入项目根目录，再进入后端目录：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG
cd backend
```

### 8. 启动后前端页面只显示一段 JSON

如果浏览器中看到类似下面的内容：

```text
{"status":"healthy","service":"Markdown文本切分API", ...}
```

原因通常是：

1. 你打开了后端接口端口，例如 `http://localhost:8001`
2. 前端开发服务器还没有启动

正确做法：

```bash
# 先启动后端
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
conda activate vlm_rag
./start_all_services.sh

# 再启动前端
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/frontend
npm run dev
```

然后访问：

```text
http://localhost:5173
```

不要访问下面这些后端端口作为前端页面：

```text
http://localhost:8000
http://localhost:8001
http://localhost:8006
http://localhost:8501
```

### 9. `start_all_services.sh` 误用系统 Python

如果脚本输出类似：

```text
⚠️ 使用系统Python (可能缺少依赖)
```

请先手动激活环境再执行：

```bash
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG
conda activate vlm_rag
cd backend
./start_all_services.sh
```

当前版本的启动脚本已经优先识别：

- 当前激活的 Conda 环境
- `/root/miniconda3/envs/vlm_rag/bin/python`
- `/root/anaconda3/envs/vlm_rag/bin/python`

### 10. 上传后点击“查看”提示“文档不存在”

这个问题通常由“上传目录/提取结果目录配置”和“文档查看接口读取目录”不一致导致。当前版本已经修复接口侧的硬编码路径问题，但部署时仍应保证 `.env` 配置正确，并在修改后重启服务。

推荐检查顺序：

```bash
# 1. 检查环境变量
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
sed -n '1,80p' .env

# 2. 推荐目录应类似：
# UPLOAD_BASE_DIR=/.../Multimodal_RAG/uploads
# EXTRACTION_RESULTS_DIR=/.../Multimodal_RAG/output

# 3. 检查上传后的 PDF 是否落盘
find ../uploads -maxdepth 4 -type f | head

# 4. 检查提取结果是否生成
find ../output -maxdepth 2 -name metadata.json | head

# 5. 重启服务使新配置生效
./restart_all_services.sh
```

补充说明：

- 新上传文件的原始 PDF 默认位于 `uploads/YYYY/MM/DD/`
- 提取结果默认位于 `output/<file_id>/`，其中至少应包含 `metadata.json`
- 当前 `milvus_api` 会优先按 `.env` 配置查找，同时兼容旧目录 `backend/output/uploads` 和 `backend/output/extraction_results`
- 如果问题仍然存在，优先检查 `backend/logs/milvus_api.log` 和 `backend/logs/pdf_extraction.log`

### 11. 对话不报错，但没有任何文本输出

如果聊天接口返回 `200 OK`，并且日志里能看到：

```text
✓ RAG对话完成
```

但前端没有任何回答文本，通常不是前端渲染问题，而是聊天服务虽然完成了请求流程，但没有从模型接口拿到有效内容。

当前版本已经修复两类常见原因：

1. `AsyncOpenAI` 与当前 `httpx` 版本不兼容，触发类似：

```text
调用LLM失败: AsyncClient.__init__() got an unexpected keyword argument 'proxies'
```

2. `MODEL_URL` 没有带 `/v1`，例如错误地配置成：

```bash
MODEL_URL=https://ai.gs88.shop
```

这类地址在浏览器里可能能打开，但对 OpenAI SDK 来说，请求到的往往是站点首页 HTML，而不是模型接口，常见表现包括：

- 流式返回里只有 `sources` 和 `metadata`，没有 `content`
- 非流式调用报错：`'str' object has no attribute 'choices'`

推荐配置：

```bash
MODEL_URL=https://ai.gs88.shop/v1
```

检查顺序：

```bash
# 1. 检查后端 .env 中的模型地址
cd /root/Agent-Project-Collection/cases/1_RAG—VLM/Multimodal_RAG/backend
sed -n '1,40p' .env

# 2. 确认 MODEL_URL 是否为 OpenAI 兼容根路径
# 例如:
# MODEL_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
# 或:
# MODEL_URL=https://your-gateway.example.com/v1

# 3. 重启聊天服务使配置生效
./restart_all_services.sh

# 4. 查看聊天日志
tail -f logs/chat.log
```

补充说明：

- 当前版本的 `backend/chat/kb_chat.py` 会自动对 OpenAI 兼容地址做 `/v1` 归一化处理，但部署时仍建议在 `.env` 中直接写完整正确的地址
- 如果日志里显示 `POST /chat 200 OK` 且 `RAG对话完成`，但仍无文本输出，优先排查 `MODEL_URL` 是否指向了网页入口而不是 API 根路径
