# 切分服务集成方案

## 目标

实现 **上传 → 提取 → 切分** 一站式流程，只需一次请求即可完成所有步骤。

---

## 架构设计

```
┌─────────────┐
│   前端      │
│  上传PDF    │
└──────┬──────┘
       │ POST /api/v1/files/upload
       │ {
       │   file,
       │   auto_extract: true,
       │   auto_chunk: true,
       │   chunking_config: {...}
       │ }
       ↓
┌──────────────────────────────────┐
│  提取服务 (端口 8006)             │
│  unified_pdf_extraction_service  │
├──────────────────────────────────┤
│  1. 保存 PDF 文件                │
│  2. 提取内容 (fast/accurate)     │
│  3. 保存 Markdown                │
│  4. 调用切分服务          │ ←───┐
│  5. 保存切分结果          │     │
│  6. 返回完整结果                 │     │
└──────────────────────────────────┘     │
       │ HTTP Request                     │
       │ POST http://localhost:8001/chunk │
       ↓                                   │
┌──────────────────────────────────┐     │
│  切分服务 (端口 8001)             │     │
│  markdown_chunker_api            │     │
├──────────────────────────────────┤     │
│  1. 接收 Markdown 文本           │     │
│  2. 执行切分 (header_recursive)  │     │
│  3. 返回切分结果                 │─────┘
└──────────────────────────────────┘
       │
       │ 切分结果返回
       ↓
    存储到本地
    extraction_results/{file_id}/chunks.json
```

---

## 实现步骤

### 1. 修改 `.env` 配置

在 `/backend/.env` 中添加切分服务配置：

```bash
# 切分服务配置
CHUNKING_SERVICE_ENABLED=true
```

### 2. 修改提取服务代码

#### 2.1 添加依赖

```python
import httpx  # 用于调用切分服务
```

#### 2.2 读取切分服务配置

```python
# 切分服务配置
CHUNKING_SERVICE_URL = os.getenv("CHUNKING_SERVICE_URL", "http://localhost:8001")
CHUNKING_SERVICE_ENABLED = os.getenv("CHUNKING_SERVICE_ENABLED", "true").lower() == "true"

print(f"  - 切分服务: {CHUNKING_SERVICE_URL} ({'启用' if CHUNKING_SERVICE_ENABLED else '禁用'})")
```

#### 2.3 创建调用切分服务的函数

```python
async def call_chunking_service(
    markdown: str,
    filename: str,
    chunking_config: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """
    调用切分服务

    Args:
        markdown: Markdown 文本
        filename: 文件名
        chunking_config: 切分配置（可选）

    Returns:
        切分结果
    """
    if not CHUNKING_SERVICE_ENABLED:
        raise Exception("切分服务未启用")

    default_config = {
        "method": "header_recursive",
        "chunk_size": 1500,
        "chunk_overlap": 200,
        "merge_tolerance": 0.2,
        "max_page_span": 3,
        "bridge_span": 150,
        "add_bridges": True
    }

    config = {**default_config, **(chunking_config or {})}

    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(
                f"{CHUNKING_SERVICE_URL}/chunk",
                json={
                    "markdown": markdown,
                    "filename": filename,
                    "config": config
                }
            )
            response.raise_for_status()
            return response.json()
    except httpx.HTTPError as e:
        raise Exception(f"调用切分服务失败: {str(e)}")
```

#### 2.4 创建保存切分结果的函数

```python
def save_chunking_results(file_id: str, chunking_result: Dict[str, Any]) -> str:
    """
    保存切分结果到本地

    Args:
        file_id: 文件 ID
        chunking_result: 切分结果

    Returns:
        保存的文件路径
    """
    result_dir = EXTRACTION_RESULTS_DIR / file_id
    result_dir.mkdir(parents=True, exist_ok=True)

    chunks_path = result_dir / "chunks.json"

    # 保存完整的切分结果
    with open(chunks_path, 'w', encoding='utf-8') as f:
        json.dump(chunking_result, f, ensure_ascii=False, indent=2)

    print(f"✓ 切分结果已保存到: {chunks_path}")
    return str(chunks_path)
```

### 响应示例

```json
{
  "success": true,
  "message": "文件上传成功并已完成提取",
  "data": {
    "file_id": "file_20251016_abc123",
    "filename": "document.pdf",
    "file_size": 2048576,
    "file_path": "/path/to/file.pdf",
    "upload_time": "2025-10-16T10:30:00",
    "extraction": {
      "status": "completed",
      "mode": "fast",
      "total_pages": 50,
      "total_images": 120,
      "markdown_path": "/path/to/document.md",
      "images_dir": "/path/to/images"
    },
    "chunking": {
      "status": "completed",
      "method": "header_recursive",
      "total_chunks": 85,
      "chunks_path": "/path/to/chunks.json"
    }
  }
}
```

---

## 本地存储结构

```
extraction_results/
└── file_20251016_abc123/
    ├── document.md              # Markdown 提取结果
    ├── metadata.json            # 元数据
    ├── chunks.json              # 切分结果
    └── images/                  # 图片
        ├── page_1_full.png
        └── ...
```

### chunks.json 示例

```json
{
  "success": true,
  "message": "切分成功，使用方法: header_recursive",
  "filename": "document.pdf",
  "data": {
    "markdown": "{{第1页}}\n# 标题...",
    "full_text": "完整文本...",
    "chunks": [
      {
        "page_start": 1,
        "page_end": 1,
        "pages": [1],
        "text": "第一个chunk的文本...",
        "text_length": 1450,
        "headers": {"h1": "标题1"},
        "continued": false,
        "cross_page_bridge": false,
        "is_table_like": false
      },
      {
        "page_start": 1,
        "page_end": 2,
        "pages": [1, 2],
        "text": "跨页的chunk...",
        "text_length": 1520,
        "headers": {"h1": "标题1", "h2": "小标题"},
        "continued": true,
        "cross_page_bridge": false,
        "is_table_like": false
      }
    ],
    "chunking_config": {
      "method": "header_recursive",
      "chunk_size": 1500,
      "chunk_overlap": 200,
      "merge_tolerance": 0.2,
      "max_page_span": 3,
      "bridge_span": 150,
      "add_bridges": true
    },
    "chunk_stats": {
      "total_chunks": 85,
      "bridge_chunks": 5,
      "cross_page_chunks": 12,
      "single_page_chunks": 68,
      "table_chunks": 3,
      "avg_chunk_length": 1423.5
    }
  }
}
```

---

## 使用场景

### 场景 1: 仅上传不提取不切分

```bash
curl -X POST "http://localhost:8006/api/v1/files/upload" \
  -F "file=@doc.pdf"
```

### 场景 2: 上传 + 提取（不切分）

```bash
curl -X POST "http://localhost:8006/api/v1/files/upload" \
  -F "file=@doc.pdf" \
  -F "auto_extract=true" \
  -F "extraction_mode=fast"
```

### 场景 3: 上传 + 提取 + 切分（完整流程）

```bash
curl -X POST "http://localhost:8006/api/v1/files/upload" \
  -F "file=@doc.pdf" \
  -F "auto_extract=true" \
  -F "extraction_mode=fast" \
  -F "auto_chunk=true" \
  -F "chunk_size=1500"
```

---
