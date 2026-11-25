#!/usr/bin/env bash
# Reconstructed ADB-based UI monitor. Not a standalone Android application.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [[ -f "$HERE/telegram.env" ]]; then source "$HERE/telegram.env"; fi

INTERVAL="${INTERVAL:-300}"
TAP_X="${TAP_X:-540}"
TAP_Y="${TAP_Y:-1232}"
WAKE_DEVICE="${WAKE_DEVICE:-0}"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
LOG_FILE="${LOG_FILE:-$HERE/slot-monitor.log}"
ALERT_DIR="${ALERT_DIR:-$HERE/slot-alerts}"
XML_FILE="$(mktemp -t cmon-XXXXXX.xml)"
trap 'rm -f "$XML_FILE"' EXIT
mkdir -p "$ALERT_DIR"

case "$INTERVAL" in *[!0-9]*|'') echo "INTERVAL must be a positive integer" >&2; exit 2;; esac
if (( INTERVAL < 60 )); then echo "INTERVAL must be at least 60 seconds" >&2; exit 2; fi
if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "Set BOT_TOKEN and CHAT_ID in telegram.env" >&2; exit 2
fi
command -v adb >/dev/null || { echo "adb is missing" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is missing" >&2; exit 2; }
ADB=(adb)
if [[ -n "${ADB_SERIAL:-}" ]]; then ADB+=(-s "$ADB_SERIAL"); fi

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

notify() {
  local message="$1"
  if ! curl -fsS --retry 2 --connect-timeout 10 --max-time 25 \
       -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$message" \
       > /dev/null; then
    log "WARNING Telegram text delivery failed"
    return 1
  fi
}

send_picture() {
  local path="$1"
  if ! curl -fsS --retry 2 --connect-timeout 10 --max-time 35 \
       -F "chat_id=$CHAT_ID" -F "photo=@$path" \
       "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" >/dev/null; then
    log "WARNING Telegram screenshot delivery failed"
    return 1
  fi
}

dump_ui() {
  # First make sure the device responds. Use the device's shell to dump the UI.
  "${ADB[@]}" get-state >/dev/null 2>&1 || return 1
  "${ADB[@]}" shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || return 1
  "${ADB[@]}" exec-out cat /sdcard/window.xml > "$XML_FILE" || return 1
  [[ -s "$XML_FILE" ]]
}

modal_open() {
  # "Выберите дату" is also present as a field on step 2;
  # use actual picker UI signals if present, and avoid false certainty.
  grep -q 'Нет доступных дат' "$XML_FILE"
}

step_two() {
  grep -q 'Шаг 2 из 3' "$XML_FILE" && grep -q 'Выберите дату' "$XML_FILE"
}

log "Monitoring started. INTERVAL=$INTERVAL. ADB device=${ADB_SERIAL:-default}"
notify "ЦОН Monitor: мониторинг запущен (интервал ${INTERVAL} с)." || true

while :; do
  if [[ "$WAKE_DEVICE" == "1" ]]; then
    "${ADB[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    sleep 2
  fi

  if ! dump_ui; then
    log "ERROR: cannot read UI. Stopping (device may be locked/disconnected)."
    notify "ЦОН Monitor: остановлен — не удалось прочитать экран телефона." || true
    exit 1
  fi

  if modal_open; then
    log "Picker already shows NO_SLOTS; closing"
    "${ADB[@]}" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
    sleep 2
    if ! dump_ui; then log "ERROR: UI unreadable after Back"; exit 1; fi
  fi

  if ! step_two; then
    log "ERROR: not on expected step 2; not tapping blindly"
    notify "ЦОН Monitor: остановлен — экран ЦОН не соответствует шагу 2. Проверь авторизацию и положение приложения." || true
    exit 1
  fi

  log "CHECKING: tapping date picker"
  if ! "${ADB[@]}" shell input tap "$TAP_X" "$TAP_Y"; then
    log "ERROR: cannot tap date picker"; exit 1
  fi
  sleep 3
  if ! dump_ui; then
    log "ERROR: UI unreadable after tap"
    notify "ЦОН Monitor: остановлен — не удалось прочитать окно даты." || true
    exit 1
  fi

  if grep -q 'Нет доступных дат' "$XML_FILE"; then
    log "NO_SLOTS"
    "${ADB[@]}" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || {
      log "ERROR: cannot close picker"; exit 1;
    }
  else
    log "ALERT: picker no longer contains NO_SLOTS; requires manual check"
    notify "ЦОН Monitor: возможно, появились даты! Сообщение «Нет доступных дат» отсутствует. Проверь окно приложения вручную. Монитор остановлен." || true
    shot="$ALERT_DIR/slot-$(date '+%Y%m%d-%H%M%S').png"
    if "${ADB[@]}" exec-out screencap -p > "$shot" && [[ -s "$shot" ]]; then
      send_picture "$shot" || true
    else
      rm -f "$shot"
      log "WARNING: could not capture screenshot"
    fi
    exit 0
  fi
  sleep "$INTERVAL"
done
