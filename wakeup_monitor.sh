#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/computers.conf"
STATE_DIR="${SCRIPT_DIR}/state"
TELEGRAM="${SCRIPT_DIR}/telegram_sender.sh"
LOG_FILE="/var/log/wakeup_monitor.log"
MAX_ATTEMPTS=5
WAIT_BETWEEN=60  # seconds between WoL retries

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

ping_host() {
    ping -c 3 -W 2 "$1" &>/dev/null
}

is_notified() {
    [[ -f "${STATE_DIR}/${1}.notified" ]]
}

mark_notified() {
    touch "${STATE_DIR}/${1}.notified"
}

clear_notified() {
    rm -f "${STATE_DIR}/${1}.notified"
}

notify() {
    log "Sending Telegram: $1"
    "$TELEGRAM" -m "$1"
}

attempt_wakeup() {
    local name="$1" ip="$2" mac="$3"
    local attempt=0

    while (( attempt < MAX_ATTEMPTS )); do
        (( attempt++ ))
        log "[$name] WoL attempt $attempt/$MAX_ATTEMPTS → $mac"
        wakeonlan "$mac"
        log "[$name] Waiting ${WAIT_BETWEEN}s for $ip..."
        sleep "$WAIT_BETWEEN"
        if ping_host "$ip"; then
            log "[$name] Came online after attempt $attempt"
            return 0
        fi
        log "[$name] Still offline after attempt $attempt"
    done
    return 1
}

process_host() {
    local name="$1" ip="$2" mac="$3"
    log "[$name] Checking $ip..."

    if ping_host "$ip"; then
        log "[$name] Online"
        if is_notified "$name"; then
            notify "✅ <b>Хост вернулся в сеть</b>

📍 Имя: <code>${name}</code>
🌐 IP: <code>${ip}</code>
🕐 Время: $(date '+%Y-%m-%d %H:%M:%S')"
            log "[$name] Sent recovery notification"
            clear_notified "$name"
        fi
        return 0
    fi

    log "[$name] Offline"

    if is_notified "$name"; then
        log "[$name] Already notified, skipping WoL"
        return 0
    fi

    if attempt_wakeup "$name" "$ip" "$mac"; then
        notify "✅ <b>Хост пробужден через WoL</b>

📍 Имя: <code>${name}</code>
🌐 IP: <code>${ip}</code>
🔌 MAC: <code>${mac}</code>
🕐 Время: $(date '+%Y-%m-%d %H:%M:%S')"
        log "[$name] Sent wake-up success notification"
        return 0
    fi

    notify "❌ <b>Хост недоступен</b>

📍 Имя: <code>${name}</code>
🌐 IP: <code>${ip}</code>
🔌 MAC: <code>${mac}</code>
🔁 Попыток WoL: ${MAX_ATTEMPTS}
🕐 Время: $(date '+%Y-%m-%d %H:%M:%S')"
    log "[$name] Sent DOWN notification"
    mark_notified "$name"
}

# ================== MAIN ==================

mkdir -p "$STATE_DIR"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="${SCRIPT_DIR}/wakeup_monitor.log"

if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Config file not found: $CONF_FILE" >&2
    exit 1
fi

log "=== wakeup_monitor start ==="

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"  # strip leading whitespace
    [[ -z "$line" || "$line" == \#* ]] && continue

    read -r h_name h_ip h_mac <<< "$line"

    if [[ -z "$h_name" || -z "$h_ip" || -z "$h_mac" ]]; then
        log "WARNING: Skipping malformed line: $line"
        continue
    fi

    process_host "$h_name" "$h_ip" "$h_mac"
done < "$CONF_FILE"

log "=== wakeup_monitor complete ==="

# Keep log under 2000 lines
if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > 2000 )); then
    tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

exit 0
