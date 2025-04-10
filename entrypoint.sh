#!/bin/bash
# entrypoint.sh - Initialisiert den Prozess, indem alle vorhandenen PDF-Dateien im Quellordner verarbeitet werden,
# und startet anschließend die Überwachung für neu erstellte PDF-Dateien.
# Dabei werden die Dateien in den Zielordner verschoben und über einen n8n Webhook werden Meldungen versendet.
# Das Skript implementiert sowohl eine Initialisierungsphase als auch einen kontinuierlichen Überwachungsmodus.

# Verzeichnis, in dem neue Dateien ankommen (z. B. NAS-Ordner, per Volume gemountet)
SOURCE_DIR="/data/source"

# Verzeichnis, in das die Dateien verschoben werden (z. B. Canon Hotfolder, per Volume gemountet)
TARGET_DIR="/data/target"

# Webhook URL, über Umgebungsvariable konfigurierbar
WEBHOOK_URL="${WEBHOOK_URL:-}"

echo "Starte Überwachung und Initialisierung..."

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

# Funktion, die eine Datei verarbeitet (Verschieben mit Retry-Loop)
process_file() {
    local FILENAME="$1"
    echo "$(date): Verarbeite Datei ${FILENAME}"
    sleep 2  # kurze Verzögerung, falls die Datei noch nicht vollständig geschrieben wurde

    # Prüfe, ob das TARGET_DIR erreichbar ist.
    local retries_target=5
    local count_target=0
    until mountpoint -q "${TARGET_DIR}"; do
        echo "$(date): Ziel ${TARGET_DIR} ist nicht gemountet. Versuch $((count_target+1)) von ${retries_target}."
        sleep 10
        count_target=$((count_target+1))
        if [ "$count_target" -ge "$retries_target" ]; then
            echo "$(date): Ziel ${TARGET_DIR} bleibt unerreichbar – Datei ${FILENAME} wird übersprungen."
            send_webhook "error" "target_not_mounted_${FILENAME}"
            return 1
        fi
    done

    # Versuch, die Datei zu verschieben, mit exponentiellem Backoff und einmaliger Fehlerbenachrichtigung
    local MAX_RETRIES_MOVE=5
    local COUNT_MOVE=0
    local BACKOFF=10
    local errorSent=false
    local success=false

    until $success; do
        if mv "${SOURCE_DIR}/${FILENAME}" "${TARGET_DIR}/"; then
            echo "$(date): Datei ${FILENAME} erfolgreich nach ${TARGET_DIR} verschoben."
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
            BACKOFF=$((BACKOFF * 2))
            if [ "$COUNT_MOVE" -ge "$MAX_RETRIES_MOVE" ]; then
                echo "$(date): Datei ${FILENAME} konnte nach ${TARGET_DIR} nicht verschoben werden. Warte 1 Stunde und starte Retry-Runde neu."
                sleep 3600  # 1 Stunde Pause
                COUNT_MOVE=0    # Retry-Zähler zurücksetzen
                BACKOFF=10      # Backoff zurücksetzen
                errorSent=false # Fehlerflag zurücksetzen, um erneut Fehler zu melden falls nötig
            fi
        fi
    done
    return 0
}

# Zuerst: Überprüfe, ob SOURCE_DIR gemountet ist (Retry-Loop)
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

echo "$(date): Quelle ${SOURCE_DIR} ist gemountet. Starte Initialisierung..."

# Initialisierungsphase: Verarbeite alle bereits vorhandenen PDF-Dateien im SOURCE_DIR
for file in "${SOURCE_DIR}"/*.pdf; do
    # Überprüfe, ob tatsächlich eine PDF gefunden wurde. Falls kein Match, wird "${SOURCE_DIR}/*.pdf" selbst zurückgegeben.
    if [ -e "$file" ]; then
        FILENAME=$(basename "$file")
        process_file "$FILENAME"
    fi
done

echo "$(date): Initialisierung abgeschlossen – starte Überwachung auf neue PDF-Dateien..."

# Starte die kontinuierliche Überwachung des Quellordners mit inotifywait
inotifywait -m -e create --format '%f' "${SOURCE_DIR}" | while read FILENAME; do
    if [[ "${FILENAME}" == *.pdf ]]; then
        process_file "${FILENAME}"
    fi
done
