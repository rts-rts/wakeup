#!/bin/bash

# Telegram Message Sender Script
# Автор: Assistant
# Описание: Скрипт для отправки сообщений в Telegram через Bot API

# ================== КОНФИГУРАЦИЯ ==================
# Секреты загружаются из конфиг-файла (не коммитить!)
CONFIG_FILE="${SCRIPT_DIR}telegram.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Ошибка: файл $CONFIG_FILE не найден"
    exit 1
fi

source "$CONFIG_FILE"

# Проверка загрузки
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "Ошибка: BOT_TOKEN или CHAT_ID не установлены в $CONFIG_FILE"
    exit 1
fi

# URL API Telegram
TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}"

# Файл для логирования
LOG_FILE="/var/log/telegram_sender.log"

# ================== ФУНКЦИИ ==================

# Функция логирования
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Функция проверки зависимостей
check_dependencies() {
    local deps=("curl" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Ошибка: $dep не установлен. Установите: sudo apt install $dep"
            exit 1
        fi
    done
}

# Функция отправки простого текстового сообщения
send_message() {
    local text="$1"
    local parse_mode="${2:-HTML}"  # По умолчанию HTML
    
    if [ -z "$text" ]; then
        echo "Ошибка: Текст сообщения не может быть пустым"
        return 1
    fi
    
    local response=$(curl -s -X POST \
        "${TELEGRAM_API}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"${CHAT_ID}\",
            \"text\": \"${text}\",
            \"parse_mode\": \"${parse_mode}\"
        }")
    
    # Проверка результата
    local ok=$(echo "$response" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
        echo "✅ Сообщение успешно отправлено"
        log_message "SUCCESS: Message sent to $CHAT_ID"
        return 0
    else
        local error=$(echo "$response" | jq -r '.description')
        echo "❌ Ошибка отправки: $error"
        log_message "ERROR: Failed to send message - $error"
        return 1
    fi
}

# Функция отправки файла
send_file() {
    local file_path="$1"
    local caption="$2"
    
    if [ ! -f "$file_path" ]; then
        echo "Ошибка: Файл $file_path не найден"
        return 1
    fi
    
    local response=$(curl -s -X POST \
        "${TELEGRAM_API}/sendDocument" \
        -F "chat_id=${CHAT_ID}" \
        -F "document=@${file_path}" \
        -F "caption=${caption}")
    
    local ok=$(echo "$response" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
        echo "✅ Файл успешно отправлен"
        log_message "SUCCESS: File $file_path sent to $CHAT_ID"
        return 0
    else
        local error=$(echo "$response" | jq -r '.description')
        echo "❌ Ошибка отправки файла: $error"
        log_message "ERROR: Failed to send file - $error"
        return 1
    fi
}

# Функция отправки изображения
send_photo() {
    local photo_path="$1"
    local caption="$2"
    
    if [ ! -f "$photo_path" ]; then
        echo "Ошибка: Изображение $photo_path не найдено"
        return 1
    fi
    
    local response=$(curl -s -X POST \
        "${TELEGRAM_API}/sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=@${photo_path}" \
        -F "caption=${caption}")
    
    local ok=$(echo "$response" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
        echo "✅ Изображение успешно отправлено"
        return 0
    else
        local error=$(echo "$response" | jq -r '.description')
        echo "❌ Ошибка отправки изображения: $error"
        return 1
    fi
}

# Функция отправки сообщения с кнопками (Inline Keyboard)
send_with_buttons() {
    local text="$1"
    local buttons="$2"  # JSON строка с кнопками
    
    local response=$(curl -s -X POST \
        "${TELEGRAM_API}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"${CHAT_ID}\",
            \"text\": \"${text}\",
            \"parse_mode\": \"HTML\",
            \"reply_markup\": ${buttons}
        }")
    
    local ok=$(echo "$response" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
        echo "✅ Сообщение с кнопками отправлено"
        return 0
    else
        local error=$(echo "$response" | jq -r '.description')
        echo "❌ Ошибка: $error"
        return 1
    fi
}

# Функция получения ID чата (полезно для групп)
get_updates() {
    echo "Получение последних обновлений..."
    local response=$(curl -s "${TELEGRAM_API}/getUpdates")
    echo "$response" | jq '.result[] | {message: .message.text, chat_id: .message.chat.id, chat_title: .message.chat.title}'
}

# Функция проверки конфигурации
check_config() {
    if [ "$BOT_TOKEN" = "YOUR_BOT_TOKEN_HERE" ]; then
        echo "❌ Ошибка: Необходимо указать токен бота (BOT_TOKEN)"
        echo "Получите токен у @BotFather в Telegram"
        exit 1
    fi
    
    if [ "$CHAT_ID" = "YOUR_CHAT_ID_HERE" ]; then
        echo "❌ Ошибка: Необходимо указать ID чата (CHAT_ID)"
        echo "Используйте команду: $0 --get-updates"
        exit 1
    fi
}

# Функция отправки уведомления о системном событии
send_system_notification() {
    local hostname=$(hostname)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local event="$1"
    local details="$2"
    
    local message="🖥 <b>Системное уведомление</b>
    
📍 Сервер: <code>${hostname}</code>
🕐 Время: ${timestamp}
📌 Событие: ${event}
📝 Детали: ${details}"
    
    send_message "$message" "HTML"
}

# Функция мониторинга и отправки статуса
send_monitoring_status() {
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    local mem_usage=$(free -m | awk 'NR==2{printf "%.1f", $3*100/$2}')
    local disk_usage=$(df -h / | awk 'NR==2{print $5}')
    local uptime=$(uptime -p)
    
    local message="📊 <b>Мониторинг системы</b>
    
🖥 Сервер: <code>$(hostname)</code>
⚡ CPU: ${cpu_usage}%
💾 RAM: ${mem_usage}%
💿 Диск: ${disk_usage}
⏱ Uptime: ${uptime}"
    
    send_message "$message" "HTML"
}

# ================== ГЛАВНОЕ МЕНЮ ==================

show_help() {
    cat << EOF
Использование: $0 [ОПЦИЯ] [АРГУМЕНТЫ]

ОПЦИИ:
    -m, --message "текст"       Отправить текстовое сообщение
    -f, --file "путь" "подпись" Отправить файл с подписью
    -p, --photo "путь" "подпись" Отправить изображение
    -s, --system "событие" "детали" Отправить системное уведомление
    --monitoring                Отправить статус мониторинга
    --get-updates              Получить последние обновления (для ID чата)
    --stdin                    Читать сообщение из stdin
    -h, --help                 Показать эту справку

ПРИМЕРЫ:
    $0 -m "Привет, мир!"
    $0 -f /path/to/file.pdf "Отчет за месяц"
    $0 -p /path/to/image.jpg "Скриншот ошибки"
    $0 -s "Backup" "Резервное копирование завершено успешно"
    $0 --monitoring
    echo "Сообщение" | $0 --stdin
    
КОНФИГУРАЦИЯ:
    Отредактируйте переменные BOT_TOKEN и CHAT_ID в начале скрипта

EOF
}

# ================== ОБРАБОТКА ПАРАМЕТРОВ ==================

# Проверка зависимостей
check_dependencies

# Создание лог-файла если не существует
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/telegram_sender.log"

# Обработка аргументов командной строки
case "$1" in
    -m|--message)
        check_config
        send_message "$2"
        ;;
    
    -f|--file)
        check_config
        send_file "$2" "$3"
        ;;
    
    -p|--photo)
        check_config
        send_photo "$2" "$3"
        ;;
    
    -s|--system)
        check_config
        send_system_notification "$2" "$3"
        ;;
    
    --monitoring)
        check_config
        send_monitoring_status
        ;;
    
    --get-updates)
        get_updates
        ;;
    
    --stdin)
        check_config
        message=$(cat)
        send_message "$message"
        ;;
    
    -h|--help)
        show_help
        ;;
    
    *)
        if [ -z "$1" ]; then
            show_help
        else
            echo "Неизвестная опция: $1"
            echo "Используйте $0 --help для справки"
            exit 1
        fi
        ;;
esac

exit 0
