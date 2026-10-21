# Процесс разработки

(Авторам текстов и контента — см. [materials/CONTRIBUTING.md](materials/CONTRIBUTING.md).)

## Поток работы

1. **Задача** — каждая работа начинается с issue на борде [GitHub Project «Verge»](https://github.com/users/discenss/projects). Колонки: Backlog → Todo → In progress → In review → Done. Метки: область (`backend`, `bot`, `ios`, `content`, `infra`, `docs`) и приоритет (`P0`–`P3`; `P0` = блокер беты).
2. **Ветка** от свежего `main`: `feat/<кратко>`, `fix/<кратко>`, `chore/<кратко>`.
3. **Коммиты и заголовок PR** — `type(scope): описание` (как в истории: `feat(backend): ...`, `fix(ios): ...`). Допустимые type: feat, fix, chore, docs, refactor, test, ci, perf.
4. **Pull request** в `main` с заполненным шаблоном; в описании `Closes #N`.
5. **CI** должен быть зелёным: backend (pytest, миграции, `verify_engines`), bot, docker-сборка, поиск секретов, формат заголовка.
6. **Ревью** — обязателен approve владельца (`@discenss`, см. CODEOWNERS). Новый коммит в PR сбрасывает approve; все обсуждения должны быть resolved.
7. **Merge** — только squash, ветка удаляется автоматически. Прямой push в `main` запрещён.

## Правила

- Секреты, `.env`, `.p8`, дампы БД с пользовательскими данными — никогда в git (secret scanning и gitleaks в CI это ловят).
- Менялись модели — добавьте миграцию Alembic.
- Менялось поведение или деплой — обновите `docs/RUNBOOK.md`.
- Hotfix на прод — тот же процесс, приоритет `P0`, ревью в первую очередь.

## Бета-тестирование

Отзывы тестеров заводятся через шаблон «Отзыв бета-тестера» (метка `beta-feedback`), не содержат персональных данных и разбираются на борде с приоритетом.

## Локальная проверка перед PR

```bash
cd backend && python -m pytest tests -q && python -m scripts.verify_engines
```
