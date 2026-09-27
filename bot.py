"""Telegram-бот: показывает состояние компьютеров и включает их через Wake-on-LAN."""

import asyncio
import html
import logging
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.error import BadRequest
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    filters,
)

SCRIPT_DIR = Path(__file__).resolve().parent
CONF_FILE = SCRIPT_DIR / "computers.conf"
TELEGRAM_CONF = SCRIPT_DIR / "telegram.conf"
STATE_DIR = SCRIPT_DIR / "state"
WAKEONLAN = "/usr/bin/wakeonlan"
MAX_ATTEMPTS = 5
WAIT_BETWEEN = 60  # секунд между повторами WoL
CHECK_INTERVAL = 600  # период проверки auto-хостов, секунд

log = logging.getLogger("wakeup-bot")


@dataclass(frozen=True)
class Host:
    name: str
    ip: str
    mac: str
    auto: bool = False


def load_telegram_conf(path: Path = TELEGRAM_CONF) -> tuple[str, int]:
    """Читает BOT_TOKEN и CHAT_ID из shell-подобного telegram.conf."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    missing = [k for k in ("BOT_TOKEN", "CHAT_ID") if not values.get(k)]
    if missing:
        raise ValueError(f"в {path} не заданы: {', '.join(missing)}")
    return values["BOT_TOKEN"], int(values["CHAT_ID"])


def load_hosts(path: Path = CONF_FILE) -> list[Host]:
    """Формат строки: name ip mac [auto]. # и пустые строки игнорируются."""
    hosts = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3:
            log.warning("Skipping malformed line: %s", line)
            continue
        auto = len(parts) > 3 and parts[3].lower() == "auto"
        hosts.append(Host(parts[0], parts[1], parts[2], auto))
    return hosts


def find_host(name: str) -> Host | None:
    return next((h for h in load_hosts() if h.name == name), None)


async def ping(ip: str) -> bool:
    proc = await asyncio.create_subprocess_exec(
        "ping", "-c", "2", "-W", "1", ip,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    return await proc.wait() == 0


async def send_wol(mac: str) -> None:
    proc = await asyncio.create_subprocess_exec(
        WAKEONLAN, mac,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    await proc.wait()


async def wake_until_online(host: Host) -> bool:
    for attempt in range(1, MAX_ATTEMPTS + 1):
        log.info("[%s] WoL attempt %d/%d -> %s", host.name, attempt, MAX_ATTEMPTS, host.mac)
        await send_wol(host.mac)
        await asyncio.sleep(WAIT_BETWEEN)
        if await ping(host.ip):
            log.info("[%s] Came online after attempt %d", host.name, attempt)
            return True
    log.info("[%s] Still offline after %d attempts", host.name, MAX_ATTEMPTS)
    return False


def now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def notified_marker(host: Host) -> Path:
    return STATE_DIR / f"{host.name}.notified"


# ================== Статус ==================

async def render_status(waking: set[str]) -> tuple[str, InlineKeyboardMarkup]:
    hosts = load_hosts()
    online = await asyncio.gather(*(ping(h.ip) for h in hosts))
    lines = ["🖥 <b>Состояние компьютеров</b>", ""]
    buttons = []
    for host, up in zip(hosts, online):
        name = html.escape(host.name)
        if up:
            icon = "🟢"
        elif host.name in waking:
            icon = "⏳"
        else:
            icon = "🔴"
            buttons.append([InlineKeyboardButton(f"🔌 Включить {host.name}",
                                                 callback_data=f"wake:{host.name}")])
        lines.append(f"{icon} <b>{name}</b> <code>{html.escape(host.ip)}</code>")
    lines += ["", f"🕐 {now()}"]
    buttons.append([InlineKeyboardButton("🔄 Обновить", callback_data="refresh")])
    return "\n".join(lines), InlineKeyboardMarkup(buttons)


async def status_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    text, markup = await render_status(context.bot_data["waking"])
    await update.effective_message.reply_text(text, parse_mode=ParseMode.HTML, reply_markup=markup,
                                              do_quote=False)


# ================== Кнопки ==================

async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if query.message is None or query.message.chat.id != context.bot_data["chat_id"]:
        await query.answer()
        return

    waking: set[str] = context.bot_data["waking"]

    if query.data == "refresh":
        await query.answer("Обновляю…")
    elif query.data.startswith("wake:"):
        host = find_host(query.data.removeprefix("wake:"))
        if host is None:
            await query.answer("Хост не найден в computers.conf", show_alert=True)
            return
        if host.name in waking:
            await query.answer(f"{host.name} уже включается")
            return
        waking.add(host.name)  # до первого await, иначе двойное нажатие пройдёт проверку
        await query.answer(f"Включаю {host.name}…")
        user = query.from_user
        who = f"@{user.username}" if user.username else user.full_name
        log.info("[%s] Wake requested by %s (%s)", host.name, who, user.id)
        await context.bot.send_message(
            context.bot_data["chat_id"],
            f"⏳ Включаю <b>{html.escape(host.name)}</b> (запросил {html.escape(who)})…",
            parse_mode=ParseMode.HTML,
        )
        context.application.create_task(manual_wake(host, context), update=update)
    else:
        await query.answer()
        return

    text, markup = await render_status(waking)
    try:
        await query.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=markup)
    except BadRequest as e:
        if "message is not modified" not in str(e).lower():
            raise


async def manual_wake(host: Host, context: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        ok = await ping(host.ip) or await wake_until_online(host)
    finally:
        context.bot_data["waking"].discard(host.name)
    name = html.escape(host.name)
    text = (f"✅ <b>{name}</b> в сети" if ok
            else f"❌ <b>{name}</b> не включился после {MAX_ATTEMPTS} попыток WoL")
    await context.bot.send_message(context.bot_data["chat_id"], text, parse_mode=ParseMode.HTML)


# ================== Автопробуждение (хосты с флагом auto) ==================

async def process_auto_host(host: Host, context: ContextTypes.DEFAULT_TYPE) -> None:
    chat_id = context.bot_data["chat_id"]
    name, ip, mac = (html.escape(v) for v in (host.name, host.ip, host.mac))
    marker = notified_marker(host)

    if await ping(host.ip):
        if marker.exists():
            await context.bot.send_message(
                chat_id,
                f"✅ <b>Хост вернулся в сеть</b>\n\n📍 Имя: <code>{name}</code>\n"
                f"🌐 IP: <code>{ip}</code>\n🕐 Время: {now()}",
                parse_mode=ParseMode.HTML,
            )
            marker.unlink(missing_ok=True)
        return

    if marker.exists() or host.name in context.bot_data["waking"]:
        return

    log.info("[%s] Offline, auto wake", host.name)
    context.bot_data["waking"].add(host.name)
    try:
        ok = await wake_until_online(host)
    finally:
        context.bot_data["waking"].discard(host.name)

    if ok:
        await context.bot.send_message(
            chat_id,
            f"✅ <b>Хост пробужден через WoL</b>\n\n📍 Имя: <code>{name}</code>\n"
            f"🌐 IP: <code>{ip}</code>\n🔌 MAC: <code>{mac}</code>\n🕐 Время: {now()}",
            parse_mode=ParseMode.HTML,
        )
        return

    await context.bot.send_message(
        chat_id,
        f"❌ <b>Хост недоступен</b>\n\n📍 Имя: <code>{name}</code>\n"
        f"🌐 IP: <code>{ip}</code>\n🔌 MAC: <code>{mac}</code>\n"
        f"🔁 Попыток WoL: {MAX_ATTEMPTS}\n🕐 Время: {now()}",
        parse_mode=ParseMode.HTML,
    )
    marker.touch()


async def auto_check(context: ContextTypes.DEFAULT_TYPE) -> None:
    hosts = [h for h in load_hosts() if h.auto]
    await asyncio.gather(*(process_auto_host(h, context) for h in hosts))


# ================== MAIN ==================

def check_setup() -> None:
    """Падаем сразу с понятной ошибкой, а не при первом нажатии кнопки."""
    problems = [f"нет файла {p}" for p in (TELEGRAM_CONF, CONF_FILE) if not p.exists()]
    problems += [f"не найдена программа {p}" for p in (WAKEONLAN, "ping") if shutil.which(p) is None]
    if problems:
        raise SystemExit("Ошибка запуска: " + "; ".join(problems))


def main() -> None:
    logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    check_setup()
    STATE_DIR.mkdir(exist_ok=True)

    try:
        token, chat_id = load_telegram_conf()
    except ValueError as e:
        raise SystemExit(f"Ошибка запуска: {e}")
    app = Application.builder().token(token).build()
    app.bot_data["chat_id"] = chat_id
    app.bot_data["waking"] = set()

    app.add_handler(CommandHandler(["status", "start"], status_cmd, filters=filters.Chat(chat_id)))
    app.add_handler(CallbackQueryHandler(on_button))
    app.job_queue.run_repeating(auto_check, interval=CHECK_INTERVAL, first=30)

    log.info("Bot started, chat_id=%s", chat_id)
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
