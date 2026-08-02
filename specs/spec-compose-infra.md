# Spec: Compose Infrastructure

| | |
|---|---|
| **Компонент** | Инфраструктура Docker Compose |
| **Файл** | `docker-compose.yml` |
| **Статус** | ✅ verified |
| **Проверено** | 2026-08-02 |

## 1. Назначение

Единая точка запуска всего стека: Hermes Gateway + Dashboard, SearXNG (метапоиск)
с Redis-совместимым кэшем Valkey, Mnemosyne (MCP-сервер памяти). Все контейнеры
в одной bridge-сети `hermes-net`, чтобы `hermes` обращался к сервисам по DNS-имени
контейнера, минуя host-порты.

## 2. Входы (переменные окружения compose)

| Переменная | Дефолт | Применение |
|------------|--------|------------|
| `HERMES_API_PORT` | `8642` | host-порт API Hermes |
| `HERMES_DASHBOARD_PORT` | `9119` | host-порт Dashboard |
| `API_SERVER_KEY` | (обязателен, из `./.env`; генерирует `setup.ps1`, 32 hex) | ключ API-сервера Hermes (env контейнера); без него `docker compose up` падает с ошибкой |
| `USERPROFILE` | `C:/Users/user` | bind-mount `~/.hermes` → `/opt/data` |
| `SEARXNG_HOST` | `127.0.0.1` | host-адрес публикации SearXNG |
| `SEARXNG_PORT` | `8080` | host-порт SearXNG |
| `MNEMOSYNE_PORT` | `127.0.0.1:8081` | host-адрес:порт Mnemosyne |
| `MNEMOSYNE_MCP_TOKEN` | (обязателен, из `./.env`) | токен MCP-аутентификации |

Сервисы: `hermes`, `searxng-core`, `searxng-valkey`, `mnemosyne`.
Сеть: `hermes-net` (bridge). Volume'ы: `searxng-cache`, `valkey-data`, `mnemosyne-data`.

## 3. Поведенческие сценарии

### SCN-COMPOSE-01: Четыре сервиса поднимаются в общей сети
**Given** Docker Desktop запущен и `./.env` содержит `MNEMOSYNE_MCP_TOKEN`
**When** `docker compose up -d` завершается успешно
**Then** существуют и работают контейнеры `hermes`, `searxng-core`, `searxng-valkey`, `mnemosyne`
**And** все четыре прикреплены к сети `hermes-net`

### SCN-COMPOSE-02: Hermes — gateway, а не интерактивный CLI
**Given** образ `nousresearch/hermes-agent:latest`
**When** контейнер стартует
**Then** команда контейнера — `["gateway", "run"]`
**And** конфиг смонтирован bind-mount'ом `~/.hermes` → `/opt/data` (без volume'а — иначе пустой конфиг)
**And** на host опубликованы `8642` (API) и `9119` (Dashboard) на `0.0.0.0`
**And** контейнер получает `API_SERVER_KEY` из `./.env` (32 hex, генерируется `setup.ps1`; известного дефолтного ключа нет)

### SCN-COMPOSE-03: SearXNG доступен только с loopback
**When** контейнер `searxng-core` запущен
**Then** порт опубликован как `127.0.0.1:8080` (не на LAN)
**And** `searxng-settings.yml` смонтирован в `/etc/searxng/settings.yml` read-only
**And** кэш лежит в volume `searxng-cache:/var/cache/searxng/`

### SCN-COMPOSE-04: Mnemosyne — loopback + healthcheck, терпящий SSE
**When** контейнер `mnemosyne` запущен
**Then** порт опубликован как `127.0.0.1:8081`
**And** healthcheck опрашивает `/sse` и считается успешным даже при exit code 28 (timeout — SSE-стрим не закрывается)
**And** данные лежат в volume `mnemosyne-data:/data`

### SCN-COMPOSE-05: Valkey — только внутренний кэш
**When** контейнер `searxng-valkey` запущен
**Then** порт `6379` не публикуется на host
**And** команда: `valkey-server --save 30 1 --loglevel warning`

## 4. Приёмочные критерии

| ID | Критерий | Проверка |
|----|----------|----------|
| C1 | Все 4 контейнера в списке `docker ps` | `docker ps --format '{{.Names}}'` |
| C2 | Все 4 в сети `hermes-net` | `docker inspect <name> --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'` |
| C3 | hermes публикует 8642 и 9119 на `0.0.0.0` | `docker port hermes` |
| C4 | searxng-core публикует только `127.0.0.1:8080` | `docker port searxng-core` |
| C5 | mnemosyne публикует только `127.0.0.1:8081` | `docker port mnemosyne` |
| C6 | Cmd hermes содержит `gateway run` | `docker inspect hermes --format '{{json .Config.Cmd}}'` |
| C7 | Bind-mount `~/.hermes` → `/opt/data` (rw) | `docker inspect hermes --format '{{range .Mounts}}{{.Source}}=>{{.Destination}}(rw={{.RW}}) {{end}}'` |
| C9 | settings.yml смонтирован read-only | `docker inspect searxng-core --format '{{range .Mounts}}...{{end}}'` |
| C10 | Контейнер hermes получает `API_SERVER_KEY` = 32 hex (не дефолт `change-me`) | `docker inspect hermes --format '{{range .Config.Env}}...{{end}}'` |

## 5. Верификация

```powershell
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
```

Все AC этого спека исполняются верификатором автоматически (ID C1–C7, C9, C10).
