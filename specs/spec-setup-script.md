# Spec: Setup Script (`setup.ps1`)

| | |
|---|---|
| **Компонент** | Установщик стека |
| **Файл** | `setup.ps1` |
| **Статус** | ✅ verified |
| **Проверено** | 2026-08-02 |

## 1. Назначение

Идемпотентная одно-командная установка стека на Windows 11: проверка/установка
Docker, генерация секретов, запись конфигов Hermes, запуск контейнеров, установка
плагина Mnemosyne, верификация здоровья, настройка Hermes Desktop. Переживает
краши через checkpoint/resume.

## 2. Входы (параметры)

| Параметр | Тип | Дефолт | Назначение |
|----------|-----|--------|------------|
| `-Provider` | string (ValidateSet) | `deepseek` | `deepseek`, `openrouter`, `anthropic`, `openai`, `google` |
| `-Model` | string | зависит от провайдера | модель LLM |
| `-ApiKey` | string | пусто (prompt) | ключ API провайдера |
| `-DryRun` | switch | — | показать план без изменений, exit 0 |
| `-Install` | switch | — | пропустить меню, выполнить 6 шагов |
| `-ResetState` | switch | — | сбросить чекпоинты + `credentials.txt` |
| `-Pause` | switch | — | держать окно после завершения |
| `-InstallDir` | string | `%USERPROFILE%\hermes-stack` | корень стека |
| `-Components` | string (CSV) | все (`hermes,searxng,mnemosyne`) | какие компоненты ставить: `hermes` (Gateway), `searxng`, `mnemosyne`; `hermes` включается всегда, неизвестные значения → ошибка |

Таблица провайдеров (внутренняя `$ProviderConfig`):

| Provider | Дефолтная модель | Env-ключ | base_url |
|----------|------------------|----------|----------|
| `deepseek` | `deepseek-chat` | `DEEPSEEK_API_KEY` | — |
| `openrouter` | `anthropic/claude-sonnet-4.6` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` |
| `anthropic` | `claude-sonnet-4.6` | `ANTHROPIC_API_KEY` | — |
| `openai` | `gpt-4o` | `OPENAI_API_KEY` | — |
| `google` | `gemini-2.5-pro` | `GOOGLE_API_KEY` | — |

## 3. Поведенческие сценарии

### SCN-SETUP-01: Без аргументов — интерактивное меню
**Given** скрипт запущен без параметров
**Then** поверх меню рисуется статус-панель: Docker (`docker info`), API (TCP 9119), Search (TCP 8080), Memory (TCP 8081) как `[OK]`/`[FAIL]` — ячейки только для выбранных компонентов
**And** пункты меню: Setup — 1 Install, 2 Update; Managing the Stack — 3 Status (`docker compose ps`), 4 Logs (`logs -f`), 5 Start (`up -d`), 6 Restart, 7 Stop (`down`), 8 Stats (`docker stats`); 0 Exit
**And** при выборе «1 Install» сначала показывается экран выбора компонентов (`Select-Components`): чекбоксы `[x]`/`[ ]` для searxng/mnemosyne, `hermes` показан как `[x] (always installed)` и не переключается; клавиши 1–3 переключают, `a`/`n` — все/ни один, Enter — продолжить; опциональный набор (searxng/mnemosyne) может быть пустым — hermes включается автоматически

### SCN-SETUP-02: `-Install -Provider <p> -ApiKey <k>` — шесть шагов
**When** скрипт запущен с `-Install`
**Then** выполняются шаги (со статус-баром `[####------] N/6 <label>`); шаги, относящиеся к невыбранным компонентам, пропускаются с `Write-INFO`:
1. `prerequisites` — проверка админ-прав (warn), наличие docker (иначе скачать установщик Docker Desktop и exit 0), ожидание демона (retry 6×10s), запрос API-ключа если пуст (warn если < 10 символов)
2. `directories` — mkdir `InstallDir` и `~/.hermes`; генерация секретов (в т.ч. `API_SERVER_KEY`, 32 hex); запись `~/.hermes/.env`, `~/.hermes/config.yaml`, `./.env`, `./.env.searxng`, подстановка секрета в `searxng-settings.yml`, запись `credentials.txt`
3. `containers` — `docker compose down --remove-orphans`, удаление только legacy-контейнеров без label compose-проекта (одноимённые контейнеры чужих проектов не трогаются), build mnemosyne (retry 2), `docker compose up -d` (retry 3×8s), ожидание 10s, проверка что все 4 в `docker ps`
4. `plugin` — `docker exec hermes uv pip install mnemosyne-hermes` (retry 3×8s), копирование пакета в `/opt/data/plugins/mnemosyne/` (путь site-packages ищется динамически, retry 3, проверка exit code), `hermes config set memory.provider mnemosyne` (retry 3, проверка exit code), `docker restart hermes`, ожидание 8s
5. `verify` — Hermes API `GET /api/status` с basic auth (retry 5×3s, печать версии), SearXNG `GET /search?q=test&format=json` (HTTP 200), Mnemosyne TCP-проба 8081 (SSE вешает Invoke-WebRequest), `hermes memory status` ≈ `mnemosyne.*active`
6. `desktop` — установка Hermes Desktop если `%LOCALAPPDATA%\hermes\hermes-agent\apps\desktop` отсутствует (скачать установщик, `--silent`), запись `%APPDATA%\hermes\connection.json` (mode=remote, url=`http://localhost:9119`, authMode=oauth)

### SCN-SETUP-03: `-DryRun` ничего не меняет
**Given** скрипт запущен с `-DryRun`
**Then** печатаются Provider/Model/Components/InstallDir/маска ключа и план по выбранным компонентам (кол-во пунктов зависит от выборки)
**And** не пишутся файлы, не вызывается docker, не скачиваются установщики (все действия в `Invoke-Retry` прерываются на `[dry-run] would: ...`)
**And** exit code 0

### SCN-SETUP-04: Checkpoint/resume
**Given** шаг N успешно завершён ранее (записан в `.hermes-stack-state.json`)
**When** скрипт запущен повторно (без `-ResetState`)
**Then** шаги 1..N-1 пропускаются с `already done -- skipping`
**And** `Set-State` не пишет в state при `-DryRun`

### SCN-SETUP-05: `-ResetState` — полная переустановка
**When** скрипт запущен с `-ResetState`
**Then** удаляются `.hermes-stack-state.json` и `credentials.txt`
**And** `Is-Completed` возвращает `$false` для всех шагов — всё перевыполняется

### SCN-SETUP-06: Форматы генерируемых секретов
**When** выполняется шаг 2
**Then** `dashPass` = 16 символов `[0-9A-Za-z]`, `dashSec` = 44 символа + `==`, `mcpTok` = 64 hex-символа, `searxngSec` = 32 символа `[0-9A-Za-z]`, `apiKey` = 32 hex-символа

### SCN-SETUP-07: Артефакты шага 2
**Then** `~/.hermes/.env`: `<ENVKEY>=<key>`, `SEARXNG_URL=http://searxng-core:8080`, `HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin`, пароль и секрет
**And** `~/.hermes/config.yaml`: `model.default=<provider>/<model>`, `model.provider`, `web.search_backend=searxng`, `memory.memory_enabled=true`, `memory.provider=mnemosyne`, `terminal.backend=local`, `approvals.mode=smart`, `display.language=ru`, `display.show_cost=true`
**And** `./.env`: `MNEMOSYNE_MCP_TOKEN`, `API_SERVER_KEY` (32 hex), порты `HERMES_API_PORT=8642`, `HERMES_DASHBOARD_PORT=9119`, `SEARXNG_HOST/PORT`, `MNEMOSYNE_PORT=127.0.0.1:8081`
**And** `./.env.searxng`: `SEARXNG_HOST=127.0.0.1`, `SEARXNG_PORT=8080`
**And** в `searxng-settings.yml` плейсхолдер `$SEARXNG_SECRET_PLACEHOLDER` заменён на реальный секрет
**And** `credentials.txt` содержит дату, URL дашборда, `admin`/пароль, MCP-токен, API Server Key, searxng-секрет, маску API-ключа

### SCN-SETUP-08: Меню → Update
**When** выбрано «2. Update» (или `Invoke-Update`)
**Then** `docker compose pull` (retry 2), `docker compose build mnemosyne` (retry 2), `docker compose up -d` (retry 3×8s), `docker exec hermes hermes update`, `docker restart hermes`

### SCN-SETUP-10: Меню → Managing the Stack
**When** выбран пункт «Status / Logs / Start / Restart / Stop / Stats»
**Then** в `$InstallDir` выполняется соответствующая команда: `docker compose ps` (3), `docker compose logs -f` (4), `docker compose up -d` (5), `docker compose restart` (6), `docker compose down` (7), `docker stats` (8)
**And** после завершения команды (кроме блокирующих 4 Logs и 8 Stats — выход по Ctrl+C) меню показывается снова; при ненулевом exit code печатается `WARN`
**And** «1 Install» завершает цикл меню и переходит к шагам установки, «0 Exit» завершает скрипт

### SCN-SETUP-11: Выборочная установка `-Components`
**Given** скрипт запущен с `-Install -Components <csv>` (или выбор сделан в `Select-Components`)
**Then** `$script:SelectedComponents` = распарсенный список (trim/lowercase), неизвестное значение → `throw`, пустой список → `throw`
**And** `hermes` включается в выборку принудительно (ядро стека, всегда устанавливается), даже если не указан в `-Components`
**And** при отсутствии `-Components` выбор берётся из `STACK_COMPONENTS` в `$InstallDir\.env` (если есть), иначе — все три
**And** шаг 2 пишет в `./.env` строки `COMPOSE_PROFILES=<searxng,mnemosyne>` (только выбранные не-hermes профили) и `STACK_COMPONENTS=<csv>`; в `~/.hermes/.env`/`config.yaml`/`credentials.txt` секции только для выбранных компонентов (`SEARXNG_URL`/`web.search_backend` только при searxng; `memory.provider` только при mnemosyne; `MNEMOSYNE_MCP_TOKEN` только при mnemosyne; `API_SERVER_KEY`/dashboard/Desktop — всегда, т.к. hermes всегда)
**And** шаг 3: `build mnemosyne` только при mnemosyne; `up -d` стартует только выбранные (через `COMPOSE_PROFILES`; `hermes` без профиля — всегда); лишние контейнеры проекта (label `com.docker.compose.project=hermes-stack`) вне выбранного набора удаляются; проверка «running» — только по ожидаемым контейнерам
**And** шаг 4 (плагин) — только при mnemosyne (hermes есть всегда); шаг 5 проверяет только выбранные компоненты; шаг 6 (Desktop) — всегда
**And** при расхождении выбора с фактически установленным (источник истины — `STACK_COMPONENTS` в `./.env`, написанный применяющим шагом 2; для legacy-установок без `STACK_COMPONENTS` считается `hermes,searxng,mnemosyne`) печатается `WARN` и сбрасываются чекпоинты шагов 2–6 (`directories`, `containers`, `plugin`, `verify`, `desktop`) — шаги перевыполняются с новой выборкой
**And** `state.components` НЕ используется для сравнения (может быть устаревшим: его пишет сводка даже после run'а, где все шаги пропущены)
**And** шаг 2 переиспользует существующие секреты (`~/.hermes/.env`, `./.env`, `searxng-settings.yml`), генерирует только недостающие — пароли/токены при смене выборки не ротируются; `DEEPSEEK_API_KEY` при отсутствии `-ApiKey` восстанавливается из `~/.hermes/.env`
**And** в конце выбранный набор сохраняется в state как `components`

### SCN-SETUP-09: Итоговая сводка
**When** установка завершена (или шаги пропущены)
**Then** пароль восстанавливается из `credentials.txt` (fallback: `~/.hermes/.env`), порты читаются из `./.env` (fallback: дефолты)
**And** печатаются copy-paste ссылки: Dashboard `http://localhost:<p>`, API `.../v1`, SearXNG, Mnemosyne `/sse`, настройки Desktop (URL/user/pass), команды статуса/логов/обновлений

## 4. Приёмочные критерии

| ID | Критерий | Проверка | Тип |
|----|----------|----------|-----|
| P1 | `.hermes-stack-state.json` существует и парсится, `completed` — массив | `Get-Content | ConvertFrom-Json` | auto |
| P2 | `credentials.txt` существует | `Test-Path` | auto |
| P3 | `./.env` содержит `MNEMOSYNE_MCP_TOKEN`, `API_SERVER_KEY` (32 hex) и порты 8642/9119 | чтение файла | auto |
| P4 | `./.env.searxng` содержит host/port loopback | чтение файла | auto |
| P5 | `setup.ps1` парсится без синтаксических ошибок | `Parser::ParseFile` | auto |
| P6 | `-DryRun` не создаёт/не меняет файлы и не дёргает docker | ручной прогон | manual |
| P7 | Без аргументов показываются статус-панель и пункты меню (Setup 1–2, Managing the Stack 3–8, Exit 0) | ручной прогон | manual |
| P8 | `-Components` принимает только `hermes,searxng,mnemosyne`; неизвестное значение и пустой список → ошибка; `-DryRun` печатает Components | ручной прогон | manual |

## 5. Верификация

```powershell
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
```

Автоматически: P1–P5. Вручную: P6, P7 (интерактивные сценарии).
