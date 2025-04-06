#!/bin/bash
# entrypoint.sh - Überwacht den Quellordner auf neue PDF-Dateien, verschiebt sie in den Zielordner
# und sendet eine Benachrichtigung an einen n8n Webhook – auch bei Fehlern.

# Verzeichnis, in dem neue Dateien ankommen (z. B. NAS-Ordner, per Volume gemountet)
SOURCE_DIR="/data/source"

# Verzeichnis, in das die Dateien verschoben werden (z. B. Canon Hotfolder, per Volume gemountet)
TARGET_DIR="/data/target"

# Webhook URL, über Umgebungsvariable konfigurierbar
WEBHOOK_URL="${WEBHOOK_URL:-}"

echo "Überwache Verzeichnis: ${SOURCE_DIR} auf neue PDF-Dateien..."

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

# Starte die Überwachung des Quellordners mit inotifywait
inotifywait -m -e create --format '%f' "${SOURCE_DIR}" | while read FILENAME; do
    if [[ "${FILENAME}" == *.pdf ]]; then
        echo "$(date): Neue PDF-Datei erkannt: ${FILENAME}"
        sleep 2  # Warte, damit die Datei vollständig geschrieben wird
        
        # Versuche, die Datei zu verschieben
        if mv "${SOURCE_DIR}/${FILENAME}" "${TARGET_DIR}/"; then
            echo "$(date): Datei ${FILENAME} erfolgreich nach ${TARGET_DIR} verschoben."
            send_webhook "file_moved" "${FILENAME}"
        else
            echo "$(date): Fehler beim Verschieben von ${FILENAME}."
            send_webhook "error" "${FILENAME}"
        fi
    fi
done
