# Repository Guidelines

## Project Structure & Module Organization
`frontend/` contains the Vite + React + TypeScript UI. Use `main.tsx` and `App.tsx` as entrypoints, keep feature screens in `components/`, shared settings in `src/config.ts`, and styles in `styles/` plus `tailwind.config.ts`.

`backend/` contains the Python services and support scripts. Main services are `Information-Extraction/unified/unified_pdf_extraction_service.py`, `Text_segmentation/markdown_chunker_api.py`, `Database/milvus_server/milvus_api.py`, and `chat/kb_chat.py`. Additional API variants live in `knowledge-base-api/`, `fastapi-document-retrieval/`, and `knowledge-management/`.

Treat `backend/logs/`, `backend/pids/`, `backend/output/`, `backend/data/`, and local database volume folders as runtime artifacts, not source files.

## Build, Test, and Development Commands
Frontend:

- `cd frontend && npm install` installs UI dependencies.
- `cd frontend && npm run dev` starts the local Vite server on port `5173`.
- `cd frontend && npm run build` runs TypeScript checks and creates a production build.
- `cd frontend && npm run lint` runs ESLint for `.ts` and `.tsx` files.

Backend:

- `cd backend && pip install -r requirements.txt` installs shared Python dependencies.
- `cd backend && ./start_all_services.sh` starts the four core backend services. These scripts are Bash-oriented and work best in Linux, macOS, or WSL.
- `cd backend && ./status_services.sh` or `./test_services.sh` checks service health.
- `cd backend/knowledge-base-api && pytest` and `cd backend/fastapi-document-retrieval && pytest` run the committed API tests.

## Coding Style & Naming Conventions
Use 2-space indentation in TypeScript/TSX and 4 spaces in Python. Keep React components in PascalCase files such as `KnowledgeBaseDetail.tsx`; use camelCase for hooks and helpers. In Python, prefer `snake_case` modules and functions, and keep route, service, and storage concerns separated.

## Testing Guidelines
Backend tests use `pytest` with `fastapi.testclient`. Name files `test_*.py` and write behavior-focused cases such as `test_search_no_results`. When changing endpoints or schemas, update the nearest service test package. No frontend test runner is configured here, so `npm run lint` plus a manual UI smoke test is the minimum bar.

## Commit & Pull Request Guidelines
This workspace snapshot does not include a `.git` directory, so commit history cannot be inspected locally. Follow concise, imperative commit messages with a scope prefix, for example `frontend: fix upload dialog state` or `backend: add Milvus health check`.

Pull requests should summarize affected services, list `.env` or port changes, include verification commands, and attach frontend screenshots when relevant.

## Security & Configuration Tips
Keep secrets in local `.env` files only. Do not commit API keys, absolute machine-specific paths, or generated logs. If you change service URLs, ports, or model endpoints, update `部署文档.md` in the same change.
