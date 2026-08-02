# Hermes Agent Stack — Спецификации (Spec-Driven Development)

Поведенческие контракты для всех компонентов стека: `docker-compose.yml`, `setup.ps1`,
контейнеры `hermes` / `searxng-core` / `searxng-valkey` / `mnemosyne`, конфигурация
Hermes и интеграция с Desktop.

## Методология (SDD-цикл для этого репозитория)

1. **Spec** — поведенческий контракт компонента: Gherkin-сценарии (Given/When/Then)
   + приёмочные критерии (AC) с командами проверки.
2. **Verify** — `specs/verify-specs.ps1` исполняет все машинопроверяемые AC против
   живого стека (read-only, ничего не меняет).
3. **Status** — результат прогона фиксируется в матрице статусов ниже и в шапке спеки.
4. **Change** — любое изменение компонента обязано обновить его спеку. Спека без
   прогона верификатора — незакрытый долг.

Правила:

- Каждый AC имеет уникальный ID и проверяется одной командой/скриптом.
- Статус `verified` присваивается только после прогона с 0 ошибок.
- Критерии, которые нельзя проверить скриптом (интерактивные сценарии), помечены `[manual]`.
- Секреты в спеках не хранятся — только имена переменных и форматы.

## Индекс спек

| Spec | Компонент | Артефакты | AC |
|------|-----------|-----------|----|
| [spec-compose-infra.md](spec-compose-infra.md) | Инфраструктура compose | `docker-compose.yml` | C1–C7, C9 |
| [spec-setup-script.md](spec-setup-script.md) | Установщик | `setup.ps1`, генерируемые файлы | P1–P7 |
| [spec-hermes-service.md](spec-hermes-service.md) | Hermes Gateway | `~/.hermes/.env`, `~/.hermes/config.yaml`, `connection.json` | H1–H8 |
| [spec-searxng-service.md](spec-searxng-service.md) | Поиск | `searxng-settings.yml`, `.env.searxng`, контейнеры searxng | S1–S4 |
| [spec-mnemosyne-service.md](spec-mnemosyne-service.md) | Память | `Dockerfile.mnemosyne`, контейнер, плагин | M1–M5 |

## Матрица статусов

| Spec | Статус | Прогон | Провалы |
|------|--------|--------|---------|
| spec-compose-infra | ✅ verified | 2026-08-02 | 0/8 |
| spec-setup-script | ✅ verified (P6/P7 — manual) | 2026-08-02 | 0/5 auto |
| spec-hermes-service | ✅ verified | 2026-08-02 | 0/8 |
| spec-searxng-service | ✅ verified | 2026-08-02 | 0/4 |
| spec-mnemosyne-service | ✅ verified | 2026-08-02 | 0/5 |

## Запуск верификации

```powershell
# Полный прогон (exit code = число провалов, 0 = всё зелёное)
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1

# Только сводка
powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1 -Quiet
```

Требования: Docker Desktop запущен, стек поднят (`docker compose up -d`),
установлен PowerShell 5.1+ (Windows 11 из коробки).
