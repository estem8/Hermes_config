# Spec: Mnemosyne Service (память)

| | |
|---|---|
| **Компонент** | Mnemosyne MCP-сервер + плагин Hermes |
| **Файлы** | `Dockerfile.mnemosyne`, `docker-compose.yml` (сервис `mnemosyne`), шаг 4 `setup.ps1` |
| **Статус** | ✅ verified |
| **Проверено** | 2026-08-08 |

## 1. Назначение

MCP-сервер персистентной памяти: контейнер на базе `python:3.12-slim` с пакетом
`mnemosyne-memory[mcp]`, слушает SSE на `0.0.0.0:8080`, данные — в `/data`
(named volume). Hermes получает клиентский плагин `mnemosyne-hermes`,
устанавливаемый в bind-mount `/opt/data/plugins/mnemosyne`.

## 2. Входы

**Образ** (`Dockerfile.mnemosyne`):

| Слой | Содержимое |
|------|------------|
| base | `python:3.12-slim` |
| pip | `mnemosyne-memory[mcp]` (без кэша) |
| apt | `sqlite3`, `curl` (диагностика; `--no-install-recommends`) |
| dirs | `mkdir -p /data` |
| ENV | `MNEMOSYNE_DATA_DIR=/data`, `MNEMOSYNE_MCP_TOKEN=` (пусто — заполняет compose из `./.env`) |
| CMD | `python -m mnemosyne.mcp_server --transport sse --host 0.0.0.0 --port 8080` |

**Compose-окружение**: `MNEMOSYNE_DATA_DIR=/data`, `MNEMOSYNE_MCP_TOKEN=${MNEMOSYNE_MCP_TOKEN}`.

## 3. Поведенческие сценарии

### SCN-MNEMO-01: MCP SSE без токена не отдаётся наружу
**Given** `MNEMOSYNE_MCP_TOKEN` задан в `./.env` и проброшен в контейнер
**When** сервер стартует на `0.0.0.0:8080`
**Then** без токена он отказывается биндить не-loopback адрес («Refusing to bind MCP SSE on non-loopback host ... without authentication»)
**And** на host сервис опубликован как `127.0.0.1:<MNEMOSYNE_PORT>` (дефолт 8081)

### SCN-MNEMO-02: Данные персистентны
**When** контейнер пересоздаётся (`docker compose up -d --force-recreate`)
**Then** память сохраняется в named volume `mnemosyne-data:/data` (`MNEMOSYNE_DATA_DIR=/data`)

### SCN-MNEMO-03: Healthcheck терпит SSE-стрим
**When** healthcheck выполняет `curl -s -o /dev/null --max-time 3 http://localhost:8080/sse`
**Then** exit 0 или 28 (timeout) считаются успехом — стрим не закрывается, 401 от собственного healthcheck — тоже здоровое поведение

### SCN-MNEMO-04: Плагин в Hermes
**Given** шаг 4 установщика выполнен
**Then** `mnemosyne-hermes` установлен pip'ом в venv Hermes и скопирован в `/opt/data/plugins/mnemosyne/`
**And** `memory.provider=mnemosyne` и `memory.memory_enabled=true` в config.yaml (шаг 4 повторно применяет флаг — gateway сбрасывает его в false при перезаписи конфига)
**And** `hermes memory status`: статус `available` (не `not available`)
**And** venv эфемерен: после `docker compose pull`/recreate `setup.ps1` (Update) переустанавливает `mnemosyne-hermes` — плагин-директория в bind-mount `/opt/data/plugins/` переживает, pip-пакеты — нет

## 4. Приёмочные критерии

| ID | Критерий | Проверка |
|----|----------|----------|
| M1 | Контейнер `mnemosyne` healthy | `docker inspect mnemosyne --format '{{.State.Health.Status}}'` |
| M2 | TCP-порт из `MNEMOSYNE_PORT` (дефолт 8081) на localhost открыт | TCP-проба |
| M3 | В env контейнера есть непустой `MNEMOSYNE_MCP_TOKEN` | `docker inspect mnemosyne --format '{{range .Config.Env}}{{.}}|{{end}}'` |
| M4 | В env контейнера есть `MNEMOSYNE_DATA_DIR=/data` | то же |
| M5 | `/opt/data/plugins/mnemosyne/` в контейнере непуст | `docker exec hermes ls /opt/data/plugins/mnemosyne/` |

## 5. Верификация

```powershell
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
```

Все AC (M1–M5) исполняются автоматически.
