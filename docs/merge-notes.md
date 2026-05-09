# Merge Notes

## Batch 1
- Initialized fusion workspace from 1_RAG—VLM base.
- Imported OCR-side standalone modules: ocr_v2_extractors, deepseekocr, paddleocr.

## Batch 2
- Applied PATCH-EXTRACT-001 baseline by replacing fusion extraction service with OCR V2-capable unified service and normalizing fallback paths to fusion output directories.
- Added fusion OCR modules: ocr_v2_extractors, deepseekocr, paddleocr.
- Added fusion Text_segmentation/markdown_chunker_v2.py copied from OCR project.
- Applied PATCH-CHUNK-001 baseline to fusion markdown_chunker_api.py with V2 methods and /chunk/v2 route.
- Applied PATCH-MILVUS-001 baseline to fusion milvus_api.py by adding /upload_json/v2 while preserving existing VLM search/document endpoints.
- Added fusion frontend src/api/config.ts from OCR project.
- Wired minimal V1/V2 mode skeleton into fusion frontend: App, Sidebar, Dashboard, KnowledgeBaseDetail, UploadDialog, Chat.
- Added temporary _v2-based knowledge-base filtering in frontend as an interim compatibility step.
- Validated backend module imports under vlm_rag310: unified_pdf_extraction_service, ocr_v2_extractors, markdown_chunker_api, markdown_chunker_v2, milvus_api.
- Validated frontend TypeScript compilation after minimal mode-switch integration.

## Batch 3
- Replaced temporary `_v2` knowledge-base naming dependence with explicit `pipeline_type` metadata in Milvus collection mappings and API responses.
- Extended `knowledge_base/create` to accept `pipeline_type`, and ensured `upload_json/v2` backfills OCR pipeline metadata.
- Normalized OCR sidecar defaults to localhost and fusion-local visualization directories via backend `.env` and `ocr_v2_extractors.py`.
- Updated startup scripts to prefer active env, then `vlm_rag310`, then `vlm_rag`.
- Updated frontend mode filtering to use `pipeline_type` in KnowledgeBase, UploadDialog, Chat, Dashboard, and RetrievalTest.
- Removed remaining frontend hardcoded Milvus URLs in KnowledgeBaseDetail and DocumentViewer.
- Added V1/V2-compatible document artifact loading in Milvus API for metadata, markdown, chunks, and uploaded PDFs.
- Added explicit `flush + load` after Milvus inserts so new V2 documents are visible immediately in stats and list views.
- Validated OCR sample ingest without frontend: create OCR KB -> `upload_json/v2` -> list/doc detail readback -> cleanup.
- Fixed `/chunk/v2` response contract to return raw `output_json`, while keeping Milvus/extraction services backward-compatible with wrapped `data` payloads.
- Verified stable background service startup in this environment by switching backend startup to `setsid`-based detachment and hardening `test_services.sh`.
- Validated real HTTP OCR chain with sample assets: `knowledge_base/create` -> `/chunk/v2` -> `/upload_json/v2` -> `/knowledge_base/{id}/documents` -> `/document/{file_id}/details` -> `/search_keyword`.
- Validated OCR KB can be consumed by retrieval and chat services over HTTP: `/search` returns OCR document, `/chat` returns grounded answer with one source document.
- Corrected upload API workflow semantics so partial failures (for example upload succeeds but OCR extraction fails) now return `success=false` with stage-specific messages instead of falsely reporting full success.
- Probed `/api/v2/files/upload` against live services and confirmed the remaining blocker is external OCR sidecar availability (`localhost:10010` MinerU endpoint connection refused), not fusion-chain logic.
