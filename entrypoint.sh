#!/bin/bash
# entrypoint.sh - Initialisiert den Prozess, indem alle vorhandenen PDF-Dateien im Quellordner verarbeitet werden,
# und startet anschließend einen kontinuierlichen Polling-Modus, der alle 5 Sekunden nach neuen PDF-Dateien sucht.
# Die Dateien werden in den Zielordner verschoben und über einen n8n Webhook werden Meldungen versendet.

# Verzeichnis, in dem neue Dateien ankommen (z. B. NAS-Ordner, per Volume gemountet)
SOURCE_DIR="/data/source"

# Verzeichnis, in das die Dateien verschoben werden (z. B. Canon Hotfolder, per Volume gemountet)
TARGET_DIR="/data/target"

# Webhook URL, über Umgebungsvariable konfigurierbar
WEBHOOK_URL="${WEBHOOK_URL:-}"

echo "$(date): Starte Überwachung und Initialisierung..."

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

# Funktion zur Überprüfung, ob eine Datei vollständig geschrieben wurde
check_file_complete() {
    local FILENAME="$1"
    local max_attempts=30
    local attempt=0
    local last_size=0
    local current_size
    local unchanged_count=0
    local check_interval=1

    echo "$(date): Starte Überprüfung der Datei ${FILENAME} auf Vollständigkeit"
    echo "$(date): Warte 30 Sekunden, um sicherzustellen, dass die Datei vollständig geschrieben wurde..."
    sleep 30

    while [ $attempt -lt $max_attempts ]; do
        echo "$(date): Versuch $((attempt + 1))/$max_attempts - Prüfe Datei ${FILENAME}"
        
        # Versuche die Datei zu öffnen und zu lesen
        if ! dd if="${SOURCE_DIR}/${FILENAME}" of=/dev/null bs=1M count=1 2>/dev/null; then
            echo "$(date): Datei ${FILENAME} konnte nicht gelesen werden (Versuch $((attempt + 1)))"
            sleep $check_interval
            attempt=$((attempt + 1))
            continue
        fi

        # Prüfe die Dateigröße
        current_size=$(stat -f %z "${SOURCE_DIR}/${FILENAME}" 2>/dev/null || stat -c %s "${SOURCE_DIR}/${FILENAME}")
        echo "$(date): Aktuelle Dateigröße: ${current_size} Bytes"
        
        if [ "$current_size" = "$last_size" ]; then
            unchanged_count=$((unchanged_count + 1))
            echo "$(date): Dateigröße unverändert (${unchanged_count}/3)"
            if [ $unchanged_count -ge 3 ]; then
                echo "$(date): Versuche vollständigen Lesevorgang für ${FILENAME}"
                if dd if="${SOURCE_DIR}/${FILENAME}" of=/dev/null bs=1M 2>/dev/null; then
                    echo "$(date): Datei ${FILENAME} erfolgreich vollständig gelesen"
                    return 0
                else
                    echo "$(date): Fehler beim vollständigen Lesen von ${FILENAME}"
                fi
            fi
        else
            echo "$(date): Dateigröße hat sich geändert: ${last_size} -> ${current_size} Bytes"
            unchanged_count=0
        fi
        
        last_size=$current_size
        sleep $check_interval
        attempt=$((attempt + 1))
    done

    echo "$(date): Maximale Anzahl an Versuchen erreicht für ${FILENAME}"
    return 1
}

# Funktion zur Verarbeitung einer Datei
process_file() {
    local FILENAME="$1"
    echo "$(date): Verarbeite Datei ${FILENAME}"

    # Warte bis die Datei vollständig geschrieben ist
    if ! check_file_complete "$FILENAME"; then
        echo "$(date): Datei ${FILENAME} scheint noch geschrieben zu werden. Überspringe Verarbeitung."
        send_webhook "error" "file_incomplete_${FILENAME}"
        return 1
    fi

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
                errorSent=false # Fehlerflag zurücksetzen, um bei erneutem Fehler wieder einen Webhook zu senden
            fi
        fi
    done
    return 0
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

echo "$(date): Quelle ${SOURCE_DIR} ist gemountet. Starte Initialisierung..."

# Initialisierungsphase: Verarbeite alle bereits vorhandenen PDF-Dateien im SOURCE_DIR
for file in "${SOURCE_DIR}"/*.pdf; do
    if [ -e "$file" ]; then
        FILENAME=$(basename "$file")
        process_file "$FILENAME"
    fi
done

echo "$(date): Initialisierung abgeschlossen – starte Polling auf neue PDF-Dateien..."

# Kontinuierliche Überwachung des Quellordners per Polling
while true; do
    for file in "${SOURCE_DIR}"/*.pdf; do
        # Falls keine PDF-Datei existiert, wird die Schleife übersprungen
        [ -e "$file" ] || continue
        FILENAME=$(basename "$file")
        process_file "$FILENAME"
    done
    sleep 5
done
