# Spec: SearXNG Service (метапоиск)

| | |
|---|---|
| **Компонент** | SearXNG + Valkey |
| **Файлы** | `docker-compose.yml` (сервисы `searxng-core`, `searxng-valkey`), `searxng-settings.yml`, `.env.searxng` |
| **Статус** | ✅ verified |
| **Проверено** | 2026-08-08 |

## 1. Назначение

Приватный метапоиск для Hermes: `searxng-core` отдаёт JSON-результаты по
`format=json`, кэширует через `searxng-valkey`, слушает только loopback.
Конфиг — минимальный оверрайд поверх `use_default_settings: true`.

## 2. Входы

**`searxng-settings.yml`**:

| Ключ | Значение | Назначение |
|------|----------|------------|
| `use_default_settings` | `true` | официальные движки/настройки по умолчанию |
| `server.secret_key` | `__SEARXNG_SECRET__` в шаблоне setup.ps1 → реальный (шаг 2) | подпись сессий |
| `server.image_proxy` | `true` | проксирование картинок |
| `search.formats` | `html, json, csv, rss` | **без `json` JSON-API отдаёт 403** (требование Hermes-провайдера) |

**`.env.searxng`** (env_file сервиса): `SEARXNG_HOST=127.0.0.1`, `SEARXNG_PORT` (переиспользуется из `./.env`, дефолт 8080).

## 3. Поведенческие сценарии

### SCN-SEARXNG-01: JSON-API доступен
**Given** `search.formats` включает `json`
**When** `GET http://localhost:<SEARXNG_PORT>/search?q=test&format=json`
**Then** ответ HTTP 200 с JSON-результатами
**And** без `json` в formats тот же запрос возвращает werkzeug 403 (это НЕ лимитер)

### SCN-SEARXNG-02: Кэш через Valkey
**Given** сервис `searxng-valkey` (образ `valkey/valkey:9-alpine`)
**When** SearXNG обращается к кэшу
**Then** данные сохраняются в volume `valkey-data:/data` с политикой `--save 30 1`
**And** порт 6379 на host не публикуется (внутренний сервис)

### SCN-SEARXNG-03: Секрет генерируется установщиком (файл не в git)
**Given** `searxng-settings.yml` не отслеживается git (gitignored), шаблон — в `setup.ps1` (шаг 2)
**When** выполнен шаг 2 `setup.ps1`
**Then** файл на диске генерируется из шаблона с 32-символьным секретом (существующий секрет переиспользуется)
**And** файл смонтирован в контейнер read-only

### SCN-SEARXNG-04: Только loopback
**When** контейнер `searxng-core` запущен
**Then** публикация `127.0.0.1:<SEARXNG_PORT>` — в LAN не светится

## 4. Приёмочные критерии

| ID | Критерий | Проверка |
|----|----------|----------|
| S1 | Живой JSON-поиск → HTTP 200 | `Invoke-WebRequest http://localhost:<SEARXNG_PORT>/search?q=test&format=json` |
| S2 | `searxng-settings.yml` содержит форматы html/json/csv/rss | чтение файла |
| S3 | Контейнер `searxng-valkey` в `docker ps` | `docker ps --format '{{.Names}}'` |
| S4 | В файле на диске нет плейсхолдера секрета | чтение файла |

## 5. Верификация

```powershell
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
```

Все AC (S1–S4) исполняются автоматически.
