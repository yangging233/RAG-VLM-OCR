#!/usr/bin/env python3
"""
OCR V2 pipeline smoke test.

执行流程：
1. 健康检查
2. 创建 OCR 知识库
3. 调用 /api/v2/files/upload
4. 校验文档列表与详情
5. 调用 /search
6. 可选调用 /chat
7. 清理测试知识库
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, Optional
from urllib.parse import urlparse

import requests


BACKEND_ROOT = Path(__file__).resolve().parent
DEFAULT_PDF_PATH = BACKEND_ROOT / "data" / "test.pdf"
ENV_PATH = BACKEND_ROOT / ".env"


class SmokeTestError(RuntimeError):
    """Smoke test failure."""


def load_simple_env(env_path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    if not env_path.exists():
        return values

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or "=" not in raw_line:
            continue

        key, raw_value = raw_line.split("=", 1)
        key = key.strip()
        value = raw_value.strip()
        if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        values[key] = value

    return values


def print_step(title: str):
    print(f"\n[{title}]")


def require(condition: bool, message: str):
    if not condition:
        raise SmokeTestError(message)


def ensure_status(response: requests.Response, step: str) -> Dict[str, Any]:
    try:
        payload = response.json()
    except ValueError as exc:
        raise SmokeTestError(f"{step} 返回了非 JSON 响应: {response.text[:300]}") from exc

    if response.status_code != 200:
        detail = payload if isinstance(payload, dict) else response.text[:300]
        raise SmokeTestError(f"{step} 失败: HTTP {response.status_code}, 响应={detail}")

    return payload


def build_default_llm_config(chat_base_url: str, timeout: int) -> Optional[Dict[str, Any]]:
    try:
        response = requests.get(f"{chat_base_url}/config/default", timeout=timeout)
        payload = ensure_status(response, "获取默认 LLM 配置")
    except Exception as exc:
        raise SmokeTestError(f"无法读取 chat 默认配置: {exc}") from exc

    config = payload.get("config", {}).get("llm", {})
    if not config.get("api_url") or not config.get("model_name"):
        return None

    return {
        "api_url": config.get("api_url"),
        "api_key": config.get("api_key", ""),
        "model_name": config.get("model_name"),
        "temperature": config.get("temperature", 0.2),
        "max_tokens": config.get("max_tokens", 512),
    }


def probe_http_status(url: str, timeout: int) -> Optional[int]:
    try:
        response = requests.get(url, timeout=timeout)
        return response.status_code
    except requests.RequestException:
        return None


def resolve_sidecar_target(extraction_mode: str, env_values: Dict[str, str]) -> tuple[str, str, Optional[str]]:
    if extraction_mode == "mineru":
        return "MinerU", env_values.get("MINERU_API_URL", "http://localhost:10010/file_parse"), None
    if extraction_mode in {"paddleocr", "paddleocr_vl"}:
        return "PaddleOCR-VL", env_values.get("PADDLEOCR_VL_API_URL", "http://localhost:8802/parse"), "/health"
    if extraction_mode == "deepseek":
        return "DeepSeek OCR", env_values.get("DEEPSEEK_OCR_API_URL", "http://localhost:8705/v1/ocr/pdf"), "/health"
    raise SmokeTestError(f"未知 extraction_mode: {extraction_mode}")


def preflight_ocr_sidecar(extraction_mode: str, timeout: int, env_values: Dict[str, str]):
    service_name, api_url, explicit_health_path = resolve_sidecar_target(extraction_mode, env_values)
    parsed = urlparse(api_url)
    host = parsed.hostname or "localhost"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    base_url = f"{parsed.scheme or 'http'}://{host}:{port}"

    print_step(f"预检 OCR sidecar ({service_name})")

    candidates = []
    if explicit_health_path:
        candidates.append((f"{service_name} health", f"{base_url}{explicit_health_path}"))
    if extraction_mode == "mineru":
        candidates.append((f"{service_name} root", f"{base_url}/"))

    for label, url in candidates:
        status = probe_http_status(url, timeout)
        if status == 200:
            print(f"  - {label}: OK ({url})")
            return
        if status is not None:
            print(f"  - {label}: HTTP {status} ({url})")
        else:
            print(f"  - {label}: unavailable ({url})")

    try:
        import socket
        with socket.create_connection((host, port), timeout=3):
            print(f"  - TCP: reachable ({host}:{port})")
            if extraction_mode == "mineru":
                print("  - MinerU 无统一 /health 端点，允许使用 TCP 可达作为回退依据")
                return
    except OSError:
        pass

    raise SmokeTestError(
        f"{service_name} sidecar 不可用: api_url={api_url}。"
        f" 请先启动对应服务，或切换到可用的 extraction_mode。"
    )


def iter_health_targets(args: argparse.Namespace) -> Iterable[tuple[str, str]]:
    yield "pdf_extraction", f"{args.pdf_api}/health"
    yield "chunker", f"{args.chunk_api}/health"
    yield "milvus_api", f"{args.milvus_api}/health"
    if not args.skip_chat:
        yield "chat", f"{args.chat_api}/health"


def smoke_test(args: argparse.Namespace) -> None:
    session = requests.Session()
    collection_id: Optional[str] = None
    env_values = load_simple_env(ENV_PATH)

    print_step("健康检查")
    for service_name, url in iter_health_targets(args):
        response = session.get(url, timeout=args.timeout)
        if response.status_code != 200:
            raise SmokeTestError(f"{service_name} 健康检查失败: HTTP {response.status_code} @ {url}")
        print(f"  - {service_name}: OK ({url})")

    pdf_path = Path(args.pdf_path).expanduser().resolve()
    require(pdf_path.exists(), f"测试 PDF 不存在: {pdf_path}")
    if not args.skip_ocr_preflight:
        preflight_ocr_sidecar(args.extraction_mode, args.timeout, env_values)

    display_name = args.display_name or f"ocr_smoke_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"

    try:
        print_step("创建 OCR 知识库")
        create_response = session.post(
            f"{args.milvus_api}/knowledge_base/create",
            params={"display_name": display_name, "pipeline_type": "ocr"},
            timeout=args.timeout,
        )
        create_payload = ensure_status(create_response, "创建知识库")
        require(create_payload.get("status") == "success", f"创建知识库返回异常: {create_payload}")
        collection_id = create_payload.get("collection_id")
        require(bool(collection_id), f"创建知识库未返回 collection_id: {create_payload}")
        print(f"  - collection_id: {collection_id}")

        print_step("执行 V2 上传")
        with pdf_path.open("rb") as fh:
            upload_response = session.post(
                f"{args.pdf_api}/api/v2/files/upload",
                files={"file": (pdf_path.name, fh, "application/pdf")},
                data={
                    "knowledge_base_id": collection_id,
                    "auto_extract": "true",
                    "extraction_mode": args.extraction_mode,
                    "auto_chunk": "true",
                    "chunking_method": args.chunking_method,
                    "chunk_size": str(args.chunk_size),
                    "chunk_overlap": str(args.chunk_overlap),
                    "max_page_span": str(args.max_page_span),
                },
                timeout=args.upload_timeout,
            )
        upload_payload = ensure_status(upload_response, "V2 上传")
        require(upload_payload.get("success") is True, f"V2 上传失败: {upload_payload}")

        upload_data = upload_payload.get("data") or {}
        file_info = upload_data.get("file") or {}
        extraction_info = upload_data.get("extraction") or {}
        chunking_info = upload_data.get("chunking") or {}
        storage_info = upload_data.get("storage") or {}

        file_id = file_info.get("file_id")
        require(bool(file_id), f"上传响应缺少 file_id: {upload_payload}")
        require(extraction_info.get("status") == "completed", f"抽取未完成: {extraction_info}")
        require(chunking_info.get("status") == "completed", f"切分未完成: {chunking_info}")
        require(storage_info.get("status") == "completed", f"入库未完成: {storage_info}")
        require((chunking_info.get("total_chunks") or 0) > 0, f"切分结果为空: {chunking_info}")
        print(f"  - file_id: {file_id}")
        print(f"  - total_chunks: {chunking_info.get('total_chunks')}")

        print_step("校验文档列表")
        docs_response = session.get(
            f"{args.milvus_api}/knowledge_base/{collection_id}/documents",
            timeout=args.timeout,
        )
        docs_payload = ensure_status(docs_response, "获取知识库文档列表")
        documents = docs_payload.get("documents") or []
        require(bool(documents), f"知识库文档列表为空: {docs_payload}")
        require(
            any(doc.get("file_id") == file_id for doc in documents),
            f"文档列表中未找到 file_id={file_id}: {documents}"
        )
        print(f"  - documents: {len(documents)}")

        print_step("校验文档详情")
        detail_response = session.get(
            f"{args.milvus_api}/document/{file_id}/details",
            timeout=args.timeout,
        )
        detail_payload = ensure_status(detail_response, "获取文档详情")
        require(detail_payload.get("status") == "success", f"文档详情返回异常: {detail_payload}")
        require((detail_payload.get("total_chunks") or 0) > 0, f"文档详情 total_chunks 异常: {detail_payload}")
        require(bool(detail_payload.get("markdown")), "文档详情 markdown 为空")
        print(f"  - total_pages: {detail_payload.get('total_pages')}")
        print(f"  - total_chunks: {detail_payload.get('total_chunks')}")

        print_step("执行语义检索")
        search_response = session.post(
            f"{args.milvus_api}/search",
            json={
                "collection_name": collection_id,
                "query_text": args.query,
                "top_k": args.top_k,
            },
            timeout=args.timeout,
        )
        search_payload = ensure_status(search_response, "语义检索")
        search_results = search_payload.get("results") or []
        require(bool(search_results), f"语义检索为空: {search_payload}")
        print(f"  - results: {len(search_results)}")
        print(f"  - top filename: {search_results[0].get('filename')}")

        if not args.skip_chat:
            print_step("执行问答")
            llm_config = build_default_llm_config(args.chat_api, args.timeout)
            require(llm_config is not None, "默认 LLM 配置为空，无法执行 /chat")
            chat_response = session.post(
                f"{args.chat_api}/chat",
                json={
                    "query": args.query,
                    "collection_name": collection_id,
                    "llm_config": llm_config,
                    "top_k": args.top_k,
                    "score_threshold": args.score_threshold,
                    "use_reranker": False,
                    "stream": False,
                    "return_source": True,
                    "milvus_api_url": args.milvus_api,
                },
                timeout=args.chat_timeout,
            )
            chat_payload = ensure_status(chat_response, "问答")
            require(chat_payload.get("success") is True, f"/chat 失败: {chat_payload}")
            answer = (chat_payload.get("answer") or "").strip()
            require(bool(answer), f"/chat 返回空答案: {chat_payload}")
            print(f"  - answer preview: {answer[:120]}")

        print_step("Smoke Test 完成")
        print("  - OCR V2 主链路可用")
        print(f"  - collection_id: {collection_id}")
        print(f"  - file_id: {file_id}")

    finally:
        if collection_id and not args.keep_kb:
            print_step("清理测试知识库")
            try:
                delete_response = session.delete(
                    f"{args.milvus_api}/knowledge_base/delete",
                    json={"collection_id": collection_id},
                    timeout=args.timeout,
                )
                if delete_response.status_code == 200:
                    print(f"  - deleted: {collection_id}")
                else:
                    print(f"  - cleanup failed: HTTP {delete_response.status_code} {delete_response.text[:300]}")
            except Exception as exc:
                print(f"  - cleanup exception: {exc}")


def parse_args() -> argparse.Namespace:
    default_chat_url = "http://localhost:8501"
    parser = argparse.ArgumentParser(description="Run OCR V2 smoke test against fusion backend services.")
    parser.add_argument("--pdf-api", default="http://localhost:8006", help="PDF extraction service base URL")
    parser.add_argument("--chunk-api", default="http://localhost:8001", help="Chunk service base URL")
    parser.add_argument("--milvus-api", default="http://localhost:8000", help="Milvus API base URL")
    parser.add_argument("--chat-api", default=default_chat_url, help="Chat API base URL")
    parser.add_argument("--pdf-path", default=str(DEFAULT_PDF_PATH), help="PDF file used for upload")
    parser.add_argument("--display-name", default="", help="Knowledge base display name override")
    parser.add_argument("--query", default="请用一句话总结这份文档的核心内容。", help="Smoke test retrieval query")
    parser.add_argument("--top-k", type=int, default=3, help="Retrieval top_k")
    parser.add_argument("--score-threshold", type=float, default=0.0, help="Chat score threshold")
    parser.add_argument("--timeout", type=int, default=30, help="Default HTTP timeout in seconds")
    parser.add_argument("--upload-timeout", type=int, default=300, help="Upload timeout in seconds")
    parser.add_argument("--chat-timeout", type=int, default=180, help="Chat timeout in seconds")
    parser.add_argument(
        "--extraction-mode",
        default="mineru",
        choices=["mineru", "deepseek", "paddleocr", "paddleocr_vl"],
        help="OCR extraction mode",
    )
    parser.add_argument("--chunking-method", default="ocr_aware", choices=["ocr_aware", "layout_based"], help="V2 chunking method")
    parser.add_argument("--chunk-size", type=int, default=1500, help="Chunk size")
    parser.add_argument("--chunk-overlap", type=int, default=200, help="Chunk overlap")
    parser.add_argument("--max-page-span", type=int, default=3, help="Max page span")
    parser.add_argument("--skip-ocr-preflight", action="store_true", help="Skip OCR sidecar preflight")
    parser.add_argument("--skip-chat", action="store_true", help="Skip /chat verification")
    parser.add_argument("--keep-kb", action="store_true", help="Keep the created knowledge base for debugging")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        smoke_test(args)
        return 0
    except SmokeTestError as exc:
        print(f"\n[FAILED] {exc}", file=sys.stderr)
        return 1
    except requests.RequestException as exc:
        print(f"\n[FAILED] 网络请求异常: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
