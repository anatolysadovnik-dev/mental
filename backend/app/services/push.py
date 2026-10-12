"""APNs: пуш-напоминания для iOS.

Зачем отдельно от бота: `settings.due_reminders` отбирает кандидатов независимо от
канала, но доставляет их только Telegram-бот (он фильтрует `provider == "telegram"`).
У приложения своего канала доставки не было. Здесь он появляется: те же слоты и то же
время (таймзона пользователя), но доставка через APNs на зарегистрированные устройства.

Ключ .p8 не коммитится: путь и идентификаторы берутся из окружения. Пока ключа нет,
`send()` ничего не отправляет и честно возвращает `sent: 0` с причиной — сервис не
падает и не мешает остальному API.
"""
from __future__ import annotations

import time
from datetime import UTC, datetime

import httpx
import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import models as m
from app.config import settings

PROD_HOST = "https://api.push.apple.com"
SANDBOX_HOST = "https://api.sandbox.push.apple.com"
_TOKEN_TTL = 45 * 60                    # APNs разрешает не более часа; берём с запасом

_token_cache: dict[str, tuple[str, float]] = {}


class PushDisabled(Exception):
    """APNs не настроен (нет .p8 / key id / team id)."""


def _provider_token() -> str:
    """JWT для APNs (ES256, подпись ключом .p8). Кэшируем — Apple не любит частую выдачу."""
    if not settings.apns_enabled:
        raise PushDisabled("APNs не настроен: заполните APNS_KEY_PATH/APNS_KEY_ID/APNS_TEAM_ID")
    cached = _token_cache.get("t")
    now = time.time()
    if cached and cached[1] > now:
        return cached[0]
    with open(settings.apns_key_path, "rb") as fh:
        key = fh.read()
    token = jwt.encode({"iss": settings.apns_team_id, "iat": int(now)},
                       key, algorithm="ES256",
                       headers={"kid": settings.apns_key_id})
    _token_cache["t"] = (token, now + _TOKEN_TTL)
    return token


def register_device(db: Session, user_id: int, token: str, *, platform: str = "ios",
                    sandbox: bool = False, language: str | None = None) -> dict:
    """Запомнить device token. Один и тот же токен может переехать на другого
    пользователя (тот же телефон, другой вход) — тогда просто меняем владельца."""
    token = (token or "").strip()
    if not token:
        raise ValueError("пустой device token")
    row = db.execute(select(m.DeviceToken).where(m.DeviceToken.token == token)).scalar_one_or_none()
    if row is None:
        row = m.DeviceToken(user_id=user_id, token=token)
        db.add(row)
    row.user_id = user_id
    row.platform = platform
    row.sandbox = sandbox
    row.language = language
    row.last_seen_at = datetime.now(UTC).replace(tzinfo=None)
    db.commit()
    return {"registered": True, "id": row.id}


def unregister_device(db: Session, token: str) -> dict:
    row = db.execute(select(m.DeviceToken).where(m.DeviceToken.token == token)).scalar_one_or_none()
    if row is None:
        return {"deleted": 0}
    db.delete(row)
    db.commit()
    return {"deleted": 1}


def send(db: Session, user_id: int, *, title: str, body: str,
         slot: str | None = None) -> dict:
    """Отправить пуш на все устройства пользователя.

    Возвращает {sent, failed, reason?} и НЕ бросает исключение при ненастроенном APNs —
    вызывающий (планировщик) не должен падать из-за отсутствия ключа.
    """
    devices = db.execute(
        select(m.DeviceToken).where(m.DeviceToken.user_id == user_id)
    ).scalars().all()
    if not devices:
        return {"sent": 0, "failed": 0, "reason": "нет зарегистрированных устройств"}
    try:
        auth = _provider_token()
    except PushDisabled as e:
        return {"sent": 0, "failed": 0, "reason": str(e)}

    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}}
    if slot:
        payload["slot"] = slot

    sent = failed = 0
    stale: list[m.DeviceToken] = []
    with httpx.Client(http2=True, timeout=10.0) as client:
        for d in devices:
            host = SANDBOX_HOST if d.sandbox else PROD_HOST
            try:
                r = client.post(
                    f"{host}/3/device/{d.token}", json=payload,
                    headers={"authorization": f"bearer {auth}",
                             "apns-topic": settings.apns_topic,
                             "apns-push-type": "alert"})
            except httpx.HTTPError:
                failed += 1
                continue
            if r.status_code == 200:
                sent += 1
            else:
                failed += 1
                # Apple сообщает, что токен больше не существует → чистим, иначе
                # мёртвые токены копятся и каждый тик тратят запрос
                if r.status_code == 410 or (r.status_code == 400
                                            and "BadDeviceToken" in r.text):
                    stale.append(d)
    for d in stale:
        db.delete(d)
    if stale:
        db.commit()
    return {"sent": sent, "failed": failed, "pruned": len(stale)}


# слот → {язык: шаблон}; только ru/en написаны вручную, остальные языки падают на ru —
# машинный перевод короткого пуша рискует звучать криво (см. bot/texts.py::_SLOT_NUDGE
# для аналогичных телеграм-формулировок, они тоже только на ru).
_SLOT_BODY = {
    "ru": {
        "morning": "Доброе утро! Сегодняшний день маршрута «{m}» ждёт вас.",
        "afternoon": "Напоминание про задание дня в маршруте «{m}».",
        "evening": "Вечер — время подвести день. Маршрут «{m}» ещё открыт.",
    },
    "en": {
        "morning": "Good morning! Today's step in \"{m}\" is ready for you.",
        "afternoon": "A gentle reminder about today's task in \"{m}\".",
        "evening": "Evening check-in — \"{m}\" is still open for today.",
    },
}


def _nudge_text(slot: str, module_name: str, language: str) -> tuple[str, str]:
    body_map = _SLOT_BODY.get(language, _SLOT_BODY["ru"])
    body = body_map.get(slot, body_map["evening"]).format(m=module_name)
    return "Verge", body


def send_due_reminders(db: Session) -> dict:
    """Пуш-канал для `settings.due_reminders` — те же кандидаты, что видит бот, но
    стемпится отдельно: по `user_id` (`mark_reminded_by_user`), а не по Telegram chat_id,
    и только когда реально отправлено (`sent > 0`) — иначе кандидат остаётся и его ещё
    может доставить бот, если аккаунт также привязан к Telegram."""
    from app.services import settings as settings_svc     # локальный импорт — без цикла на уровне модуля

    sent_total = 0
    for item in settings_svc.due_reminders(db):
        title, body = _nudge_text(item["slot"], item.get("module_name", ""),
                                  item.get("language", "ru"))
        result = send(db, item["user_id"], title=title, body=body, slot=item["slot"])
        if result.get("sent", 0) > 0:
            settings_svc.mark_reminded_by_user(db, item["user_id"], item["slot"])
            sent_total += result["sent"]
    return {"sent": sent_total}
