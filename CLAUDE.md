# CLAUDE.md — Wake-on-LAN Monitor

## Что это

Bash-сервис мониторинга доступности компьютеров в локальной сети с автоматическим пробуждением через Wake-on-LAN и уведомлениями в Telegram.

## Структура

```
wakeup/
├── computers.conf         — список хостов (name ip mac, пробел/таб)
├── wakeup_monitor.sh      — главный скрипт мониторинга
├── telegram_sender.sh     — отправка в Telegram через Bot API
├── wakeup-monitor.service — /etc/systemd/system/ (oneshot)
├── wakeup-monitor.timer   — /etc/systemd/system/ (каждые 10 минут)
└── state/                 — runtime-директория, создаётся скриптом
    └── <name>.notified    — маркер "уже уведомлено", избегает спама
```

Лог: `/var/log/wakeup_monitor.log` (ротация: обрезается до 1000 строк при превышении 2000)

## Ключевые решения и причины

- **wakeonlan** (не ethtool) — именно этот инструмент отправляет magic packet; установлен в `/usr/bin/wakeonlan`
- **State-файлы** вместо БД — простейший способ помнить состояние между запусками systemd oneshot
- **5 попыток × 60с** — цикл внутри одного запуска скрипта, не между запусками таймера
- **Telegram через telegram_sender.sh -m "..."** — вызов существующего скрипта, не прямой curl
- **SCRIPT_DIR** — все пути относительно расположения скрипта, чтобы systemd мог запускать из любого CWD

## Поведение при изменениях

- `computers.conf` — читается при каждом запуске, перезапуск сервиса не нужен
- Systemd units — после изменения: `sudo systemctl daemon-reload`
- Параметры (`MAX_ATTEMPTS`, `WAIT_BETWEEN`) — в начале `wakeup_monitor.sh`

## Telegram

- Токен и Chat ID захардкожены в `telegram_sender.sh` (BOT_TOKEN, CHAT_ID)
- Сообщения в HTML parse_mode — можно использовать `<b>`, `<code>`, `<i>`
- Многострочные сообщения работают (проверено `send_system_notification` в telegram_sender.sh)

## Типичные задачи

**Добавить хост:** вписать строку в `computers.conf`

**Хост постоянно offline и уведомления надоели:** `rm state/<name>.notified`

**Изменить интервал таймера:** отредактировать `OnCalendar` в `wakeup-monitor.timer`, затем `sudo systemctl daemon-reload`

**Изменить количество попыток WoL:** `MAX_ATTEMPTS=5` в начале `wakeup_monitor.sh`

**Проверить статус:** `systemctl list-timers wakeup-monitor.timer` и `cat /var/log/wakeup_monitor.log`
