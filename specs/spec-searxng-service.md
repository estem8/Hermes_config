# Spec: SearXNG Service (метапоиск)

| | |
|---|---|
| **Компонент** | SearXNG + Valkey |
| **Файлы** | `docker-compose.yml` (сервисы `searxng-core`, `searxng-valkey`), `searxng-settings.yml`, `.env.searxng` |
| **Статус** | ✅ verified |
| **Проверено** | 2026-08-02 |

## 1. Назначение

Приватный метапоиск для Hermes: `searxng-core` отдаёт JSON-результаты по
`format=json`, кэширует через `searxng-valkey`, слушает только loopback.
Конфиг — минимальный оверрайд поверх `use_default_settings: true`.

## 2. Входы

**`searxng-settings.yml`**:

| Ключ | Значение | Назначение |
|------|----------|------------|
| `use_default_settings` | `true` | официальные движки/настройки по умолчанию |
| `server.secret_key` | `$SEARXNG_SECRET_PLACEHOLDER` → реальный (шаг 2 setup) | подпись сессий |
| `server.image_proxy` | `true` | проксирование картинок |
| `search.formats` | `html, json, csv, rss` | **без `json` JSON-API отдаёт 403** (требование Hermes-провайдера) |

**`.env.searxng`** (env_file сервиса): `SEARXNG_HOST=127.0.0.1`, `SEARXNG_PORT=8080`.

## 3. Поведенческие сценарии

### SCN-SEARXNG-01: JSON-API доступен
**Given** `search.formats` включает `json`
**When** `GET http://localhost:8080/search?q=test&format=json`
**Then** ответ HTTP 200 с JSON-результатами
**And** без `json` в formats тот же запрос возвращает werkzeug 403 (это НЕ лимитер)

### SCN-SEARXNG-02: Кэш через Valkey
**Given** сервис `searxng-valkey` (образ `valkey/valkey:9-alpine`)
**When** SearXNG обращается к кэшу
**Then** данные сохраняются в volume `valkey-data:/data` с политикой `--save 30 1`
**And** порт 6379 на host не публикуется (внутренний сервис)

### SCN-SEARXNG-03: Секрет подставляется установщиком
**Given** `searxng-settings.yml` в репозитории содержит плейсхолдер `$SEARXNG_SECRET_PLACEHOLDER`
**When** выполнен шаг 2 `setup.ps1`
**Then** в файле на диске плейсхолдер заменён на 32-символьный секрет
**And** файл смонтирован в контейнер read-only

### SCN-SEARXNG-04: Только loopback
**When** контейнер `searxng-core` запущен
**Then** публикация `127.0.0.1:8080` — в LAN не светится

## 4. Приёмочные критерии

| ID | Критерий | Проверка |
|----|----------|----------|
| S1 | Живой JSON-поиск → HTTP 200 | `Invoke-WebRequest http://localhost:8080/search?q=test&format=json` |
| S2 | `searxng-settings.yml` содержит форматы html/json/csv/rss | чтение файла |
| S3 | Контейнер `searxng-valkey` в `docker ps` | `docker ps --format '{{.Names}}'` |
| S4 | Плейсхолдер `$SEARXNG_SECRET_PLACEHOLDER` отсутствует в файле на диске | чтение файла |

## 5. Верификация

```powershell
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
```

Все AC (S1–S4) исполняются автоматически.
