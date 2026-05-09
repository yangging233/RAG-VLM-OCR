#!/usr/bin/env python3
"""
Mock MinerU API

用于在本机缺少真实 MinerU 运行条件时，复用已知样例输出，
验证融合链路 `/api/v2/files/upload -> /chunk/v2 -> /upload_json/v2`。
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
from typing import Any, Dict, List

import uvicorn
from fastapi import FastAPI, File, Form, UploadFile


HOST = os.getenv("MOCK_MINERU_HOST", "0.0.0.0")
PORT = int(os.getenv("MOCK_MINERU_PORT", "10010"))
DEFAULT_SAMPLE_OUTPUT = Path(
    os.getenv(
        "MOCK_MINERU_SAMPLE_OUTPUT",
        "/root/Agent-Project-Collection/cases/3_RAG—OCR/Multimodal_RAG_OCR/backend/output/"
        "extraction_results/a6d62b6a-6361-4a75-b56c-d811ff5ccc1a/mineru_output.json",
    )
)

app = FastAPI(title="Mock MinerU API", version="1.0.0")


def load_sample_output() -> Dict[str, Any]:
    with open(DEFAULT_SAMPLE_OUTPUT, "r", encoding="utf-8") as f:
        return json.load(f)


def build_result_for_filename(sample_payload: Dict[str, Any], filename: str) -> Dict[str, Any]:
    file_stem = Path(filename).stem
    sample_results = sample_payload.get("results", {})
    first_key = next(iter(sample_results.keys()))
    result = copy.deepcopy(sample_results[first_key])
    return {
        "backend": sample_payload.get("backend", "pipeline"),
        "version": sample_payload.get("version", "2.5.4"),
        "results": {
            file_stem: result,
        },
    }


@app.get("/")
async def root() -> Dict[str, Any]:
    return {
        "status": "ok",
        "service": "mock-mineru-api",
        "sample_output": str(DEFAULT_SAMPLE_OUTPUT),
    }


@app.post("/file_parse")
async def file_parse(
    files: List[UploadFile] = File(...),
    output_dir: str = Form("./output"),
    lang_list: str = Form("ch"),
    backend: str = Form("pipeline"),
    parse_method: str = Form("auto"),
    formula_enable: bool = Form(True),
    table_enable: bool = Form(True),
    server_url: str | None = Form(None),
    return_md: bool = Form(True),
    return_middle_json: bool = Form(True),
    return_model_output: bool = Form(True),
    return_content_list: bool = Form(True),
    start_page_id: int = Form(0),
    end_page_id: int = Form(99999),
) -> Dict[str, Any]:
    del output_dir
    del lang_list
    del backend
    del parse_method
    del formula_enable
    del table_enable
    del server_url
    del return_md
    del return_middle_json
    del return_model_output
    del return_content_list
    del start_page_id
    del end_page_id

    sample_payload = load_sample_output()

    merged_results: Dict[str, Any] = {}
    for upload_file in files:
        filename = upload_file.filename or "unnamed.pdf"
        await upload_file.read()
        payload = build_result_for_filename(sample_payload, filename)
        merged_results.update(payload["results"])

    return {
        "backend": sample_payload.get("backend", "pipeline"),
        "version": sample_payload.get("version", "2.5.4"),
        "results": merged_results,
    }


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
