# CLAUDE.md — Wake-on-LAN Telegram Bot

## Что это

Python-бот в Telegram-группе: показывает доступность компьютеров в локальной сети и включает их по кнопке через Wake-on-LAN. Хосты с флагом `auto` бот будит сам.

## Структура

```
wakeup/
├── bot.py                 — бот (python-telegram-bot v22, long polling, JobQueue)
├── pyproject.toml, uv.lock — зависимости, управляются uv
├── computers.conf         — список хостов (name ip mac [auto], пробел/таб)
├── telegram.conf          — BOT_TOKEN, CHAT_ID (id группы); не в git
├── telegram_sender.sh     — отдельная CLI-утилита отправки; бот её не использует
├── wakeup-bot.service     — /etc/systemd/system/ (Type=simple, Restart=always)
├── tests/test_config.py   — pytest на парсинг конфигов
└── state/                 — runtime-директория, создаётся ботом
    └── <name>.notified    — маркер "auto-хост недоступен, уже уведомлено"
```

Лог: stdout → journald (`journalctl -u wakeup-bot`)

## Ключевые решения и причины

- **Группа, а не канал** — в канале подписчики не могут писать команды и жать кнопки
- **Доступ = членство в группе** — handlers фильтруются по `CHAT_ID`, в личке бот молчит
- **Один процесс вместо timer+oneshot** — периодическая проверка auto-хостов через `JobQueue.run_repeating`
- **Бот шлёт сообщения сам** (python-telegram-bot), а не через `telegram_sender.sh`
- **wakeonlan** (не ethtool) — `/usr/bin/wakeonlan`
- **State-файлы** — помнят "уже уведомлено" между перезапусками
- **5 попыток × 60с** — и для кнопки, и для auto
- **SCRIPT_DIR** — пути относительно `bot.py`, чтобы systemd мог запускать из любого CWD
- **uv** — для зависимостей (`uv sync`, `uv run`)
- **Отдельный токен бота** — на сервере работает `telegram-bot.service` (`/home/user/telegram_bot`, мониторинг сервера) со своим ботом; общий токен даёт `Conflict` в getUpdates
- **Сервис от `User=user`** — root не нужен (ping и wakeonlan работают от пользователя), uv установлен в `/home/user/.local/bin/uv`

## Поведение при изменениях

- `computers.conf` — читается при каждой команде/проверке, перезапуск не нужен
- `bot.py`, `telegram.conf` — `sudo systemctl restart wakeup-bot`
- Systemd unit — после изменения: `sudo systemctl daemon-reload`
- Параметры (`MAX_ATTEMPTS`, `WAIT_BETWEEN`, `CHECK_INTERVAL`) — в начале `bot.py`

## Telegram

- Сообщения в HTML parse_mode; имена/IP экранируются `html.escape`
- Команды: `/status` (`/start`); callback_data: `wake:<name>`, `refresh`
- Privacy mode включён: в группе бот получает только команды, не обычный текст
- CHAT_ID группы `WakeUp_MASOMI_1` — отрицательный; при преобразовании в супергруппу меняется на `-100…`

## Типичные задачи

**Добавить хост:** вписать строку в `computers.conf` (с `auto`, если будить автоматически)

**Хост постоянно offline и уведомления надоели:** убрать `auto` или `rm state/<name>.notified` для повторной попытки

**Тесты:** `uv run pytest`

**Проверить статус:** `systemctl status wakeup-bot` и `journalctl -u wakeup-bot`
