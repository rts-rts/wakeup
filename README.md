# Wake-on-LAN Monitor

Сервис периодически пингует список компьютеров. Если компьютер недоступен — отправляет WoL-пакет, повторяет до 5 раз с интервалом 1 минута, затем шлёт уведомление в Telegram.

## Файлы

```
wakeup/
├── computers.conf        — список хостов
├── wakeup_monitor.sh     — главный скрипт
├── telegram_sender.sh    — отправка сообщений в Telegram
├── telegram.conf         — хранится токен бота и ID чата Telegram
├── wakeup-monitor.service — systemd unit
├── wakeup-monitor.timer  — systemd timer (каждые 10 минут)
└── state/                — создаётся автоматически
    └── <name>.notified   — маркер "уведомление уже отправлено"
```

Лог: `/var/log/wakeup_monitor.log`

## Управление хостами

Файл `computers.conf` — по одной строке на хост, поля разделяются пробелами или табуляцией:

```
# name         ip               mac
ARTMAG01       192.168.10.100   18:c0:4d:08:e9:af
SYS            192.168.10.81    d8:bb:c1:07:06:aa
```

- Строки начинающиеся с `#` и пустые строки игнорируются
- MAC нужен для Wake-on-LAN; посмотреть на целевом компьютере: `ip link` или `arp -n <ip>`
- После изменения файла перезапускать сервис не нужно — читается при каждом запуске

## Как работает логика

```
Каждые 10 минут для каждого хоста:

  ping OK?
  ├── ДА + был помечен как недоступный → уведомление "вернулся", снять пометку
  └── НЕТ + уже помечен              → пропустить (не спамить)
      НЕТ + не помечен               → WoL-цикл:
          Попытка 1: wakeonlan <mac> → ждать 60с → ping?
          Попытка 2: ...
          ...
          Попытка 5: если всё ещё нет → уведомление в Telegram + пометить хост
```

## Управление сервисом

```bash
# Статус таймера (когда следующий запуск)
systemctl list-timers wakeup-monitor.timer

# Ручной запуск
sudo systemctl start wakeup-monitor.service

# Лог последнего запуска
journalctl -u wakeup-monitor.service

# Остановить/выключить
sudo systemctl stop wakeup-monitor.timer
sudo systemctl disable wakeup-monitor.timer

# Включить снова
sudo systemctl enable --now wakeup-monitor.timer
```

## Просмотр лога

```bash
# Последние записи
tail -f /var/log/wakeup_monitor.log

# Всё с начала
cat /var/log/wakeup_monitor.log
```

## Состояние хостов

```bash
# Посмотреть кто сейчас помечен как "недоступен и уведомлён"
ls /home/user/wakeup/state/

# Вручную сбросить пометку (например, после ремонта)
rm /home/user/wakeup/state/ARTMAG01.notified

# Сбросить все пометки
rm -f /home/user/wakeup/state/*.notified
```

## Настройка Telegram

Токен бота и Chat ID хранятся в начале `telegram.conf`:

```bash
BOT_TOKEN="..."
CHAT_ID="..."
```

Получить Chat ID: запустить `./telegram_sender.sh --get-updates` после того как написать боту любое сообщение.

## Тест WoL вручную

```bash
# Проверить доступность
ping -c 3 192.168.10.100

# Отправить WoL-пакет напрямую
wakeonlan 18:c0:4d:08:e9:af

# Тест Telegram
./telegram_sender.sh -m "Тест"
```

## Требования

- `wakeonlan` — `sudo apt install wakeonlan`
- `curl`, `jq` — нужны для `telegram_sender.sh`
- Компьютеры должны поддерживать Wake-on-LAN и быть настроены в BIOS/UEFI
