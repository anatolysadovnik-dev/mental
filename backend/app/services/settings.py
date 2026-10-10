"""Настройки пользователя + вычисление, кому пора отправить напоминание.

Три слота напоминаний в день: утро / день(обед) / вечер. Каждый слот шлётся раз в день
и только если сегодняшний день модуля ещё не пройден. Планировщик живёт в боте (там Bot);
бэкенд держит данные и логику — бот раз в минуту дёргает `due_reminders` и шлёт.
"""
from __future__ import annotations

from datetime import datetime

import pytz
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import models as m
from app.services import clock, i18n

DEFAULT_TZ = clock.DEFAULT_TZ

# слот → (атрибут часа, атрибут минуты, атрибут даты последней отправки)
SLOTS = {
    "morning":   ("reminder_morning_hour", "reminder_morning_minute", "last_morning_date"),
    "afternoon": ("reminder_afternoon_hour", "reminder_afternoon_minute", "last_afternoon_date"),
    "evening":   ("reminder_hour", "reminder_minute", "last_reminded_date"),
}


def _tz(name: str | None) -> pytz.BaseTzInfo:
    """Единый резолвер таймзоны — тот же, что у дневного гейта (services/clock)."""
    return clock.tz(name)


def get_settings(db: Session, user_id: int) -> dict:
    u = db.get(m.User, user_id)
    return {
        "timezone": u.timezone or DEFAULT_TZ,
        "language": i18n.resolve_language(u),
        "morning": {"hour": u.reminder_morning_hour, "minute": u.reminder_morning_minute},
        "afternoon": {"hour": u.reminder_afternoon_hour, "minute": u.reminder_afternoon_minute},
        "evening": {"hour": u.reminder_hour, "minute": u.reminder_minute},
    }


def update_settings(db: Session, user_id: int, *, timezone: str | None = None,
                    language: str | None = None, slot: str | None = None,
                    hour: int | None = None, minute: int | None = None) -> dict:
    u = db.get(m.User, user_id)
    if timezone is not None:
        pytz.timezone(timezone)                         # бросит, если неверная
        u.timezone = timezone
    if language is not None:
        if language not in i18n.SUPPORTED_LANGUAGES:
            raise ValueError(f"неизвестный язык: {language}")
        u.preferred_language = language
    if slot is not None:
        if slot not in SLOTS:
            raise ValueError(f"неизвестный слот: {slot}")
        h_attr, mi_attr, _ = SLOTS[slot]
        if hour is not None:
            if not (0 <= int(hour) <= 23):
                raise ValueError("час 0..23")
            setattr(u, h_attr, int(hour))
        if minute is not None:
            if not (0 <= int(minute) <= 59):
                raise ValueError("минута 0..59")
            setattr(u, mi_attr, int(minute))
    db.commit()
    return get_settings(db, user_id)


def due_reminders(db: Session) -> list[dict]:
    """Кандидаты на напоминание СЕЙЧАС (по слотам). НЕ стемпит — слот помечается отправленным
    только после фактической доставки (`mark_reminded`/`mark_reminded_by_user`). Пока не
    доставлено — кандидат возвращается каждый тик, поэтому напоминание не теряется, даже если
    канал был недоступен. Напоминания всегда включены (их нельзя отключить, можно менять время).

    Канало-независимо: раньше требовался привязанный Telegram, теперь кандидат отдаётся
    всегда (`provider_user_id` — `None`, если Telegram не привязан) — доставкой занимается
    каждый канал сам (бот — по chat_id, APNs — по `user_id`, см. `push.send_due_reminders`)."""
    now_utc = datetime.now(pytz.utc)
    out: list[dict] = []
    users = db.execute(select(m.User)).scalars().all()
    for u in users:
        local = now_utc.astimezone(_tz(u.timezone))
        today = local.date()
        # активная normal-запись и сегодняшний день не пройден
        enr = db.execute(
            select(m.Enrollment).where(m.Enrollment.user_id == u.id,
                                       m.Enrollment.status == "active",
                                       m.Enrollment.mode == "normal")
        ).scalars().first()
        if not enr:
            continue
        # уже закрыли день (вечернюю сессию) сегодня → сегодня не напоминаем
        closed_today = db.execute(
            select(m.DailyEntry.id).where(m.DailyEntry.enrollment_id == enr.id,
                                          m.DailyEntry.entry_date == today,
                                          m.DailyEntry.evening_done.is_(True)).limit(1)
        ).scalar_one_or_none()
        if closed_today:
            continue
        # открыт ли текущий день (утренняя сессия пройдена)
        cur = db.execute(
            select(m.DailyEntry).where(m.DailyEntry.enrollment_id == enr.id,
                                       m.DailyEntry.week_n == enr.current_week,
                                       m.DailyEntry.day_n == enr.current_day)
        ).scalars().first()
        opened = cur is not None and cur.morning_done
        ident = db.execute(
            select(m.UserIdentity).where(m.UserIdentity.user_id == u.id,
                                         m.UserIdentity.provider == "telegram")
        ).scalars().first()
        language = i18n.resolve_language(u)
        mod = db.get(m.Module, enr.module_code)
        mod_name = enr.module_code
        if mod:
            mod_name = i18n.overlay(db, m.ModuleTranslation, m.ModuleTranslation.module_code,
                                    mod.code, language, mod, ["name"])["name"]
        for slot, (h_attr, mi_attr, date_attr) in SLOTS.items():
            if getattr(u, date_attr) == today:           # уже доставлено сегодня
                continue
            if (local.hour, local.minute) < (getattr(u, h_attr), getattr(u, mi_attr)):
                continue
            # утро — только если день ещё не открыт; день/обед и вечер — пока день не закрыт
            if slot == "morning" and opened:
                continue                                 # утро неактуально — не шлём (и не помечаем)
            out.append({"user_id": u.id,
                        "provider_user_id": ident.provider_user_id if ident else None,
                        "slot": slot, "module_name": mod_name, "language": language,
                        "week": enr.current_week, "day": enr.current_day})
    return out                                           # без стемпа — пометит mark_reminded*


def _stamp(db: Session, user_id: int, slot: str) -> dict:
    u = db.get(m.User, user_id)
    if u is None:
        return {"ok": False}
    _, _, date_attr = SLOTS[slot]
    local = datetime.now(pytz.utc).astimezone(_tz(u.timezone))
    setattr(u, date_attr, local.date())
    db.commit()
    return {"ok": True}


def mark_reminded(db: Session, provider_user_id: str | int, slot: str) -> dict:
    """Пометить слот доставленным через Telegram (стемпит last_*_date). Вызывается ботом
    ПОСЛЕ фактической отправки — чтобы напоминание не терялось при сбое."""
    if slot not in SLOTS:
        raise ValueError(f"неизвестный слот: {slot}")
    ident = db.execute(
        select(m.UserIdentity).where(m.UserIdentity.provider == "telegram",
                                     m.UserIdentity.provider_user_id == str(provider_user_id))
    ).scalars().first()
    if not ident:
        return {"ok": False}
    return _stamp(db, ident.user_id, slot)


def mark_reminded_by_user(db: Session, user_id: int, slot: str) -> dict:
    """То же, что `mark_reminded`, но для каналов, которые уже знают `user_id` напрямую
    (APNs, см. `push.send_due_reminders`) — без поиска Telegram-привязки."""
    if slot not in SLOTS:
        raise ValueError(f"неизвестный слот: {slot}")
    return _stamp(db, user_id, slot)
