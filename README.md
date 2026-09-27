# Wake-on-LAN Telegram Bot

Telegram-бот в закрытой группе: участники смотрят, какие компьютеры включены, и включают нужный кнопкой (Wake-on-LAN). Держать все компьютеры постоянно включёнными не нужно.

Хосты с флагом `auto` бот проверяет каждые 10 минут и будит сам (как раньше делал `wakeup_monitor.sh`).

## Файлы

```
wakeup/
├── bot.py                — бот (python-telegram-bot, long polling)
├── pyproject.toml        — зависимости (uv)
├── computers.conf        — список хостов
├── telegram.conf         — токен бота и ID группы (не в git)
├── telegram_sender.sh    — отдельная утилита отправки сообщений (бот её не использует)
├── wakeup-bot.service    — systemd unit
├── tests/                — pytest
└── state/                — создаётся автоматически
    └── <name>.notified   — маркер "auto-хост недоступен, уведомление отправлено"
```

Лог: `journalctl -u wakeup-bot`

## Как пользоваться в Telegram

- `/status` — список компьютеров: 🟢 включён, 🔴 выключен, ⏳ включается
- Кнопка **🔌 Включить NAME** — отправляет WoL, до 5 попыток с интервалом 1 минута; итог бот пишет в группу вместе с именем того, кто нажал
- Кнопка **🔄 Обновить** — перепроверить состояние

Бот отвечает только в группе с `CHAT_ID` из `telegram.conf`. В личке и чужих группах он молчит. Доступ = членство в группе.

## Установка

1. Создать бота у @BotFather, токен записать в `telegram.conf` (пример — `telegram.conf.example`).
2. Создать **группу** (не канал: в канале подписчики не могут нажимать кнопки и писать команды), добавить в неё бота.
3. Написать в группе любое сообщение, затем `./telegram_sender.sh --get-updates` — `chat_id` группы (отрицательное число) записать в `CHAT_ID`.
   Если бот не видит сообщения, отправьте в группе `/start@имя_бота` или отключите privacy mode у @BotFather.
4. Установить зависимости:
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh   # если uv нет
   sudo apt install wakeonlan
   uv sync
   ```
5. Проверить путь к uv (`which uv`) в `ExecStart` файла `wakeup-bot.service`, затем:
   ```bash
   sudo cp wakeup-bot.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now wakeup-bot
   ```

### Переход со старой версии

```bash
sudo systemctl disable --now wakeup-monitor.timer
sudo rm /etc/systemd/system/wakeup-monitor.{service,timer}
sudo systemctl daemon-reload
```

## Управление хостами

Файл `computers.conf` — по одной строке на хост, поля разделяются пробелами или табуляцией:

```
# name         ip               mac                 [auto]
ARTMAG01       192.168.10.100   18:c0:4d:08:e9:af
SYS            192.168.10.81    d8:bb:c1:07:06:aa   auto
```

- Строки, начинающиеся с `#`, и пустые строки игнорируются
- `auto` — бот сам будит хост, если он выключен; без флага — только по кнопке
- MAC посмотреть на целевом компьютере: `ip link` или `arp -n <ip>`
- Файл читается при каждой команде — перезапуск бота не нужен

## Логика auto-хостов

```
Каждые 10 минут для каждого хоста с флагом auto:

  ping OK?
  ├── ДА + был помечен как недоступный → уведомление "вернулся", снять пометку
  └── НЕТ + уже помечен              → пропустить (не спамить)
      НЕТ + не помечен               → WoL-цикл (5 × 60с):
          успех → уведомление "пробужден"
          нет   → уведомление "недоступен" + пометить хост
```

Сбросить пометку: `rm state/<name>.notified`

## Управление сервисом

```bash
systemctl status wakeup-bot
journalctl -u wakeup-bot -f
sudo systemctl restart wakeup-bot
```

## Разработка

```bash
uv run pytest            # тесты
uv run python bot.py     # запуск вручную
```

Параметры (`MAX_ATTEMPTS`, `WAIT_BETWEEN`, `CHECK_INTERVAL`) — в начале `bot.py`.

## Требования

- Python ≥ 3.11, `uv`
- `wakeonlan` — `sudo apt install wakeonlan`
- `curl`, `jq` — только для `telegram_sender.sh`
- Компьютеры должны поддерживать Wake-on-LAN и быть настроены в BIOS/UEFI
