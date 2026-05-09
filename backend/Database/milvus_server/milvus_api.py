import base64
import uuid
import json
import os
import re
import requests
import time
import mimetypes
from typing import Dict, List, Any, Optional
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlparse

import uvicorn
from fastapi import FastAPI, HTTPException, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel
from pymilvus import connections, Collection, CollectionSchema, FieldSchema, DataType, utility
from dotenv import load_dotenv

# 加载 backend/.env 文件
env_path = Path(__file__).parent.parent.parent / '.env'
load_dotenv(dotenv_path=env_path, override=True)

BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
PROJECT_ROOT = BACKEND_ROOT.parent

# 环境变量配置
MILVUS_HOST = os.getenv("MILVUS_HOST")
MILVUS_PORT = os.getenv("MILVUS_PORT")
EMBEDDING_URL = os.getenv("EMBEDDING_URL")
EMBEDDING_MODEL_NAME = os.getenv("EMBEDDING_MODEL_NAME")
EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY")

VALID_PIPELINE_TYPES = {"vlm", "ocr"}


def normalize_pipeline_type(pipeline_type: Optional[str], default: str = "vlm") -> str:
    """规范化知识库 pipeline 类型。"""
    normalized = (pipeline_type or "").strip().lower()
    if normalized in VALID_PIPELINE_TYPES:
        return normalized
    return default


class EmbeddingServiceError(RuntimeError):
    """Embedding 服务不可用或返回了非法结果。"""


def normalize_embedding_url(raw_url: Optional[str]) -> str:
    """
    归一化 OpenAI 兼容 embedding 地址。

    支持传入基地址、`/v1` 基地址或完整 `/embeddings` 端点。
    """
    normalized = (raw_url or "").strip().rstrip("/")
    if not normalized:
        return normalized

    parsed = urlparse(normalized)
    path = parsed.path.rstrip("/")

    if path.endswith("/embeddings"):
        return normalized

    if path.endswith("/v1") or path.endswith("/compatible-mode/v1"):
        return f"{normalized}/embeddings"

    if path:
        return f"{normalized}/embeddings"

    return f"{normalized}/v1/embeddings"


def _dedupe_paths(paths: List[Optional[Path]]) -> List[Path]:
    """按顺序去重路径，保留候选目录优先级。"""
    unique_paths: List[Path] = []
    seen = set()

    for path in paths:
        if path is None:
            continue

        path_str = str(path)
        if path_str in seen:
            continue

        seen.add(path_str)
        unique_paths.append(path)

    return unique_paths


def get_upload_search_dirs() -> List[Path]:
    """返回上传文件目录候选列表，兼容当前与历史目录结构。"""
    configured_dir = os.getenv("UPLOAD_BASE_DIR")
    configured_path = Path(configured_dir).expanduser() if configured_dir else None

    return _dedupe_paths([
        configured_path,
        configured_path / "uploads" if configured_path else None,
        PROJECT_ROOT / "uploads",
        BACKEND_ROOT / "output" / "uploads",
        BACKEND_ROOT / "uploads",
    ])


def get_extraction_search_dirs() -> List[Path]:
    """返回抽取结果目录候选列表，兼容当前与历史目录结构。"""
    configured_dir = os.getenv("EXTRACTION_RESULTS_DIR")
    configured_path = Path(configured_dir).expanduser() if configured_dir else None

    return _dedupe_paths([
        configured_path,
        configured_path / "extraction_results" if configured_path else None,
        PROJECT_ROOT / "output",
        PROJECT_ROOT / "output" / "extraction_results",
        BACKEND_ROOT / "output" / "extraction_results",
        BACKEND_ROOT / "extraction_results",
    ])


def get_visualization_search_dirs() -> List[Path]:
    """返回 OCR 可视化目录候选列表。"""
    configured_dir = os.getenv("MINERU_VIZ_DIR")
    configured_path = Path(configured_dir).expanduser() if configured_dir else None

    return _dedupe_paths([
        configured_path,
        PROJECT_ROOT / "backend" / "mineru_visualizations",
        BACKEND_ROOT / "mineru_visualizations",
    ])


def find_extraction_dir(file_id: str) -> Optional[Path]:
    """按候选目录查找文档提取结果目录。"""
    for base_dir in get_extraction_search_dirs():
        extraction_dir = base_dir / file_id
        if extraction_dir.exists():
            return extraction_dir
    return None


def find_visualization_dir(file_id: str) -> Optional[Path]:
    """按候选目录查找 OCR 可视化目录。"""
    for base_dir in get_visualization_search_dirs():
        if not base_dir.exists():
            continue

        exact_dir = base_dir / file_id
        if exact_dir.is_dir():
            return exact_dir

        try:
            matches = sorted(
                [path for path in base_dir.glob(f"*{file_id}*") if path.is_dir()],
                key=lambda path: path.stat().st_mtime,
                reverse=True,
            )
        except OSError:
            continue

        if matches:
            return matches[0]

    return None


def find_uploaded_pdf(file_id: str, filename: str) -> Optional[Path]:
    """按候选目录查找原始 PDF 文件。"""
    safe_filename = Path(filename).name
    exact_filename = f"{file_id}_{safe_filename}"
    timestamped_suffix = f"_{file_id}_{safe_filename}"

    for base_dir in get_upload_search_dirs():
        if not base_dir.exists():
            continue

        try:
            matches = base_dir.rglob("*.pdf")
        except OSError:
            continue

        for match in matches:
            if not match.is_file():
                continue

            if match.name == exact_filename or match.name.endswith(timestamped_suffix):
                return match

    return None


def find_preferred_file(extraction_dir: Path, exact_names: List[str], glob_patterns: List[str]) -> Optional[Path]:
    """在抽取目录中按优先级查找文件。"""
    for name in exact_names:
        candidate = extraction_dir / name
        if candidate.exists():
            return candidate

    for pattern in glob_patterns:
        matches = sorted(extraction_dir.glob(pattern))
        for match in matches:
            if match.is_file():
                return match

    return None


def load_output_payload(extraction_dir: Path) -> Dict[str, Any]:
    """统一读取 V2 output/chunked_output 数据结构。"""
    output_path = find_preferred_file(
        extraction_dir,
        exact_names=[],
        glob_patterns=["*_chunked_output.json", "*_output.json"]
    )
    if output_path is None:
        return {}

    with open(output_path, 'r', encoding='utf-8') as f:
        payload = json.load(f)

    if isinstance(payload, dict) and isinstance(payload.get("data"), dict):
        payload = payload["data"]

    return payload if isinstance(payload, dict) else {}


def load_primary_result_data(extraction_dir: Path) -> Dict[str, Any]:
    """读取 output.json 中首个 result 节点。"""
    payload = load_output_payload(extraction_dir)
    results = payload.get("results", {})
    if not isinstance(results, dict):
        return {}

    for result in results.values():
        if isinstance(result, dict):
            return result

    return {}


def guess_media_type(filename: str) -> str:
    media_type, _ = mimetypes.guess_type(filename)
    return media_type or "application/octet-stream"


def list_embedded_images(extraction_dir: Path, file_id: str) -> List[Dict[str, str]]:
    """列出 OCR output.json 中的嵌入图片。"""
    result_data = load_primary_result_data(extraction_dir)
    images = result_data.get("images", {})
    if not isinstance(images, dict):
        return []

    assets: List[Dict[str, str]] = []
    for image_key in sorted(images.keys()):
        image_name = Path(image_key).name
        assets.append({
            "name": image_name,
            "url": f"/document/{file_id}/images/{image_name}",
            "kind": "embedded",
        })
    return assets


def list_visualization_images(file_id: str) -> List[Dict[str, str]]:
    """列出 OCR 可视化图片。"""
    visualization_dir = find_visualization_dir(file_id)
    if visualization_dir is None:
        return []

    assets: List[Dict[str, str]] = []
    for image_path in sorted(visualization_dir.iterdir()):
        if not image_path.is_file():
            continue
        if image_path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".gif", ".webp"}:
            continue

        kind = "annotated" if "annotated" in image_path.stem else "raw"
        assets.append({
            "name": image_path.name,
            "url": f"/document/{file_id}/visualizations/{image_path.name}",
            "kind": kind,
        })

    return assets


def load_document_metadata(extraction_dir: Path) -> Dict[str, Any]:
    """统一读取 V1/V2 文档元数据。"""
    metadata_path = find_preferred_file(
        extraction_dir,
        exact_names=["metadata.json"],
        glob_patterns=["*_metadata.json"]
    )
    if metadata_path is None:
        raise HTTPException(status_code=404, detail="元数据文件不存在")

    with open(metadata_path, 'r', encoding='utf-8') as f:
        raw_metadata = json.load(f)

    legacy_meta = raw_metadata.get("metadata", {}) if isinstance(raw_metadata, dict) else {}
    filename = raw_metadata.get("filename")
    if not filename:
        raise HTTPException(status_code=404, detail="元数据缺少 filename")

    pipeline_type = normalize_pipeline_type(
        raw_metadata.get("pipeline_type") or legacy_meta.get("pipeline_type"),
        default="ocr" if metadata_path.name.endswith("_metadata.json") else "vlm"
    )

    return {
        "metadata_path": metadata_path,
        "raw_metadata": raw_metadata,
        "filename": filename,
        "metadata": legacy_meta,
        "extraction_time": raw_metadata.get("extraction_time"),
        "total_pages": legacy_meta.get("total_pages", raw_metadata.get("total_pages", 0)),
        "total_images": legacy_meta.get("total_images", raw_metadata.get("total_images", 0)),
        "extraction_mode": raw_metadata.get("extraction_mode"),
        "pipeline_type": pipeline_type,
    }


def load_document_chunks(extraction_dir: Path) -> List[Dict[str, Any]]:
    """统一读取 V1/V2 文档 chunks。"""
    chunks_path = find_preferred_file(
        extraction_dir,
        exact_names=["chunks.json"],
        glob_patterns=["*_chunked_output.json"]
    )
    if chunks_path is None:
        return []

    with open(chunks_path, 'r', encoding='utf-8') as f:
        chunk_payload = json.load(f)

    if isinstance(chunk_payload, dict) and isinstance(chunk_payload.get("data"), dict):
        chunk_payload = chunk_payload["data"]

    if isinstance(chunk_payload, dict):
        if "chunks" in chunk_payload:
            return chunk_payload.get("chunks", [])

        results = chunk_payload.get("results", {})
        if isinstance(results, dict):
            for result in results.values():
                if isinstance(result, dict) and "chunks" in result:
                    return result.get("chunks", [])

    if isinstance(chunk_payload, list):
        return chunk_payload

    return []


def load_document_markdown(extraction_dir: Path, filename: str) -> str:
    """统一读取 V1/V2 Markdown 内容。"""
    markdown_path = find_preferred_file(
        extraction_dir,
        exact_names=[f"{Path(filename).stem}.md"],
        glob_patterns=["*_extraction.md", "*.md"]
    )
    if markdown_path and markdown_path.exists():
        with open(markdown_path, 'r', encoding='utf-8') as f:
            return f.read()

    payload = load_output_payload(extraction_dir)
    if not payload:
        return ""

    results = payload.get("results", {})
    if not isinstance(results, dict):
        return ""

    for result in results.values():
        if not isinstance(result, dict):
            continue
        markdown = result.get("markdown") or result.get("md_content")
        if markdown:
            return markdown

    return ""


def normalize_keyword_terms(query_text: str) -> List[str]:
    """标准化关键词查询，兼容中英文短语和分词。"""
    normalized_query = query_text.strip().lower()
    if not normalized_query:
        return []

    terms: List[str] = [normalized_query]
    split_terms = re.split(r"[\s,，。！？；;、/|]+", normalized_query)

    for term in split_terms:
        cleaned = term.strip()
        if cleaned and cleaned not in terms:
            terms.append(cleaned)

    return terms[:10]


def build_keyword_snippet(content: str, keywords: List[str], max_length: int = 220) -> str:
    """根据关键词从文本中截取预览片段。"""
    normalized_content = re.sub(r"\s+", " ", content or "").strip()
    if not normalized_content:
        return ""

    lower_content = normalized_content.lower()
    positions = [
        lower_content.find(keyword)
        for keyword in keywords
        if keyword and lower_content.find(keyword) != -1
    ]

    start = max(min(positions) - 40, 0) if positions else 0
    end = min(start + max_length, len(normalized_content))
    snippet = normalized_content[start:end]

    if start > 0:
        snippet = f"...{snippet}"
    if end < len(normalized_content):
        snippet = f"{snippet}..."

    return snippet


def score_keyword_match(query_text: str, chunk_text: str, filename: str) -> Optional[Dict[str, Any]]:
    """计算关键词匹配分数，并返回命中摘要。"""
    normalized_query = query_text.strip().lower()
    if not normalized_query:
        return None

    keywords = normalize_keyword_terms(query_text)
    content = chunk_text or ""
    content_lower = content.lower()
    filename_value = filename or ""
    filename_lower = filename_value.lower()

    matched_keywords: List[str] = []
    content_hits = 0
    filename_hits = 0

    for keyword in keywords:
        in_content = keyword in content_lower
        in_filename = keyword in filename_lower

        if not in_content and not in_filename:
            continue

        matched_keywords.append(keyword)
        if in_content:
            content_hits += 1
        if in_filename:
            filename_hits += 1

    phrase_in_content = normalized_query in content_lower
    phrase_in_filename = normalized_query in filename_lower

    if not matched_keywords and not phrase_in_content and not phrase_in_filename:
        return None

    unique_keywords = list(dict.fromkeys(matched_keywords))
    score = len(unique_keywords) * 12

    if phrase_in_content:
        score += 30
    if phrase_in_filename:
        score += 20
    if filename_lower == normalized_query:
        score += 40

    if phrase_in_content and phrase_in_filename:
        match_type = "both"
    elif phrase_in_filename or filename_hits > 0:
        match_type = "filename" if content_hits == 0 else "both"
    else:
        match_type = "content"

    snippet = build_keyword_snippet(content, unique_keywords or [normalized_query]) or filename_value

    return {
        "score": score,
        "matched_keywords": unique_keywords,
        "match_type": match_type,
        "snippet": snippet,
    }

# Pydantic 模型定义
class DocumentChunk(BaseModel):
    chunk_text: str
    filename: str
    file_id: Optional[str] = None
    embedding: Optional[List[float]] = None
    metadata: Dict[str, Any] = {}

class UploadKBRequest(BaseModel):
    collection_name: str
    file_data: Dict[str, Any]

class UploadResponse(BaseModel):
    filename: str
    file_id: str
    status: str
    message: str
    chunks_count: int = 0

class SearchRequest(BaseModel):
    collection_name: str
    query_text: str
    top_k: int = 10
    filter_expr: Optional[str] = None

class SearchByFilenameRequest(BaseModel):
    collection_name: str
    filename: str
    top_k: int = 10

class KeywordSearchRequest(BaseModel):
    query_text: str
    collection_name: Optional[str] = None
    top_k: int = 20

class DeleteRequest(BaseModel):
    collection_name: str
    filename: str

class DeleteKBRequest(BaseModel):
    collection_name: str

class UploadV2Request(BaseModel):
    collection_name: str
    file_id: str
    output_json: Dict[str, Any]
    result_key: str

class MilvusRAGService:
    def __init__(self):
        self.milvus_host = MILVUS_HOST
        self.milvus_port = MILVUS_PORT
        self.embedding_url = normalize_embedding_url(EMBEDDING_URL)
        self.embedding_model_name = EMBEDDING_MODEL_NAME
        self.embedding_api_key = EMBEDDING_API_KEY
        
        print(f"Milvus配置: {self.milvus_host}:{self.milvus_port}")
        print(f"Embedding配置: URL={self.embedding_url}, Model={self.embedding_model_name}")
        
        self.connect_to_milvus()
    
    def connect_to_milvus(self):
        """连接到Milvus服务"""
        try:
            connections.connect(
                "default", 
                host=self.milvus_host, 
                port=self.milvus_port
            )
            print(f"Successfully connected to Milvus at {self.milvus_host}:{self.milvus_port}")
        except Exception as e:
            print(f"Failed to connect to Milvus: {e}")
            raise

    def _build_embedding_headers(self) -> Dict[str, str]:
        headers = {
            "Content-Type": "application/json"
        }
        if self.embedding_api_key:
            headers["Authorization"] = f"Bearer {self.embedding_api_key}"
        return headers

    def _request_embeddings(self, texts: List[str], timeout: int) -> List[List[float]]:
        if not self.embedding_url:
            raise EmbeddingServiceError("EMBEDDING_URL 未配置")
        if not self.embedding_model_name:
            raise EmbeddingServiceError("EMBEDDING_MODEL_NAME 未配置")

        payload = {
            "model": self.embedding_model_name,
            "input": texts
        }
        response = requests.post(
            self.embedding_url,
            json=payload,
            headers=self._build_embedding_headers(),
            timeout=timeout
        )

        if response.status_code != 200:
            response_text = (response.text or "").strip()
            detail = f"Embedding API 返回 HTTP {response.status_code}"
            if response_text:
                detail = f"{detail}: {response_text[:300]}"
            raise EmbeddingServiceError(detail)

        try:
            result = response.json()
        except ValueError as exc:
            raise EmbeddingServiceError(f"Embedding API 返回了非 JSON 响应: {exc}") from exc

        data = result.get("data")
        if not isinstance(data, list) or len(data) != len(texts):
            actual = len(data) if isinstance(data, list) else 0
            raise EmbeddingServiceError(
                f"Embedding API 返回的数据条数异常，期望 {len(texts)} 条，实际 {actual} 条"
            )

        embeddings: List[List[float]] = []
        for idx, item in enumerate(data, start=1):
            embedding = item.get("embedding") if isinstance(item, dict) else None
            if not isinstance(embedding, list) or not embedding:
                raise EmbeddingServiceError(f"Embedding API 第 {idx} 条结果缺少有效 embedding")
            embeddings.append(embedding)

        return embeddings
    
    def generate_embedding(self, text: str) -> List[float]:
        """单个文本生成向量（用于query）"""
        try:
            return self._request_embeddings([text], timeout=30)[0]
        except EmbeddingServiceError:
            raise
        except Exception as e:
            raise EmbeddingServiceError(f"Embedding generation failed: {e}") from e
    
    def generate_embeddings_batch(self, texts: List[str], batch_size: int = 32) -> List[List[float]]:
        """
        批量生成embeddings，使用线程池并行处理多个批次
        
        Args:
            texts: 文本列表
            batch_size: 每批次处理的文本数量
        
        Returns:
            按顺序返回的embedding列表
        """
        if not texts:
            return []
        
        total_texts = len(texts)
        print(f"开始批量生成 {total_texts} 个文本的embeddings，批次大小: {batch_size}")
        
        # 预分配结果列表
        all_embeddings = [None] * total_texts
        start_time = time.time()
        errors: List[str] = []
        
        def process_batch(batch_idx: int, batch_texts: List[str]) -> tuple:
            """处理单个批次"""
            start_idx = batch_idx * batch_size
            
            try:
                batch_embeddings = self._request_embeddings(batch_texts, timeout=60)
                return batch_idx, start_idx, batch_embeddings, None
            except Exception as e:
                error_msg = f"处理异常: {str(e)}"
                print(f"批次 {batch_idx + 1} {error_msg}")
                return batch_idx, start_idx, None, error_msg
        
        # 准备批次
        batches = []
        for i in range(0, total_texts, batch_size):
            batch_end = min(i + batch_size, total_texts)
            batches.append((i // batch_size, texts[i:batch_end]))
        
        # 使用线程池并行处理
        with ThreadPoolExecutor(max_workers=4) as executor:
            future_to_batch = {
                executor.submit(process_batch, batch_idx, batch_texts): batch_idx
                for batch_idx, batch_texts in batches
            }
            
            for future in as_completed(future_to_batch):
                batch_idx, start_idx, batch_embeddings, error = future.result()
                if error:
                    errors.append(f"批次 {batch_idx + 1}: {error}")
                    continue

                for i, embedding in enumerate(batch_embeddings or []):
                    all_embeddings[start_idx + i] = embedding
        
        elapsed = time.time() - start_time
        rate = total_texts / elapsed if elapsed > 0 else 0
        print(f"批量生成完成，总耗时: {elapsed:.2f}秒，平均速率: {rate:.2f} 文本/秒")
        
        if errors:
            raise EmbeddingServiceError("; ".join(errors))

        missing_indices = [idx for idx, embedding in enumerate(all_embeddings) if embedding is None]
        if missing_indices:
            raise EmbeddingServiceError(f"Embedding 结果不完整，缺少 {len(missing_indices)} 条")

        return [embedding for embedding in all_embeddings if embedding is not None]
    
    def get_model_dimension(self, model_name: str) -> int:
        """获取模型的向量维度"""
        model_dimensions = {
            "jina-embeddings-v4": 2048,
            "jina-embeddings-v3": 1024,
            "jina-embeddings-v2-base-zh": 512,
            "text-embedding-ada-002": 1536,
            "text-embedding-v4": 1024
        }
        return model_dimensions.get(model_name, 1024)
    
    def create_collection_schema(self, embedding_dim: int = 1024) -> CollectionSchema:
        """创建Collection的Schema"""
        fields = [
            FieldSchema(name="id", dtype=DataType.INT64, is_primary=True, auto_id=True),
            FieldSchema(name="chunk_text", dtype=DataType.VARCHAR, max_length=65535),
            FieldSchema(name="filename", dtype=DataType.VARCHAR, max_length=255),
            FieldSchema(name="file_id", dtype=DataType.VARCHAR, max_length=100),
            FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=embedding_dim),
            FieldSchema(name="metadata", dtype=DataType.VARCHAR, max_length=65535),
            FieldSchema(name="created_at", dtype=DataType.VARCHAR, max_length=50)
        ]
        
        schema = CollectionSchema(
            fields=fields,
            description="RAG Knowledge Base Collection"
        )
        return schema
    
    def generate_collection_id(self) -> str:
        """生成符合Milvus规范的collection ID"""
        import time
        timestamp = int(time.time() * 1000)  # 毫秒级时间戳
        return f"kb_{timestamp}"

    def upsert_name_mapping(
        self,
        collection_id: str,
        display_name: Optional[str] = None,
        pipeline_type: Optional[str] = None
    ) -> Dict[str, Any]:
        """创建或更新 collection 元数据映射。"""
        import json
        from pathlib import Path

        mapping_file = Path(__file__).parent / "collection_name_mapping.json"

        mappings = {}
        if mapping_file.exists():
            with open(mapping_file, 'r', encoding='utf-8') as f:
                mappings = json.load(f)

        existing = mappings.get(collection_id, {})
        resolved_display_name = display_name or existing.get("display_name") or collection_id
        resolved_pipeline_type = (
            normalize_pipeline_type(pipeline_type)
            if pipeline_type is not None
            else normalize_pipeline_type(existing.get("pipeline_type"), default="")
        )

        mapping_payload = {
            "display_name": resolved_display_name,
            "created_at": existing.get("created_at", datetime.now().isoformat())
        }
        if resolved_pipeline_type:
            mapping_payload["pipeline_type"] = resolved_pipeline_type

        mappings[collection_id] = mapping_payload

        with open(mapping_file, 'w', encoding='utf-8') as f:
            json.dump(mappings, f, ensure_ascii=False, indent=2)

        print(
            f"Saved mapping: {collection_id} -> {mapping_payload['display_name']}"
            f" (pipeline_type={mapping_payload.get('pipeline_type', 'unknown')})"
        )
        return mapping_payload

    def save_name_mapping(self, collection_id: str, display_name: str, pipeline_type: str = "vlm"):
        """保存collection ID和显示名称的映射关系到JSON文件"""
        self.upsert_name_mapping(collection_id, display_name=display_name, pipeline_type=pipeline_type)

    def get_name_mapping(self, collection_id: str = None) -> Dict[str, Any]:
        """获取名称映射"""
        import json
        from pathlib import Path

        mapping_file = Path(__file__).parent / "collection_name_mapping.json"

        if not mapping_file.exists():
            return {}

        with open(mapping_file, 'r', encoding='utf-8') as f:
            mappings = json.load(f)

        if collection_id:
            return mappings.get(collection_id, {})
        return mappings

    def delete_name_mapping(self, collection_id: str):
        """删除名称映射"""
        import json
        from pathlib import Path

        mapping_file = Path(__file__).parent / "collection_name_mapping.json"

        if not mapping_file.exists():
            return

        with open(mapping_file, 'r', encoding='utf-8') as f:
            mappings = json.load(f)

        if collection_id in mappings:
            del mappings[collection_id]

            with open(mapping_file, 'w', encoding='utf-8') as f:
                json.dump(mappings, f, ensure_ascii=False, indent=2)

            print(f"Deleted mapping: {collection_id}")

    def infer_pipeline_type(
        self,
        collection_id: str,
        display_name: str = "",
        pipeline_type: Optional[str] = None
    ) -> str:
        """从显式元数据或集合名/显示名推断 pipeline 类型。"""
        explicit_type = normalize_pipeline_type(pipeline_type, default="")
        if explicit_type:
            return explicit_type

        mapping = self.get_name_mapping(collection_id)
        mapped_type = normalize_pipeline_type(mapping.get("pipeline_type"), default="")
        if mapped_type:
            return mapped_type

        name = f"{collection_id} {display_name}".lower()
        if name.endswith("_v2") or "ocr" in name or "mineru" in name or "paddleocr" in name or "deepseek" in name:
            return "ocr"
        return "vlm"

    def create_knowledge_base(self, display_name: str, pipeline_type: str = "vlm", embedding_dim: int = None) -> tuple:
        """
        创建知识库（Collection）

        Args:
            display_name: 用户输入的显示名称（可以是中文）
            pipeline_type: 知识库流水线类型，vlm 或 ocr
            embedding_dim: embedding维度

        Returns:
            (collection_id, success): 返回collection ID和是否成功
        """
        try:
            pipeline_type = normalize_pipeline_type(pipeline_type)
            # 生成符合Milvus规范的collection ID
            collection_id = self.generate_collection_id()

            if utility.has_collection(collection_id):
                # 理论上不会发生，因为使用时间戳
                collection_id = self.generate_collection_id()

            if embedding_dim is None:
                embedding_dim = self.get_model_dimension(self.embedding_model_name)

            schema = self.create_collection_schema(embedding_dim)
            collection = Collection(name=collection_id, schema=schema)

            # 创建索引
            index_params = {
                "metric_type": "COSINE",
                "index_type": "IVF_FLAT",
                "params": {"nlist": 1024}
            }
            collection.create_index(field_name="embedding", index_params=index_params)

            # 参考milvus_kb_service: 创建后立即加载collection
            collection.load()

            # 保存名称映射
            self.save_name_mapping(collection_id, display_name, pipeline_type=pipeline_type)

            print(
                f"Created knowledge base: {collection_id} ('{display_name}') "
                f"with embedding_dim: {embedding_dim}, pipeline_type: {pipeline_type}"
            )
            return collection_id, True

        except Exception as e:
            print(f"Failed to create knowledge base: {e}")
            raise
    
    def delete_knowledge_base(self, collection_id: str) -> bool:
        """删除知识库"""
        try:
            if utility.has_collection(collection_id):
                utility.drop_collection(collection_id)
                # 同时删除名称映射
                self.delete_name_mapping(collection_id)
                print(f"Deleted knowledge base: {collection_id}")
                return True
            return False
        except Exception as e:
            print(f"Failed to delete knowledge base: {e}")
            raise
    
    def create_or_get_collection(self, collection_name: str, embedding_dim: int = None) -> Collection:
        """创建或获取Collection"""
        if utility.has_collection(collection_name):
            collection = Collection(collection_name)
            # 确保已加载
            try:
                collection.load()
            except Exception as e:
                print(f"加载已存在的collection时出错: {e}")
        else:
            if embedding_dim is None:
                embedding_dim = self.get_model_dimension(self.embedding_model_name)
                
            schema = self.create_collection_schema(embedding_dim)
            collection = Collection(name=collection_name, schema=schema)
            
            index_params = {
                "metric_type": "COSINE",
                "index_type": "IVF_FLAT",
                "params": {"nlist": 1024}
            }
            collection.create_index(field_name="embedding", index_params=index_params)
            
            # 参考milvus_kb_service: 创建后立即加载
            collection.load()
        
        return collection
    
    def parse_json_file(self, json_data: Dict[str, Any]) -> List[DocumentChunk]:
        """解析JSON文件并转换为DocumentChunk列表"""
        try:
            documents = []
            
            # 提取基本信息
            filename = json_data.get("filename", "unknown.txt")
            if filename.startswith("/"):
                filename = os.path.basename(filename)
            
            data_section = json_data.get("data", {})
            chunks = data_section.get("chunks", [])
            
            print(f"开始解析文件: {filename}, 包含 {len(chunks)} 个chunks")
            
            # 为每个chunk创建DocumentChunk
            for i, chunk in enumerate(chunks):
                chunk_text = chunk.get("text", "")
                if not chunk_text.strip():
                    print(f"跳过空chunk {i}")
                    continue
                
                # 构建metadata
                metadata = {
                    "page_start": chunk.get("page_start", 1),
                    "page_end": chunk.get("page_end", 1),
                    "pages": chunk.get("pages", [1]),
                    "text_length": chunk.get("text_length", len(chunk_text)),
                    "continued": chunk.get("continued", False),
                    "cross_page_bridge": chunk.get("cross_page_bridge", False),
                    "is_table_like": chunk.get("is_table_like", False),
                    "chunk_index": i
                }
                
                # 添加文档级别的metadata
                if "metadata" in data_section:
                    metadata.update(data_section["metadata"])
                
                doc = DocumentChunk(
                    chunk_text=chunk_text,
                    filename=filename,
                    file_id=str(uuid.uuid4()),
                    metadata=metadata
                )
                documents.append(doc)
            
            print(f"成功解析 {len(documents)} 个有效chunks")
            return documents
            
        except Exception as e:
            print(f"Failed to parse JSON file: {e}")
            raise HTTPException(status_code=400, detail=f"JSON解析失败: {str(e)}")
    
    def insert_documents(self, collection_name: str, documents: List[DocumentChunk]) -> List[str]:
        """
        批量插入文档到Collection
        参考milvus_kb_service.py的操作方式
        """
        if not documents:
            return []
        
        try:
            # 准备数据
            print(f"准备 {len(documents)} 个文档数据")
            
            chunk_texts = []
            filenames = []
            file_ids = []
            metadatas = []
            
            for doc in documents:
                chunk_texts.append(doc.chunk_text)
                filenames.append(doc.filename)
                file_ids.append(doc.file_id or str(uuid.uuid4()))
                metadatas.append(json.dumps(doc.metadata, ensure_ascii=False))
            
            # 批量生成embeddings
            print(f"批量生成embeddings")
            EMBED_BATCH_SIZE = 32
            embeddings = self.generate_embeddings_batch(chunk_texts, batch_size=EMBED_BATCH_SIZE)
            
            # 检测embedding维度
            embedding_dim = len(embeddings[0])
            print(f"检测到embedding维度: {embedding_dim}")
            
            # 创建或获取collection（会自动load）
            collection = self.create_or_get_collection(collection_name, embedding_dim)
            
            # 分批插入Milvus
            print(f"分批插入Milvus")
            MILVUS_BATCH_SIZE = 1000
            total_docs = len(documents)
            
            current_time = datetime.now().isoformat()
            
            for i in range(0, total_docs, MILVUS_BATCH_SIZE):
                end_idx = min(i + MILVUS_BATCH_SIZE, total_docs)
                
                # 准备当前批次数据 - 参考milvus_kb_service.py的entities格式
                entities = [
                    chunk_texts[i:end_idx],
                    filenames[i:end_idx],
                    file_ids[i:end_idx],
                    embeddings[i:end_idx],
                    metadatas[i:end_idx],
                    [current_time] * (end_idx - i)
                ]
                
                # 插入当前批次
                collection.insert(entities)
            
            print(f"插入完成，共 {len(file_ids)} 条文档")
            
            # 显式 flush + load，保证刚入库的数据能立即被统计、列表和检索接口看到
            try:
                collection.flush()
                collection.load()
                print("插入后已 flush 并重新加载 collection")
            except Exception as load_err:
                print(f"插入后 flush/load 警告: {load_err}")
            
            return file_ids
            
        except EmbeddingServiceError as e:
            print(f"插入文档失败，embedding 不可用: {e}")
            raise HTTPException(status_code=502, detail=f"Embedding 服务不可用: {str(e)}")
        except Exception as e:
            print(f"插入文档失败: {e}")
            raise HTTPException(status_code=500, detail=f"插入文档失败: {str(e)}")
    
    def search_by_text(self, collection_name: str, query_text: str, 
                      top_k: int = 10, filter_expr: Optional[str] = None) -> List[Dict]:
        """根据文本搜索相似文档"""
        try:
            if not utility.has_collection(collection_name):
                raise HTTPException(status_code=404, detail=f"知识库 {collection_name} 不存在")
            
            # 生成查询向量
            print(f"为查询文本生成embedding: {query_text[:50]}...")
            query_embedding = self.generate_embedding(query_text)
            
            collection = Collection(collection_name)
            
            # 参考milvus_kb_service: 确保collection已加载
            try:
                # 检查collection是否有索引（间接判断是否需要load）
                if not collection.has_index():
                    print(f"Collection '{collection_name}' 没有索引，正在加载...")
                    collection.load()
                else:
                    # 即使有索引，也尝试load以确保在内存中
                    collection.load()
                print(f"Collection '{collection_name}' 已确保加载")
            except Exception as load_err:
                print(f"加载collection时出错: {load_err}")
                # 尝试继续，可能已经加载
            
            search_params = {
                "metric_type": "COSINE",
                "params": {"nprobe": 10}
            }
            
            output_fields = ["chunk_text", "filename", "file_id", "metadata", "created_at"]
            
            print(f"执行向量搜索，top_k: {top_k}")
            results = collection.search(
                data=[query_embedding],
                anns_field="embedding",
                param=search_params,
                limit=top_k,
                expr=filter_expr,
                output_fields=output_fields
            )
            
            # 格式化结果
            formatted_results = []
            for hits in results:
                for hit in hits:
                    result = {
                        "id": hit.id,
                        "score": hit.score,
                        "chunk_text": hit.entity.get("chunk_text"),
                        "filename": hit.entity.get("filename"),
                        "file_id": hit.entity.get("file_id"),
                        "metadata": json.loads(hit.entity.get("metadata", "{}")),
                        "created_at": hit.entity.get("created_at")
                    }
                    formatted_results.append(result)
            
            print(f"搜索完成，找到 {len(formatted_results)} 个结果")
            return formatted_results
            
        except EmbeddingServiceError as e:
            print(f"搜索失败，embedding 不可用: {e}")
            raise HTTPException(status_code=502, detail=f"Embedding 服务不可用: {str(e)}")
        except Exception as e:
            print(f"搜索失败: {e}")
            import traceback
            print(f"详细错误: {traceback.format_exc()}")
            raise HTTPException(status_code=500, detail=f"搜索失败: {str(e)}")
    
    def search_by_filename(self, collection_name: str, filename: str, top_k: int = 10) -> List[Dict]:
        """根据文件名检索知识库内信息"""
        try:
            if not utility.has_collection(collection_name):
                raise HTTPException(status_code=404, detail=f"知识库 {collection_name} 不存在")
            
            collection = Collection(collection_name)
            
            # 确保collection已加载
            try:
                collection.load()
                print(f"Collection '{collection_name}' 已加载")
            except Exception as load_err:
                print(f"加载collection警告: {load_err}")
            
            # 构建查询表达式
            expr = f'filename == "{filename}"'
            print(f"根据文件名查询: {expr}")
            
            # 执行查询
            results = collection.query(
                expr=expr,
                limit=top_k,
                output_fields=["chunk_text", "filename", "file_id", "metadata", "created_at"]
            )
            
            # 格式化结果
            formatted_results = []
            for result in results:
                formatted_result = {
                    "id": result.get("id"),
                    "chunk_text": result.get("chunk_text"),
                    "filename": result.get("filename"),
                    "file_id": result.get("file_id"),
                    "metadata": json.loads(result.get("metadata", "{}")),
                    "created_at": result.get("created_at")
                }
                formatted_results.append(formatted_result)
            
            print(f"根据文件名 {filename} 找到 {len(formatted_results)} 个结果")
            return formatted_results
            
        except Exception as e:
            print(f"根据文件名检索失败: {e}")
            import traceback
            print(f"详细错误: {traceback.format_exc()}")
            raise HTTPException(status_code=500, detail=f"根据文件名检索失败: {str(e)}")

    def keyword_search_documents(
        self,
        query_text: str,
        collection_name: Optional[str] = None,
        top_k: int = 20
    ) -> List[Dict[str, Any]]:
        """基于关键词搜索文档内容和文件名，不依赖额外模型服务。"""
        try:
            normalized_query = query_text.strip()
            if not normalized_query:
                return []

            if collection_name:
                if not utility.has_collection(collection_name):
                    raise HTTPException(status_code=404, detail=f"知识库 {collection_name} 不存在")
                collection_names = [collection_name]
            else:
                collection_names = utility.list_collections()

            mappings = self.get_name_mapping()
            matched_results: List[Dict[str, Any]] = []

            for current_collection in collection_names:
                try:
                    collection = Collection(current_collection)
                    collection.load()

                    rows = collection.query(
                        expr="id > 0",
                        output_fields=["chunk_text", "filename", "file_id", "metadata", "created_at"],
                        limit=16384
                    )

                    collection_display_name = mappings.get(current_collection, {}).get(
                        "display_name",
                        current_collection
                    )

                    for row in rows:
                        chunk_text = row.get("chunk_text", "")
                        filename = row.get("filename", "")
                        matched = score_keyword_match(normalized_query, chunk_text, filename)

                        if not matched:
                            continue

                        metadata_raw = row.get("metadata", "{}")
                        try:
                            metadata = json.loads(metadata_raw)
                        except (TypeError, json.JSONDecodeError):
                            metadata = {}

                        matched_results.append({
                            "collection_id": current_collection,
                            "collection_name": collection_display_name,
                            "filename": filename,
                            "file_id": metadata.get("file_id", row.get("file_id")),
                            "chunk_text": chunk_text,
                            "snippet": matched["snippet"],
                            "score": matched["score"],
                            "match_type": matched["match_type"],
                            "matched_keywords": matched["matched_keywords"],
                            "metadata": metadata,
                            "created_at": row.get("created_at")
                        })

                except HTTPException:
                    raise
                except Exception as collection_err:
                    print(f"关键词检索知识库 {current_collection} 失败: {collection_err}")
                    continue

            matched_results.sort(
                key=lambda item: (item.get("score", 0), item.get("created_at", "")),
                reverse=True
            )

            if top_k > 0:
                matched_results = matched_results[:top_k]

            print(f"关键词检索完成，查询: '{normalized_query}'，命中 {len(matched_results)} 条结果")
            return matched_results

        except HTTPException:
            raise
        except Exception as e:
            print(f"关键词检索失败: {e}")
            import traceback
            print(f"详细错误: {traceback.format_exc()}")
            raise HTTPException(status_code=500, detail=f"关键词检索失败: {str(e)}")
    
    def delete_documents_by_filename(self, collection_name: str, filename: str) -> int:
        """根据文件名删除文档"""
        try:
            if not utility.has_collection(collection_name):
                raise HTTPException(status_code=404, detail=f"知识库 {collection_name} 不存在")
            
            collection = Collection(collection_name)
            
            # 删除前确保collection已加载
            try:
                collection.load()
            except Exception as load_err:
                print(f"加载collection警告: {load_err}")
            
            # 构建删除表达式
            expr = f'filename == "{filename}"'
            print(f"删除文件: {expr}")
            
            # 执行删除 - 参考milvus_kb_service.py，不调用flush
            collection.delete(expr)
            
            print(f"删除文件 {filename} 成功")
            return 1
            
        except Exception as e:
            print(f"删除失败: {e}")
            raise HTTPException(status_code=500, detail=f"删除失败: {str(e)}")
    
    def list_knowledge_bases(self) -> List[Dict[str, Any]]:
        """列出所有知识库，包含 display_name 和 pipeline_type。"""
        try:
            collection_ids = utility.list_collections()
            mappings = self.get_name_mapping()

            result = []
            for collection_id in collection_ids:
                mapping = mappings.get(collection_id, {})
                display_name = mapping.get("display_name", collection_id)
                pipeline_type = self.infer_pipeline_type(
                    collection_id,
                    display_name,
                    mapping.get("pipeline_type")
                )
                result.append({
                    "collection_id": collection_id,
                    "display_name": display_name,
                    "pipeline_type": pipeline_type,
                    "created_at": mapping.get("created_at", "")
                })

            return result
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"获取知识库列表失败: {str(e)}")

    def get_collection_stats(self, collection_id: str) -> Dict[str, Any]:
        """获取知识库统计信息"""
        try:
            if not utility.has_collection(collection_id):
                raise HTTPException(status_code=404, detail=f"知识库 {collection_id} 不存在")

            collection = Collection(collection_id)

            try:
                collection.load()
            except Exception as load_err:
                print(f"加载collection警告: {load_err}")

            total_chunks = collection.num_entities

            try:
                results = collection.query(
                    expr="id > 0",
                    output_fields=["filename", "created_at"],
                    limit=16384
                )

                unique_filenames = set()
                latest_update = None

                for result in results:
                    filename = result.get("filename")
                    if filename:
                        unique_filenames.add(filename)

                    created_at = result.get("created_at")
                    if created_at:
                        if latest_update is None or created_at > latest_update:
                            latest_update = created_at

                total_documents = len(unique_filenames)

            except Exception as query_err:
                print(f"查询统计信息失败: {query_err}")
                total_documents = 0
                latest_update = None

            mapping = self.get_name_mapping(collection_id)
            display_name = mapping.get("display_name", collection_id)
            pipeline_type = self.infer_pipeline_type(
                collection_id,
                display_name,
                mapping.get("pipeline_type")
            )

            return {
                "collection_id": collection_id,
                "collection_name": display_name,
                "pipeline_type": pipeline_type,
                "total_documents": total_documents,
                "total_chunks": total_chunks,
                "last_updated": latest_update
            }

        except Exception as e:
            print(f"获取统计信息失败: {e}")
            raise HTTPException(status_code=500, detail=f"获取统计信息失败: {str(e)}")

    def get_collection_documents(self, collection_id: str) -> List[Dict[str, Any]]:
        """获取知识库中的文档列表（按文件名去重）"""
        try:
            if not utility.has_collection(collection_id):
                raise HTTPException(status_code=404, detail=f"知识库 {collection_id} 不存在")

            collection = Collection(collection_id)

            # 确保collection已加载
            try:
                collection.load()
            except Exception as load_err:
                print(f"加载collection警告: {load_err}")

            # 查询所有记录
            try:
                results = collection.query(
                    expr="id > 0",
                    output_fields=["filename", "file_id", "metadata", "created_at"],
                    limit=16384
                )

                # 按文件名分组统计
                doc_stats = {}
                for result in results:
                    filename = result.get("filename")
                    if not filename:
                        continue

                    if filename not in doc_stats:
                        # 解析metadata获取额外信息
                        metadata_str = result.get("metadata", "{}")
                        try:
                            metadata = json.loads(metadata_str)
                        except:
                            metadata = {}

                        # 从metadata中提取实际的file_id（用于文件系统路径）
                        # metadata.file_id 是文件系统路径用的ID（如 file_20251016_d398cfa1）
                        # result.file_id 是Milvus中的UUID
                        actual_file_id = metadata.get("file_id", result.get("file_id"))

                        doc_stats[filename] = {
                            "filename": filename,
                            "file_id": actual_file_id,  # 使用metadata中的file_id
                            "chunks": 0,
                            "created_at": result.get("created_at"),
                            "metadata": metadata
                        }

                    doc_stats[filename]["chunks"] += 1

                # 转换为列表并排序（按创建时间倒序）
                documents = list(doc_stats.values())
                documents.sort(key=lambda x: x.get("created_at", ""), reverse=True)

                return documents

            except Exception as query_err:
                print(f"查询文档列表失败: {query_err}")
                return []

        except Exception as e:
            print(f"获取文档列表失败: {e}")
            raise HTTPException(status_code=500, detail=f"获取文档列表失败: {str(e)}")

    def get_all_stats(self) -> Dict[str, Any]:
        """获取所有知识库的汇总统计信息"""
        try:
            collections = utility.list_collections()

            total_collections = len(collections)
            total_documents = 0
            total_chunks = 0

            collection_details = []

            for collection_name in collections:
                try:
                    stats = self.get_collection_stats(collection_name)
                    total_documents += stats["total_documents"]
                    total_chunks += stats["total_chunks"]
                    collection_details.append(stats)
                except Exception as e:
                    print(f"获取 {collection_name} 统计信息失败: {e}")
                    continue

            return {
                "total_collections": total_collections,
                "total_documents": total_documents,
                "total_chunks": total_chunks,
                "collections": collection_details
            }

        except Exception as e:
            print(f"获取汇总统计失败: {e}")
            raise HTTPException(status_code=500, detail=f"获取汇总统计失败: {str(e)}")

# FastAPI 应用
app = FastAPI(title="Milvus RAG Service", version="2.0.0")

# 配置CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 允许所有来源，生产环境应该限制具体域名
    allow_credentials=True,
    allow_methods=["*"],  # 允许所有HTTP方法
    allow_headers=["*"],  # 允许所有headers
)

# 初始化Milvus服务
milvus_service = MilvusRAGService()

@app.post("/knowledge_base/create")
async def create_knowledge_base(display_name: str, pipeline_type: str = "vlm"):
    """创建知识库"""
    try:
        normalized_pipeline_type = normalize_pipeline_type(pipeline_type)
        collection_id, success = milvus_service.create_knowledge_base(
            display_name,
            pipeline_type=normalized_pipeline_type
        )

        if success:
            return {
                "status": "success",
                "message": f"知识库 '{display_name}' 创建成功",
                "collection_id": collection_id,
                "display_name": display_name,
                "pipeline_type": normalized_pipeline_type
            }
        else:
            return {
                "status": "error",
                "message": f"知识库创建失败"
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

class DeleteKBByIdRequest(BaseModel):
    collection_id: str

@app.delete("/knowledge_base/delete")
async def delete_knowledge_base(request: DeleteKBByIdRequest):
    """删除知识库"""
    try:
        success = milvus_service.delete_knowledge_base(request.collection_id)
        if success:
            return {"status": "success", "message": f"知识库删除成功"}
        else:
            return {"status": "not_found", "message": f"知识库不存在"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/knowledge_base/list")
async def list_knowledge_bases():
    """列出所有知识库"""
    try:
        kbs = milvus_service.list_knowledge_bases()
        return {"status": "success", "knowledge_bases": kbs}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/upload_json", response_model=UploadResponse)
async def upload_json_file(request: UploadKBRequest):
    """上传JSON文件到知识库"""
    try:
        # 解析JSON文件
        documents = milvus_service.parse_json_file(request.file_data)
        
        if not documents:
            raise HTTPException(status_code=400, detail="未找到有效的文档chunks")
        
        # 插入文档
        file_ids = milvus_service.insert_documents(request.collection_name, documents)
        
        # 获取文件名
        filename = request.file_data.get("filename", "unknown.txt")
        if filename.startswith("/"):
            filename = os.path.basename(filename)
        
        response = UploadResponse(
            filename=filename,
            file_id=documents[0].file_id if documents else str(uuid.uuid4()),
            status="success",
            message=f"文件上传成功，处理了{len(documents)}个chunks",
            chunks_count=len(documents)
        )
        
        return response
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/upload_json/v2", response_model=UploadResponse)
async def upload_json_v2(request: UploadV2Request):
    """上传 OCR 2.0 的 output.json 并入库。"""
    try:
        output_payload = request.output_json
        if isinstance(output_payload.get("data"), dict):
            output_payload = output_payload["data"]

        result_data = output_payload.get("results", {}).get(request.result_key, {})
        chunks = result_data.get("chunks", [])
        if not chunks:
            raise HTTPException(status_code=400, detail="V2 output_json 中未找到 chunks")

        file_data = {
            "filename": f"{request.result_key}.pdf",
            "data": {
                "chunks": chunks,
                "metadata": {
                    "file_id": request.file_id,
                    "knowledge_base_id": request.collection_name,
                    "total_chunks": len(chunks),
                    "pipeline_type": "ocr",
                    "source": "v2"
                }
            }
        }

        # 复用现有入库流程
        documents = milvus_service.parse_json_file(file_data)
        if not documents:
            raise HTTPException(status_code=400, detail="未找到有效的文档chunks")

        milvus_service.insert_documents(request.collection_name, documents)
        milvus_service.upsert_name_mapping(request.collection_name, pipeline_type="ocr")

        filename = file_data.get("filename", "unknown.txt")
        if filename.startswith("/"):
            filename = os.path.basename(filename)

        return UploadResponse(
            filename=filename,
            file_id=documents[0].file_id if documents else request.file_id,
            status="success",
            message=f"文件上传成功，处理了{len(documents)}个chunks",
            chunks_count=len(documents)
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/search")
async def search_documents(request: SearchRequest):
    """根据问题搜索相似文档"""
    try:
        results = milvus_service.search_by_text(
            collection_name=request.collection_name,
            query_text=request.query_text,
            top_k=request.top_k,
            filter_expr=request.filter_expr
        )
        
        return {
            "status": "success",
            "query": request.query_text,
            "results": results,
            "total": len(results)
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/search_keyword")
async def search_documents_by_keyword(request: KeywordSearchRequest):
    """基于关键词检索文档内容和文件名。"""
    try:
        results = milvus_service.keyword_search_documents(
            query_text=request.query_text,
            collection_name=request.collection_name,
            top_k=request.top_k
        )

        return {
            "status": "success",
            "query": request.query_text,
            "results": results,
            "total": len(results)
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/search_by_filename")
async def search_by_filename(request: SearchByFilenameRequest):
    """根据文件名检索知识库内信息"""
    try:
        results = milvus_service.search_by_filename(
            collection_name=request.collection_name,
            filename=request.filename,
            top_k=request.top_k
        )
        
        return {
            "status": "success",
            "filename": request.filename,
            "results": results,
            "total": len(results)
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/delete")
async def delete_documents(request: DeleteRequest):
    """删除文档"""
    try:
        deleted_count = milvus_service.delete_documents_by_filename(
            collection_name=request.collection_name,
            filename=request.filename
        )
        
        return {
            "status": "success",
            "message": f"已删除文件 {request.filename}",
            "deleted_count": deleted_count
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    """健康检查"""
    return {"status": "healthy", "service": "Milvus RAG Service"}

@app.get("/stats/collection/{collection_name}")
async def get_collection_stats(collection_name: str):
    """获取单个知识库的统计信息"""
    try:
        stats = milvus_service.get_collection_stats(collection_name)
        return {"status": "success", "data": stats}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/stats/all")
async def get_all_stats():
    """获取所有知识库的汇总统计信息"""
    try:
        stats = milvus_service.get_all_stats()
        return {"status": "success", "data": stats}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/knowledge_base/{collection_id}/documents")
async def get_knowledge_base_documents(collection_id: str):
    """获取知识库中的文档列表"""
    try:
        documents = milvus_service.get_collection_documents(collection_id)
        stats = milvus_service.get_collection_stats(collection_id)

        return {
            "status": "success",
            "collection_id": collection_id,
            "collection_name": stats["collection_name"],
            "pipeline_type": stats["pipeline_type"],
            "total_documents": stats["total_documents"],
            "total_chunks": stats["total_chunks"],
            "last_updated": stats["last_updated"],
            "documents": documents
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/document/{file_id}/details")
async def get_document_details(file_id: str):
    """获取文档的详细信息，包括PDF、Markdown、chunks等"""
    try:
        extraction_dir = find_extraction_dir(file_id)
        if extraction_dir is None:
            raise HTTPException(status_code=404, detail=f"文档 {file_id} 不存在")

        document_meta = load_document_metadata(extraction_dir)
        chunks_data = load_document_chunks(extraction_dir)
        markdown_content = load_document_markdown(extraction_dir, document_meta["filename"])

        # 查找PDF文件
        pdf_path = find_uploaded_pdf(file_id, document_meta["filename"])
        embedded_images = list_embedded_images(extraction_dir, file_id)
        visualization_images = list_visualization_images(file_id)

        return {
            "status": "success",
            "file_id": file_id,
            "filename": document_meta["filename"],
            "metadata": document_meta["metadata"],
            "pipeline_type": document_meta["pipeline_type"],
            "extraction_mode": document_meta["extraction_mode"],
            "extraction_time": document_meta["extraction_time"],
            "markdown": markdown_content,
            "chunks": chunks_data,
            "pdf_url": f"/document/{file_id}/pdf" if pdf_path else None,
            "embedded_images": embedded_images,
            "visualization_images": visualization_images,
            "total_chunks": len(chunks_data),
            "total_pages": document_meta["total_pages"],
            "total_images": document_meta["total_images"]
        }
    except HTTPException:
        raise
    except Exception as e:
        print(f"获取文档详情失败: {e}")
        raise HTTPException(status_code=500, detail=f"获取文档详情失败: {str(e)}")

@app.get("/document/{file_id}/pdf")
async def get_document_pdf(file_id: str):
    """直接返回PDF文件，Content-Disposition设置为inline以便浏览器内嵌显示"""
    try:
        extraction_dir = find_extraction_dir(file_id)
        if extraction_dir is None:
            raise HTTPException(status_code=404, detail="文档不存在")

        document_meta = load_document_metadata(extraction_dir)

        # 查找PDF文件
        pdf_path = find_uploaded_pdf(file_id, document_meta["filename"])

        if not pdf_path or not pdf_path.exists():
            raise HTTPException(status_code=404, detail="PDF文件不存在")

        # 返回PDF，设置为inline模式以便浏览器内嵌显示
        from fastapi.responses import Response
        from urllib.parse import quote
        with open(pdf_path, 'rb') as f:
            pdf_content = f.read()

        # URL encode the filename for proper handling of Chinese characters
        encoded_filename = quote(document_meta["filename"])

        return Response(
            content=pdf_content,
            media_type="application/pdf",
            headers={
                "Content-Disposition": f"inline; filename*=UTF-8''{encoded_filename}",
                "Cache-Control": "public, max-age=3600"
            }
        )
    except HTTPException:
        raise
    except Exception as e:
        print(f"获取PDF文件失败: {e}")
        raise HTTPException(status_code=500, detail=f"获取PDF文件失败: {str(e)}")

@app.get("/document/{file_id}/images/{image_name}")
async def get_document_image(file_id: str, image_name: str):
    """获取文档提取的图片"""
    try:
        # 图片路径
        extraction_dir = find_extraction_dir(file_id)
        if extraction_dir is None:
            raise HTTPException(status_code=404, detail="文档不存在")

        image_path = extraction_dir / "images" / image_name

        if image_path.exists():
            return FileResponse(
                path=str(image_path),
                media_type=guess_media_type(image_name)
            )

        result_data = load_primary_result_data(extraction_dir)
        images = result_data.get("images", {})
        if isinstance(images, dict):
            matched_key = next(
                (key for key in images.keys() if Path(key).name == image_name),
                None
            )
            if matched_key:
                try:
                    image_bytes = base64.b64decode(images[matched_key])
                except Exception as decode_err:
                    raise HTTPException(status_code=500, detail=f"图片解码失败: {decode_err}") from decode_err

                return Response(
                    content=image_bytes,
                    media_type=guess_media_type(image_name),
                    headers={"Cache-Control": "public, max-age=3600"}
                )

        raise HTTPException(status_code=404, detail="图片不存在")
    except HTTPException:
        raise
    except Exception as e:
        print(f"获取图片失败: {e}")
        raise HTTPException(status_code=500, detail=f"获取图片失败: {str(e)}")


@app.get("/document/{file_id}/visualizations/{image_name}")
async def get_document_visualization(file_id: str, image_name: str):
    """获取 OCR 可视化图片。"""
    try:
        visualization_dir = find_visualization_dir(file_id)
        if visualization_dir is None:
            raise HTTPException(status_code=404, detail="可视化目录不存在")

        image_path = visualization_dir / image_name
        if not image_path.exists():
            raise HTTPException(status_code=404, detail="可视化图片不存在")

        return FileResponse(
            path=str(image_path),
            media_type=guess_media_type(image_name),
            headers={"Cache-Control": "public, max-age=3600"}
        )
    except HTTPException:
        raise
    except Exception as e:
        print(f"获取可视化图片失败: {e}")
        raise HTTPException(status_code=500, detail=f"获取可视化图片失败: {str(e)}")

if __name__ == "__main__":
    host = os.getenv("SERVER_HOST", "0.0.0.0")
    port = int(os.getenv("SERVER_PORT", "8000"))
    
    print("\n" + "="*60)
    print("Starting Milvus RAG Service")
    print("="*60)
    print(f"Server: http://{host}:{port}")
    print(f"Docs: http://{host}:{port}/docs")
    print("="*60 + "\n")
    
    uvicorn.run(app, host=host, port=port)
