# Spec: Hermes Service (Gateway + конфигурация + Desktop)

| | |
|---|---|
| **Компонент** | Hermes Gateway |
| **Файлы** | `docker-compose.yml` (сервис `hermes`), `~/.hermes/.env`, `~/.hermes/config.yaml`, `%APPDATA%\hermes\connection.json` |
| **Статус** | ✅ verified |
| **Проверено** | 2026-08-02 |

## 1. Назначение

Контейнер Hermes работает как gateway (API + Dashboard), держит конфигурацию
в bind-mount'е `~/.hermes:/opt/data`, использует SearXNG как веб-поиск и Mnemosyne
как провайдера памяти. Hermes Desktop подключается к нему как к remote gateway.

## 2. Входы

**`~/.hermes/.env`** (пишет setup.ps1, шаг 2):

| Переменная | Формат/значение | Назначение |
|------------|-----------------|------------|
| `<PROVIDER>_API_KEY` | `sk-...` / `AIza...` | ключ LLM-провайдера |
| `SEARXNG_URL` | `http://searxng-core:8080` | DNS-имя контейнера в `hermes-net` |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `admin` | логин дашборда |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | 16 alnum | пароль дашборда |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | 44 alnum + `==` | секрет подписи сессий |

**`~/.hermes/config.yaml`** — гарантируется шагом 2 установщика; gateway при
миграциях дополняет файл сам (`_config_version`, `agent`, `plugins` — системные,
спеком не владеются):

| Ключ | Гарантированное значение |
|------|--------------------------|
| `model.default` | `<provider>/<model>` |
| `model.provider` | `<provider>` |
| `web.search_backend` | `searxng` |
| `memory.memory_enabled` | `true` |
| `memory.provider` | `mnemosyne` |
| `terminal.backend` | `local` |
| `approvals.mode` | `smart` |
| `display.language` | `ru` |
| `display.show_cost` | `true` |

## 3. Поведенческие сценарии

### SCN-HERMES-01: Веб-поиск через SearXNG по DNS-имени
**Given** `SEARXNG_URL=http://searxng-core:8080` в `~/.hermes/.env` и `web.search_backend=searxng` в config.yaml
**When** агент вызывает `web_search`
**Then** запрос уходит на `searxng-core:8080` внутри сети `hermes-net` (контейнер-контейнер, без host-портов)
**And** провайдер search-only (`supports_extract=False`) — `web_extract` отдельным провайдером не покрывается

### SCN-HERMES-02: Память через Mnemosyne MCP
**Given** `memory.provider=mnemosyne`, `memory.memory_enabled=true` и плагин в `/opt/data/plugins/mnemosyne/`
**When** агент читает/пишет память
**Then** `hermes memory status` показывает mnemosyne active
**And** плагин переживает пересоздание контейнера (лежит в bind-mount `~/.hermes/plugins/mnemosyne`)

### SCN-HERMES-03: API и Dashboard за basic auth
**Given** env-переменные `HERMES_DASHBOARD_BASIC_AUTH_*`
**When** запрос `GET http://localhost:9119/api/status` с заголовком `Authorization: Basic base64(admin:<pass>)`
**Then** ответ 200 с полем `version`
**And** API-сервер слушает 8642 (env `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, `API_SERVER_KEY=<32 hex>`)

### SCN-HERMES-04: Desktop подключается как remote gateway
**Given** `%APPDATA%\hermes\connection.json` записан установщиком
**Then** `mode=remote`, `remote.url=http://localhost:9119`, `remote.authMode=oauth` (см. комментарий в шаге 6 `setup.ps1`: не-oauth нормализуется Desktop в token-auth и не проходит WebSocket-аутентификацию)
**And** Desktop подключается к контейнеру через host-порт 9119

## 4. Приёмочные критерии

| ID | Критерий | Проверка |
|----|----------|----------|
| H1 | `~/.hermes/.env` содержит `SEARXNG_URL=http://searxng-core:8080` | чтение файла |
| H2 | `~/.hermes/.env` содержит `HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin` и непустой пароль | чтение файла |
| H3 | config.yaml: `search_backend: searxng` | чтение файла |
| H4 | config.yaml: `memory_enabled: true` и `provider: mnemosyne` | чтение файла |
| H5 | `~/.hermes/plugins/mnemosyne/` существует (bind-mount) | `Test-Path` |
| H6 | `GET /api/status` на 9119 с basic auth → 200 + version | `Invoke-RestMethod` |
| H7 | `hermes memory status` содержит `mnemosyne...active` | `docker exec hermes hermes memory status` |
| H8 | `connection.json`: mode=remote, url=localhost:9119, authMode=oauth | чтение JSON |

## 5. Верификация

```powershell
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
```

Все AC (H1–H8) исполняются автоматически. Пароль для H6 скрипт читает из
`credentials.txt` (fallback: `~/.hermes/.env`) и не печатает.
