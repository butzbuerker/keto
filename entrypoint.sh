#!/bin/bash
# entrypoint.sh - Überwacht den Quellordner auf neue PDF-Dateien, verschiebt sie in den Zielordner
# und sendet eine Benachrichtigung an einen n8n Webhook – auch bei Fehlern.
# Zusätzlich wird überprüft, ob das Source-Verzeichnis gemountet ist und es wird ein Retry-Mechanismus
# implementiert, falls das Target-Verzeichnis (z. B. der Drucker) nicht erreichbar ist.

# Verzeichnis, in dem neue Dateien ankommen (z. B. NAS-Ordner, per Volume gemountet)
SOURCE_DIR="/data/source"

# Verzeichnis, in das die Dateien verschoben werden (z. B. Canon Hotfolder, per Volume gemountet)
TARGET_DIR="/data/target"

# Webhook URL, über Umgebungsvariable konfigurierbar
WEBHOOK_URL="${WEBHOOK_URL:-}"

echo "Starte Überwachung..."

# Funktion, die einen JSON-POST an den Webhook sendet
send_webhook() {
    local ACTION="$1"
    local FILENAME="$2"
    local TIMESTAMP
    TIMESTAMP=$(date -Iseconds)
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
             -d "{\"action\": \"${ACTION}\", \"filename\": \"${FILENAME}\", \"timestamp\": \"${TIMESTAMP}\"}" \
             "$WEBHOOK_URL" || echo "$(date): Fehler beim Senden des Webhook für ${FILENAME}"
    fi
}

# Prüfe, ob das SOURCE_DIR gemountet ist. Falls nicht, versuche es mehrfach.
MAX_RETRIES_SOURCE=10
COUNT_SOURCE=0
until mountpoint -q "${SOURCE_DIR}"; do
    echo "$(date): Quelle ${SOURCE_DIR} ist nicht gemountet. Versuch $((COUNT_SOURCE+1)) von ${MAX_RETRIES_SOURCE}."
    sleep 10
    COUNT_SOURCE=$((COUNT_SOURCE+1))
    if [ "$COUNT_SOURCE" -ge "$MAX_RETRIES_SOURCE" ]; then
        echo "$(date): Max. Versuche erreicht. Quelle ${SOURCE_DIR} nicht verfügbar."
        send_webhook "error" "source_not_mounted"
        exit 1
    fi
done

echo "$(date): Quelle ${SOURCE_DIR} ist gemountet. Starte Überwachung auf neue PDF-Dateien..."

# Funktion zur Überprüfung, ob das TARGET_DIR gemountet ist, mit Retry
check_target_mounted() {
    local retries=5
    local count=0
    until mountpoint -q "${TARGET_DIR}"; do
        echo "$(date): Ziel ${TARGET_DIR} ist nicht gemountet. Versuch $((count+1)) von ${retries}."
        sleep 10
        count=$((count+1))
        if [ "$count" -ge "$retries" ]; then
            return 1
        fi
    done
    return 0
}

# Starte die Überwachung des Quellordners mit inotifywait
inotifywait -m -e create --format '%f' "${SOURCE_DIR}" | while read FILENAME; do
    if [[ "${FILENAME}" == *.pdf ]]; then
        echo "$(date): Neue PDF-Datei erkannt: ${FILENAME}"
        sleep 2  # Warte, damit die Datei vollständig geschrieben wird

        # Prüfe, ob das TARGET_DIR erreichbar ist, bevor du versuchst, die Datei zu verschieben
        if ! check_target_mounted; then
            echo "$(date): Zielverzeichnis ${TARGET_DIR} ist nicht erreichbar. Datei ${FILENAME} wird nicht verschoben."
            send_webhook "error" "target_not_mounted_${FILENAME}"
            continue  # Überspringe diese Datei
        fi

MAX_RETRIES_MOVE=5
COUNT_MOVE=0
BACKOFF=10
errorSent=false
success=false

until $success; do
    if mv "${SOURCE_DIR}/${FILENAME}" "${TARGET_DIR}/"; then
        echo "$(date): Datei ${FILENAME} erfolgreich nach ${TARGET_DIR} verschoben."
        # Sende Erfolgsmeldung, falls vorher ein Fehler aufgetreten war
        if $errorSent; then
            send_webhook "file_moved_after_error" "${FILENAME}"
        else
            send_webhook "file_moved" "${FILENAME}"
        fi
        success=true
    else
        if ! $errorSent; then
            echo "$(date): Fehler beim Verschieben von ${FILENAME}. Sende einmalige Fehlermeldung."
            send_webhook "error" "move_failed_${FILENAME}"
            errorSent=true
        fi
        echo "$(date): Retry ${COUNT_MOVE}/$MAX_RETRIES_MOVE in ${BACKOFF} Sekunden."
        sleep $BACKOFF
        COUNT_MOVE=$((COUNT_MOVE+1))
        BACKOFF=$((BACKOFF * 2))  # exponentieller Backoff
        if [ "$COUNT_MOVE" -ge "$MAX_RETRIES_MOVE" ]; then
            echo "$(date): Datei ${FILENAME} konnte nach ${TARGET_DIR} nicht verschoben werden. Warte 1 Stunde, bevor erneut versucht wird."
            sleep 3600  # Warte 1 Stunde
            COUNT_MOVE=0  # Retry-Zähler zurücksetzen
            BACKOFF=10
            errorSent=false  # Fehlerflag zurücksetzen, um erneut bei einem erneuten Versuch Fehler zu melden
        fi
    fi
done

