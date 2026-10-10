"""Минимальный FastAPI-скелет Mental Club — read-only эндпоинты каталога и интейка.

Бизнес-движки (day-progression, scoring/zone, интейк-роутер) — следующий слой (§7, §12).
"""
import logging
from contextlib import asynccontextmanager

from fastapi import Body, Depends, FastAPI, HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.database import SessionLocal, get_db
from app import models as m
from app.dependencies import current_user_id, is_internal, owned_enrollment, require_user_id
from app.services import (intake as intake_svc, progression, postmodule, identity,
                          settings as settings_svc, finalproduct, audio as audio_svc, i18n,
                          auth as auth_svc, daysteps, linking, push, text_content as text_svc)

logger = logging.getLogger(__name__)


def _push_reminders_tick() -> None:
    """Раз в минуту: те же кандидаты, что у бота (`settings.due_reminders`), доставка —
    APNs вместо Telegram (см. `push.send_due_reminders`). Бот сюда не лезет и не трогается."""
    db = SessionLocal()
    try:
        push.send_due_reminders(db)
    except Exception:                                   # noqa: BLE001 — тик не должен ронять процесс
        logger.exception("push reminders tick упал")
    finally:
        db.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    sched = AsyncIOScheduler(timezone="UTC")
    sched.add_job(_push_reminders_tick, "interval", minutes=1, id="ios_push_reminders",
                 max_instances=1, coalesce=True)
    sched.start()
    yield
    sched.shutdown(wait=False)


app = FastAPI(title="Mental Club API", version="0.1.0", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/v1/modules")
def list_modules(lang: str = "ru", db: Session = Depends(get_db)):
    """Каталог модулей (паспорта). До входа в enrollment язык берём явным query-параметром
    (как у audio.resolve) — единого пользователя тут ещё может не быть под рукой."""
    language = lang if lang in i18n.SUPPORTED_LANGUAGES else i18n.DEFAULT_LANGUAGE
    rows = db.execute(select(m.Module)).scalars().all()
    out = []
    for x in rows:
        view = i18n.overlay(db, m.ModuleTranslation, m.ModuleTranslation.module_code, x.code,
                            language, x, ["name", "subtitle", "passport"])
        out.append({"code": x.code, "name": view["name"], "subtitle": view["subtitle"],
                    "content_version": x.content_version, "passport": view["passport"]})
    return out


@app.get("/api/v1/modules/{code}/weeks/{n}")
def get_week(code: str, n: int, lang: str = "ru", db: Session = Depends(get_db)):
    """Неделя модуля с днями и самопроверкой."""
    language = lang if lang in i18n.SUPPORTED_LANGUAGES else i18n.DEFAULT_LANGUAGE
    week = db.execute(
        select(m.ModuleWeek).where(m.ModuleWeek.module_code == code.upper(), m.ModuleWeek.n == n)
    ).scalar_one_or_none()
    if not week:
        raise HTTPException(404, "week not found")
    week_view = i18n.overlay(db, m.ModuleWeekTranslation, m.ModuleWeekTranslation.week_id, week.id,
                             language, week, ["title", "intro_screen", "goal", "result"])
    days = db.execute(select(m.ModuleDay).where(m.ModuleDay.week_id == week.id).order_by(m.ModuleDay.day_n)).scalars().all()
    day_views = [
        i18n.overlay(db, m.ModuleDayTranslation, m.ModuleDayTranslation.day_id, d.id, language, d,
                    ["title", "focus", "task_text", "task_subtasks", "quiz", "reflection"])
        for d in days
    ]
    return {
        "n": week.n, "title": week_view["title"], "intro_screen": week_view["intro_screen"],
        "goal": week_view["goal"], "result": week_view["result"],
        "days": [{"d": d.day_n, "title": v["title"], "focus": v["focus"],
                  "task": {"text": v["task_text"], "subtasks": v["task_subtasks"]},
                  "quiz": v["quiz"], "reflection": v["reflection"]}
                 for d, v in zip(days, day_views)],
    }


@app.get("/api/v1/intake")
def get_intake(lang: str = "ru", db: Session = Depends(get_db)):
    """Вопросы входной самооценки + шкала (слой D, §12)."""
    language = lang if lang in i18n.SUPPORTED_LANGUAGES else i18n.DEFAULT_LANGUAGE
    cfg = db.get(m.IntakeConfig, 1)
    if not cfg:
        raise HTTPException(404, "intake not loaded")
    cfg_view = i18n.overlay(db, m.IntakeConfigTranslation, m.IntakeConfigTranslation.config_id,
                            cfg.id, language, cfg, ["client_intro", "start_button"])
    qs = db.execute(select(m.IntakeQuestion).order_by(m.IntakeQuestion.n)).scalars().all()
    questions = []
    for q in qs:
        qv = i18n.overlay(db, m.IntakeQuestionTranslation, m.IntakeQuestionTranslation.question_n,
                          q.n, language, q, ["text"])
        questions.append({"n": q.n, "direction": q.direction_code, "text": qv["text"]})
    return {
        "version": cfg.version, "client_intro": cfg_view["client_intro"],
        "answer_scale": cfg.answer_scale, "start_button": cfg_view["start_button"],
        "questions": questions,
    }


# ── Авторизация мобильного клиента (§3.1) ────────────────────────────────────
# Только для iOS. Бот НЕ затронут: он по-прежнему ходит телом запроса без токена.

@app.post("/api/v1/auth/apple")
def auth_apple(payload: dict = Body(...), db: Session = Depends(get_db)):
    """{identity_token, language?, timezone?} → наш JWT. Apple Sign-In."""
    token = (payload.get("identity_token") or "").strip()
    if not token:
        raise HTTPException(422, "нужен identity_token")
    try:
        verified = auth_svc.verify_apple(token)
        return auth_svc.sign_in(db, verified, language=payload.get("language", "ru"),
                                timezone=payload.get("timezone"))
    except auth_svc.AuthDisabled as e:
        raise HTTPException(503, str(e))
    except auth_svc.AuthError as e:
        raise HTTPException(401, str(e))


@app.post("/api/v1/auth/google")
def auth_google(payload: dict = Body(...), db: Session = Depends(get_db)):
    """{id_token, language?, timezone?} → наш JWT. Google Sign-In."""
    token = (payload.get("id_token") or "").strip()
    if not token:
        raise HTTPException(422, "нужен id_token")
    try:
        verified = auth_svc.verify_google(token)
        return auth_svc.sign_in(db, verified, language=payload.get("language", "ru"),
                                timezone=payload.get("timezone"))
    except auth_svc.AuthDisabled as e:
        raise HTTPException(503, str(e))
    except auth_svc.AuthError as e:
        raise HTTPException(401, str(e))


@app.get("/api/v1/auth/me")
def auth_me(uid: int = Depends(require_user_id), db: Session = Depends(get_db)):
    """Проверка живости сессии + профиль. iOS вызывает при старте (restoreSession).

    Отличать 401 (разлогин) от сетевой ошибки — задача клиента: здесь 401 означает
    именно недействительную сессию, а не сбой связи.
    """
    u = db.get(m.User, uid)
    if u is None:
        raise HTTPException(401, "пользователь не найден")
    idents = db.execute(
        select(m.UserIdentity).where(m.UserIdentity.user_id == uid)
    ).scalars().all()
    return {"user_id": u.id, "language": i18n.resolve_language(u),
            "timezone": u.timezone or settings_svc.DEFAULT_TZ,
            "providers": sorted({i.provider for i in idents})}


# ── Link-коды: склейка каналов (Telegram/WhatsApp ↔ iOS) ─────────────────────

@app.post("/api/v1/auth/link-code")
def auth_link_code(payload: dict = Body(...), db: Session = Depends(get_db)):
    """Канал-источник (бот) просит код для своего пользователя: {provider, provider_user_id}.

    Токен не требуется — вызывающий это бот, который живёт во внутренней сети и
    авторизации пока не имеет (сознательное решение: бота не трогаем).
    """
    provider = payload.get("provider")
    if not provider or payload.get("provider_user_id") is None:
        raise HTTPException(422, "нужны provider и provider_user_id")
    user = identity.get_by_provider(db, provider, payload["provider_user_id"])
    if user is None:
        raise HTTPException(404, "пользователь этого канала не найден")
    return linking.generate_code(db, user.id, provider=provider)


@app.post("/api/v1/auth/link")
def auth_link(payload: dict = Body(...), uid: int = Depends(require_user_id),
              db: Session = Depends(get_db)):
    """Приложение предъявляет 6-значный код: {code} → аккаунты сливаются в один."""
    code = (str(payload.get("code") or "")).strip()
    if not code:
        raise HTTPException(422, "нужен code")
    try:
        return linking.redeem_code(db, app_user_id=uid, code=code)
    except ValueError as e:
        raise HTTPException(422, str(e))


# ── Пуш-уведомления iOS (APNs) ───────────────────────────────────────────────

@app.post("/api/v1/devices/register")
def devices_register(payload: dict = Body(...), uid: int = Depends(require_user_id),
                     db: Session = Depends(get_db)):
    """{token, sandbox?, language?} → запомнить устройство для пушей."""
    try:
        return push.register_device(
            db, uid, payload.get("token"), platform=payload.get("platform", "ios"),
            sandbox=bool(payload.get("sandbox", False)), language=payload.get("language"))
    except ValueError as e:
        raise HTTPException(422, str(e))


@app.post("/api/v1/devices/unregister")
def devices_unregister(payload: dict = Body(...), uid: int = Depends(require_user_id),
                       db: Session = Depends(get_db)):
    """Снять устройство с пушей (выход из аккаунта)."""
    return push.unregister_device(db, (payload.get("token") or "").strip())


# ── Движки (§7, §12) ─────────────────────────────────────────────────────────

def _enrollment(db, eid: int, uid: int | None = None) -> m.Enrollment:
    """Программа по eid + проверка владельца для авторизованных запросов.

    Бот ходит без токена (uid=None) и получает прежнее поведение. Приложение всегда
    с токеном — и чужую программу по угаданному eid уже не откроет (403).
    """
    return owned_enrollment(db, eid, uid)


def _resolve_user_id(db, payload: dict, uid: int | None = None) -> int:
    """user_id запроса. Токен, если он есть, ПЕРЕБИВАЕТ тело.

    Поэтому `{"user_id": N}` в теле не даёт авторизованному клиенту доступа к чужому
    аккаунту; бот, приходящий без токена, опознаётся телом как раньше.
    """
    if uid is not None:
        return uid
    if payload.get("provider") and payload.get("provider_user_id") is not None:
        return identity.resolve_or_create(db, payload["provider"], payload["provider_user_id"]).id
    if payload.get("user_id") is not None:
        return int(payload["user_id"])
    raise HTTPException(422, "нужен user_id или provider+provider_user_id")


@app.post("/api/v1/users/resolve")
def users_resolve(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                  db: Session = Depends(get_db)):
    """{provider, provider_user_id} → единый user_id (создаёт при первом обращении)."""
    u = identity.resolve_or_create(db, payload["provider"], payload["provider_user_id"],
                                   language=payload.get("language", "ru"),
                                   timezone=payload.get("timezone"))
    return {"user_id": u.id, "language": u.preferred_language}


@app.post("/api/v1/intake/submit")
def intake_submit(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                  db: Session = Depends(get_db)):
    """{provider,provider_user_id | user_id, answers:{'1':0..4,...30}} → маршрут + фокусы (§12)."""
    uid = _resolve_user_id(db, payload, uid)
    answers = {int(k): int(v) for k, v in payload["answers"].items()}
    r = intake_svc.score_intake(db, answers, user_id=uid)
    r.pop("_scores", None)                              # баллы не отдаём пользователю
    return r


@app.post("/api/v1/users/settings")
def get_user_settings(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                      db: Session = Depends(get_db)):
    return settings_svc.get_settings(db, _resolve_user_id(db, payload, uid))


@app.post("/api/v1/users/settings/update")
def update_user_settings(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                         db: Session = Depends(get_db)):
    uid = _resolve_user_id(db, payload, uid)
    try:
        return settings_svc.update_settings(
            db, uid, timezone=payload.get("timezone"), language=payload.get("language"),
            slot=payload.get("slot"), hour=payload.get("hour"), minute=payload.get("minute"))
    except Exception as e:                              # noqa: BLE001
        raise HTTPException(422, f"неверные настройки: {e}")


@app.post("/api/v1/reminders/due")
def reminders_due(internal: bool = Depends(is_internal), db: Session = Depends(get_db)):
    """Внутренний эндпоинт для планировщика бота: кандидаты на напоминание сейчас (без стемпа).

    Отдаёт provider_user_id всех пользователей вместе с их позицией в программе, поэтому
    закрывается сервисным токеном. Пока INTERNAL_API_TOKEN не задан — доступ как раньше
    (бот не сломан); как только задан — только предъявивший токен.
    """
    if not internal:
        raise HTTPException(401, "нужен сервисный токен")
    return {"due": settings_svc.due_reminders(db)}


@app.post("/api/v1/reminders/mark")
def reminders_mark(payload: dict = Body(...), internal: bool = Depends(is_internal),
                   db: Session = Depends(get_db)):
    """Бот подтверждает доставку слота → стемпим (дедуп раз/день). Только после отправки."""
    if not internal:
        raise HTTPException(401, "нужен сервисный токен")
    return settings_svc.mark_reminded(db, payload["provider_user_id"], payload["slot"])


@app.post("/api/v1/users/reset")
def users_reset(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                db: Session = Depends(get_db)):
    """Полный сброс прогресса пользователя (программы, дневник, интейк). Идентичность сохраняется."""
    uid = _resolve_user_id(db, payload, uid)
    return {"reset": True, "deleted": identity.reset_user(db, uid)}


@app.post("/api/v1/users/abandon-active")
def users_abandon_active(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                         db: Session = Depends(get_db)):
    """Бросить ТЕКУЩУЮ незавершённую программу (для «Сменить программу»). Завершённые остаются."""
    uid = _resolve_user_id(db, payload, uid)
    return {"deleted": identity.abandon_active_enrollment(db, uid)}


@app.post("/api/v1/users/enrollments")
def user_enrollments(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                     db: Session = Depends(get_db)):
    """{provider,provider_user_id | user_id} → список записей пользователя (для «Мой путь»/«Сегодня»)."""
    uid = _resolve_user_id(db, payload, uid)
    language = i18n.resolve_language(db.get(m.User, uid))
    rows = db.execute(
        select(m.Enrollment).where(m.Enrollment.user_id == uid).order_by(m.Enrollment.id.desc())
    ).scalars().all()
    out = []
    for e in rows:
        mod = db.get(m.Module, e.module_code)
        name = i18n.overlay(db, m.ModuleTranslation, m.ModuleTranslation.module_code, mod.code,
                            language, mod, ["name"])["name"] if mod else e.module_code
        out.append({"enrollment_id": e.id, "module": e.module_code,
                    "name": name, "status": e.status,
                    "week": e.current_week, "day": e.current_day, "mode": e.mode})
    return {"enrollments": out}


@app.get("/api/v1/enrollments/{eid}/status")
def enrollment_status(eid: int, uid: int | None = Depends(current_user_id),
                      db: Session = Depends(get_db)):
    """Сводка пути: модуль, где я сейчас, зоны пройденных недель."""
    e = _enrollment(db, eid, uid)
    language = i18n.resolve_language(e.user)
    mod = db.get(m.Module, e.module_code)
    name = i18n.overlay(db, m.ModuleTranslation, m.ModuleTranslation.module_code, mod.code,
                        language, mod, ["name"])["name"] if mod else e.module_code
    zones = db.execute(
        select(m.SelfcheckResult).where(m.SelfcheckResult.enrollment_id == eid)
        .order_by(m.SelfcheckResult.week_n)
    ).scalars().all()
    days_done = db.execute(
        select(func.count(m.DailyEntry.id)).where(m.DailyEntry.enrollment_id == eid)
    ).scalar_one()
    # Названия недель — отдельное поле (а не внутри "weeks"), чтобы не трогать
    # контракт "weeks" (бот его парсит как список ТОЛЬКО пройденных недель).
    mod_weeks = db.execute(
        select(m.ModuleWeek).where(m.ModuleWeek.module_code == e.module_code)
        .order_by(m.ModuleWeek.n)
    ).scalars().all()
    week_titles = [
        {"week": w.n, "title": i18n.overlay(db, m.ModuleWeekTranslation,
                                            m.ModuleWeekTranslation.week_id, w.id,
                                            language, w, ["title"])["title"]}
        for w in mod_weeks
    ]
    return {"module": e.module_code, "name": name,
            "status": e.status, "week": e.current_week, "day": e.current_day, "mode": e.mode,
            "total_weeks": 6, "total_days": 7, "days_completed": days_done,
            "days_total": 42, "started_at": e.started_at.isoformat() if e.started_at else None,
            "weeks": [{"week": z.week_n, "zone": z.zone} for z in zones],
            "week_titles": week_titles}


@app.post("/api/v1/journal/list")
def journal_list(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                 db: Session = Depends(get_db)):
    """«Мой дневник» (§8): записи пользователя, свежие сверху. Опц. фильтр module_code."""
    uid = _resolve_user_id(db, payload, uid)
    language = i18n.resolve_language(db.get(m.User, uid))
    q = select(m.JournalEntry).where(m.JournalEntry.user_id == uid)
    if payload.get("module_code"):
        q = q.where(m.JournalEntry.module_code == payload["module_code"].upper())
    rows = db.execute(q.order_by(m.JournalEntry.created_at.desc(), m.JournalEntry.id.desc())).scalars().all()
    names: dict[str, str] = {}
    for code in {j.module_code for j in rows if j.module_code}:
        mod = db.get(m.Module, code)
        if mod:
            names[code] = i18n.overlay(db, m.ModuleTranslation, m.ModuleTranslation.module_code,
                                       code, language, mod, ["name"])["name"]
    return {"entries": [
        {"id": j.id, "source_type": j.source_type, "module_code": j.module_code,
         "module_name": names.get(j.module_code), "week": j.week_n, "day": j.day_n, "text": j.text,
         "created_at": j.created_at.isoformat() if j.created_at else None}
        for j in rows
    ]}


@app.post("/api/v1/journal")
def journal_add(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                db: Session = Depends(get_db)):
    """Личная заметка в дневник (source_type='note')."""
    uid = _resolve_user_id(db, payload, uid)
    text = (payload.get("text") or "").strip()
    if not text:
        raise HTTPException(422, "пустая заметка")
    j = m.JournalEntry(user_id=uid, source_type="note",
                       module_code=(payload.get("module_code") or None), text=text)
    db.add(j)
    db.commit()
    return {"id": j.id}


@app.post("/api/v1/enroll")
def enroll(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
           db: Session = Depends(get_db)):
    uid = _resolve_user_id(db, payload, uid)
    # Одновременно идёт только ОДНА программа — так это подано в боте, и приложение
    # не должно расходиться. Смена маршрута — через /users/abandon-active.
    mode = payload.get("mode", "normal")
    requested = (payload.get("module_code") or "").upper()
    active = db.execute(
        select(m.Enrollment).where(m.Enrollment.user_id == uid,
                                   m.Enrollment.status.in_(("active", "selfcheck_due")),
                                   m.Enrollment.mode == mode)
    ).scalars().all()
    if any(e.module_code != requested for e in active):
        raise HTTPException(409, "уже идёт другая программа: сначала завершите или "
                                 "бросьте её (/users/abandon-active)")
    e = progression.enroll(db, uid, payload["module_code"], mode=mode)
    language = i18n.resolve_language(db.get(m.User, uid))
    mod = db.get(m.Module, e.module_code)
    name = i18n.overlay(db, m.ModuleTranslation, m.ModuleTranslation.module_code, mod.code,
                        language, mod, ["name"])["name"] if mod else e.module_code
    return {"enrollment_id": e.id, "module": e.module_code,
            "name": name, "mode": e.mode,
            "week": e.current_week, "day": e.current_day, "status": e.status}


@app.get("/api/v1/enrollments/{eid}/today")
def today(eid: int, uid: int | None = Depends(current_user_id),
          db: Session = Depends(get_db)):
    # дату гейта больше не навязываем: движок берёт локальную дату пользователя
    # (services/clock) — раньше здесь стояла date.today() серверного процесса
    return progression.get_today(db, _enrollment(db, eid, uid))


@app.get("/api/v1/enrollments/{eid}/day-steps")
def day_steps(eid: int, uid: int | None = Depends(current_user_id),
              db: Session = Depends(get_db)):
    """Тот же день, что и /today, но уже РАЗЛОЖЕННЫЙ в последовательность шагов.

    Единый источник истины для прохождения дня: раньше эту последовательность строил
    только Telegram-бот у себя, и второй клиент означал бы вторую реализацию. Каждый
    шаг несёт структурные поля (для iOS) и готовый `text` (для бота), см. services/daysteps.
    """
    return daysteps.build(progression.get_today(db, _enrollment(db, eid, uid)))


@app.get("/api/v1/audio/{code}/resolve")
def audio_resolve(code: str, lang: str = "ru", db: Session = Depends(get_db)):
    """Разрешить аудио-практику в конкретный языковой вариант (с фолбэком) + отдать URL
    (если публичный домен уже настроен, settings.audio_public_base_url) и кэш доставки по
    каналам. Канал (бот и т.п.) сам решает, как доставить: по URL, по кэшу или локальным файлом."""
    r = audio_svc.resolve(db, code, lang)
    if not r:
        raise HTTPException(404, "audio not found")
    return r


@app.post("/api/v1/audio/{code}/cache")
def audio_cache(code: str, payload: dict = Body(...), db: Session = Depends(get_db)):
    """Запомнить ID доставки (Telegram file_id / WhatsApp media_id / …) для конкретного
    языка+канала — дальше этот канал шлёт мгновенно, без повторной загрузки файла."""
    ok = audio_svc.cache_delivery(db, code, payload["language"], payload["channel"], payload["ref"])
    if not ok:
        raise HTTPException(404, "audio/language not found")
    return {"ok": True}


@app.get("/api/v1/audio/{code}/file")
def audio_file(code: str, lang: str = "ru", db: Session = Depends(get_db)):
    """Отдать сам аудиофайл локально (пока нет публичного объектного хранилища).
    Once там будет S3/R2 — этот путь станет ненужен: resolve() начнёт отдавать URL бакета
    напрямую, каналы перестанут ходить сюда."""
    from pathlib import Path
    from fastapi.responses import FileResponse
    from app.config import settings
    r = audio_svc.resolve(db, code, lang)
    if not r:
        raise HTTPException(404, "audio not found")
    path = Path(settings.content_dir) / "audio" / r["storage_key"]
    if not path.is_file():
        raise HTTPException(404, "audio file missing on disk")
    return FileResponse(path, media_type=r["mime"] or "audio/mpeg", filename=r["storage_key"])


@app.get("/api/v1/text/{code}/resolve")
def text_resolve(code: str, lang: str = "ru", db: Session = Depends(get_db)):
    """Разрешить текстовую практику в конкретный языковой вариант (с фолбэком на ru) —
    аналог /audio/{code}/resolve, но тело практики отдаётся сразу, без отдельного файла."""
    r = text_svc.resolve(db, code, lang)
    if not r:
        raise HTTPException(404, "text not found")
    return r


@app.post("/api/v1/enrollments/{eid}/practice-log")
def practice_log(eid: int, payload: dict = Body(...),
                  uid: int | None = Depends(current_user_id),
                  db: Session = Depends(get_db)):
    """Необязательная отметка «прослушал аудио» / «прочитал текст» в дневник (§ смена
    парадигмы: текст+аудио). Ничего не блокирует — можно отмечать или не отмечать."""
    kind = payload.get("kind")
    if kind not in ("audio", "text"):
        raise HTTPException(422, "kind должен быть audio или text")
    code = (payload.get("code") or "").strip()
    if not code:
        raise HTTPException(422, "пустой code")
    enr = _enrollment(db, eid, uid)
    j = progression.log_practice(db, enr, kind=kind, code=code, title=payload.get("title"))
    return {"id": j.id}


@app.post("/api/v1/enrollments/{eid}/open-day")
def open_day(eid: int, payload: dict = Body(default={}),
             uid: int | None = Depends(current_user_id),
             db: Session = Depends(get_db)):
    """Утренняя сессия: открыть день (фокус/задание/аудио)."""
    return progression.open_day(db, _enrollment(db, eid, uid))


@app.post("/api/v1/enrollments/{eid}/close-day")
def close_day(eid: int, payload: dict = Body(default={}),
              uid: int | None = Depends(current_user_id),
              db: Session = Depends(get_db)):
    """Вечерняя сессия: статус задания + квиз + рефлексия → продвижение.

    `close_day` продвигает день и не идемпотентен, поэтому дневной гейт стоит здесь:
    повторный вызов в те же сутки (двойной тап, ретрай на плохой сети) не проматывает
    второй день, а возвращает текущее состояние с `already_closed`. Сам движок остаётся
    time-agnostic (§7.1) — гейт это забота клиентского слоя.
    """
    enr = _enrollment(db, eid, uid)
    if progression.closed_today(db, enr):
        return {"status": enr.status, "week": enr.current_week, "day": enr.current_day,
                "already_closed": True}
    return progression.close_day(
        db, enr,
        task_status=payload.get("task_status"), task_answer=payload.get("task_answer"),
        quiz_answer=payload.get("quiz_answer"), reflection=payload.get("reflection"),
    )


@app.post("/api/v1/enrollments/{eid}/complete-day")
def complete_day(eid: int, payload: dict = Body(default={}),
                 uid: int | None = Depends(current_user_id),
                 db: Session = Depends(get_db)):
    """Весь день одним вызовом (тест-режим/авто-прогон). Тот же гейт, что в close-day."""
    enr = _enrollment(db, eid, uid)
    if progression.closed_today(db, enr):
        return {"status": enr.status, "week": enr.current_week, "day": enr.current_day,
                "already_closed": True}
    return progression.complete_day(
        db, enr,
        task_status=payload.get("task_status"),
        task_answer=payload.get("task_answer"), quiz_answer=payload.get("quiz_answer"),
        reflection=payload.get("reflection"),
    )


@app.get("/api/v1/enrollments/{eid}/selfcheck-questions")
def selfcheck_questions(eid: int, uid: int | None = Depends(current_user_id),
                        db: Session = Depends(get_db)):
    """Вопросы недельной самопроверки текущей недели (тексты вариантов; веса скрыты)."""
    e = _enrollment(db, eid, uid)
    language = i18n.resolve_language(e.user)
    week = db.execute(select(m.ModuleWeek).where(m.ModuleWeek.module_code == e.module_code,
                                                 m.ModuleWeek.n == e.current_week)).scalar_one()
    qs = db.execute(select(m.SelfcheckQuestion).where(m.SelfcheckQuestion.week_id == week.id)
                    .order_by(m.SelfcheckQuestion.q_index)).scalars().all()
    out = []
    for q in qs:
        base_texts = [o["text"] for o in q.options]
        question_text = q.question
        if language != i18n.DEFAULT_LANGUAGE:
            tr = db.execute(
                select(m.SelfcheckQuestionTranslation).where(
                    m.SelfcheckQuestionTranslation.question_id == q.id,
                    m.SelfcheckQuestionTranslation.language == language)
            ).scalar_one_or_none()
            if tr:
                question_text = tr.question or question_text
                base_texts = tr.option_texts or base_texts
        out.append({"q": q.q_index, "question": question_text, "options": base_texts})
    # маркеры идут блоком ПЕРЕД вопросами самопроверки: раз в неделю вместо ежедневных 10
    morning, evening = progression.get_markers(db, e, language=language)
    return {"week": e.current_week, "questions": out,
            "morning_markers": morning, "evening_markers": evening}


@app.post("/api/v1/enrollments/{eid}/selfcheck")
def selfcheck(eid: int, payload: dict = Body(...),
              uid: int | None = Depends(current_user_id),
              db: Session = Depends(get_db)):
    """{answers:{'1':idx,...10}, morning:{...}, evening:{...}} → зона + рекомендация +
    critical-блоки (баллы скрыты). morning/evening — недельные маркеры, в баллы не идут."""
    answers = {int(k): int(v) for k, v in payload["answers"].items()}
    r = progression.submit_selfcheck(db, _enrollment(db, eid, uid), answers,
                                     morning=payload.get("morning"),
                                     evening=payload.get("evening"))
    r.pop("core_score", None); r.pop("flags", None)
    return r


@app.get("/api/v1/enrollments/{eid}/final-product/template")
def final_product_template(eid: int, uid: int | None = Depends(current_user_id),
                           db: Session = Depends(get_db)):
    """Шаблон финального продукта (секции для пошагового сбора)."""
    return finalproduct.get_template(db, _enrollment(db, eid, uid))


@app.post("/api/v1/enrollments/{eid}/final-product")
def final_product_save(eid: int, payload: dict = Body(...),
                       uid: int | None = Depends(current_user_id),
                       db: Session = Depends(get_db)):
    """Сохранить собранный продукт: instance + короткая отсылка в дневник (§14, §12)."""
    return finalproduct.save(db, _enrollment(db, eid, uid), payload.get("answers") or [])


@app.post("/api/v1/final-products/list")
def final_products_list(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
                        db: Session = Depends(get_db)):
    """Все собранные продукты пользователя — экран «Личные достижения»."""
    uid = _resolve_user_id(db, payload, uid)
    return {"items": finalproduct.list_for_user(db, uid)}


@app.get("/api/v1/enrollments/{eid}/final-product/file")
def final_product_file(eid: int, uid: int | None = Depends(current_user_id),
                       db: Session = Depends(get_db)):
    """Скачать продукт как .md-файл."""
    from fastapi.responses import Response
    enr = _enrollment(db, eid, uid)
    fp = finalproduct.get_for_enrollment(db, enr)
    if fp is None:
        raise HTTPException(404, "final product not built yet")
    fname = f"{enr.module_code}_личный_итог.md"
    return Response(content=fp["md"], media_type="text/markdown",
                    headers={"Content-Disposition": f'attachment; filename="{fname}"'})


@app.get("/api/v1/enrollments/{eid}/postmodule-questions")
def postmodule_questions(eid: int, uid: int | None = Depends(current_user_id),
                         db: Session = Depends(get_db)):
    """Вопросы постмодуля для показа (REAL=21 вопрос без весов; BOUND=пусто)."""
    return postmodule.get_questions(db, _enrollment(db, eid, uid))


@app.post("/api/v1/enrollments/{eid}/postmodule")
def postmodule_run(eid: int, payload: dict = Body(default={}),
                   uid: int | None = Depends(current_user_id),
                   db: Session = Depends(get_db)):
    return postmodule.run(db, _enrollment(db, eid, uid), payload.get("answers"))


# ── Тестовый режим (перемотка; только mode='test') ──────────────────────────

@app.post("/api/v1/enrollments/{eid}/test/advance")
def test_advance(eid: int, payload: dict = Body(default={}),
                 uid: int | None = Depends(current_user_id),
                 db: Session = Depends(get_db)):
    """scope: day|week|program, preset: best|worst|random. Прогон без дневного гейта.
    Возвращает транскрипт выдачи движка (фокусы, квизы, зоны, интерпретации, critical, постмодуль)."""
    from app.services import testmode
    e = _enrollment(db, eid, uid)
    if e.mode != "test":
        raise HTTPException(403, "перемотка доступна только для enrollment с mode='test'")
    return testmode.run(db, e, scope=payload.get("scope", "day"),
                        preset=payload.get("preset", "best"), seed=payload.get("seed"))


# ── ИИ: будни (ask, простая модель) + аналитика (insight, сильная модель) ────

@app.post("/api/v1/ai/ask")
def ai_ask(payload: dict = Body(...), uid: int | None = Depends(current_user_id),
           db: Session = Depends(get_db)):
    """Свободный вопрос пользователя → мягкий ответ (everyday-модель, guardrails §16)."""
    from app.services import ai
    _resolve_user_id(db, payload, uid)                      # гарантируем существование пользователя
    q = (payload.get("question") or "").strip()
    if not q:
        raise HTTPException(422, "пустой вопрос")
    return ai.ask(q, context=payload.get("context"))


@app.post("/api/v1/enrollments/{eid}/insight")
def ai_insight(eid: int, uid: int | None = Depends(current_user_id),
               db: Session = Depends(get_db)):
    """Итог модуля по данным пользователя (analytics-модель)."""
    from app.services import ai
    return ai.module_insight(db, _enrollment(db, eid, uid))


@app.post("/api/v1/enrollments/{eid}/week-insight")
def ai_week_insight(eid: int, uid: int | None = Depends(current_user_id),
                    db: Session = Depends(get_db)):
    """ИИ-разбор последней пройденной недели (analytics-модель)."""
    from app.services import ai
    return ai.week_insight(db, _enrollment(db, eid, uid))
