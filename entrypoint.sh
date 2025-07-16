#!/bin/bash
# entrypoint.sh - Initialisiert den Prozess, indem alle vorhandenen PDF-Dateien im Quellordner verarbeitet werden,
# und startet anschließend einen kontinuierlichen Polling-Modus, der alle 5 Sekunden nach neuen PDF-Dateien sucht.
# Die Dateien werden in den Zielordner verschoben und über einen n8n Webhook werden Meldungen versendet.

# Verzeichnis, in dem neue Dateien ankommen (z. B. NAS-Ordner, per Volume gemountet)
SOURCE_DIR="/data/source"

# Verzeichnis, in das die Dateien verschoben werden (z. B. Canon Hotfolder, per Volume gemountet)
TARGET_DIR="/data/target"

# Webhook URL, über Umgebungsvariable konfigurierbar
WEBHOOK_URL="${WEBHOOK_URL:-}"

# CIFS Credentials - Standard-Credentials für Canon Hotfolder
CIFS_USERNAME="${CIFS_USERNAME:-pdf_jdf}"
CIFS_PASSWORD="${CIFS_PASSWORD:-VMR-phz_zbn.eat7yfw}"

echo "$(date): Starte Überwachung und Initialisierung..."

# Debug-Funktion für Mount-Status
debug_mount_status() {
    echo "$(date): === MOUNT DEBUG INFO ==="
    echo "$(date): Source-Verzeichnis: ${SOURCE_DIR}"
    mountpoint -q "${SOURCE_DIR}" && echo "$(date): ✓ Source ist gemountet" || echo "$(date): ✗ Source ist NICHT gemountet"
    ls -la "${SOURCE_DIR}" 2>/dev/null | head -5 || echo "$(date): Kann Source nicht auflisten"
    
    echo "$(date): Target-Verzeichnis: ${TARGET_DIR}"
    mountpoint -q "${TARGET_DIR}" && echo "$(date): ✓ Target ist gemountet" || echo "$(date): ✗ Target ist NICHT gemountet"
    ls -la "${TARGET_DIR}" 2>/dev/null | head -5 || echo "$(date): Kann Target nicht auflisten"
    
    echo "$(date): CIFS Credentials:"
    echo "$(date): Username: ${CIFS_USERNAME}"
    echo "$(date): Password: [HIDDEN]"
    echo "$(date): === END DEBUG INFO ==="
}

# Funktion zum Mounten des CIFS-Shares
mount_cifs_target() {
    local max_attempts=5
    local attempt=0
    
    echo "$(date): Versuche CIFS-Share zu mounten..."
    
    # Installiere cifs-utils falls nicht vorhanden
    if ! command -v mount.cifs &> /dev/null; then
        echo "$(date): Installiere cifs-utils..."
        apk add --no-cache cifs-utils
    fi
    
    # Erstelle Target-Verzeichnis falls es nicht existiert
    mkdir -p "${TARGET_DIR}"
    
    while [ $attempt -lt $max_attempts ]; do
        echo "$(date): Mount-Versuch $((attempt + 1))/$max_attempts"
        
        # Prüfe ob bereits gemountet
        if mountpoint -q "${TARGET_DIR}"; then
            echo "$(date): ${TARGET_DIR} ist bereits gemountet"
            return 0
        fi
        
        # Versuche zu mounten mit korrekter UNC-Pfad-Syntax
        local mount_cmd="mount -t cifs //CanonC810/pdf_jdf ${TARGET_DIR}"
        if [ -n "$CIFS_USERNAME" ] && [ -n "$CIFS_PASSWORD" ]; then
            mount_cmd="$mount_cmd -o username=$CIFS_USERNAME,password=$CIFS_PASSWORD,vers=2.0,uid=0,gid=0,file_mode=0644,dir_mode=0755"
        else
            mount_cmd="$mount_cmd -o vers=2.0,uid=0,gid=0,file_mode=0644,dir_mode=0755"
        fi
        
        echo "$(date): Führe aus: $mount_cmd"
        if $mount_cmd; then
            echo "$(date): CIFS-Share erfolgreich gemountet"
            # Teste Schreibzugriff
            if touch "${TARGET_DIR}/test_write.tmp" 2>/dev/null; then
                rm -f "${TARGET_DIR}/test_write.tmp"
                echo "$(date): Schreibzugriff auf Target-Verzeichnis bestätigt"
                return 0
            else
                echo "$(date): WARNUNG: Kein Schreibzugriff auf Target-Verzeichnis"
                umount "${TARGET_DIR}" 2>/dev/null
                return 1
            fi
        else
            echo "$(date): Fehler beim Mounten des CIFS-Shares"
            sleep 30
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo "$(date): Konnte CIFS-Share nicht mounten nach $max_attempts Versuchen"
    return 1
}

# Funktion zur Überprüfung und Wiederherstellung der Mounts
check_and_restore_mounts() {
    local source_mounted=true
    local target_mounted=true
    
    # Prüfe Source-Mount
    if ! mountpoint -q "${SOURCE_DIR}"; then
        echo "$(date): WARNUNG: Source-Verzeichnis ${SOURCE_DIR} ist nicht gemountet!"
        source_mounted=false
    fi
    
    # Prüfe Target-Mount
    if ! mountpoint -q "${TARGET_DIR}"; then
        echo "$(date): WARNUNG: Target-Verzeichnis ${TARGET_DIR} ist nicht gemountet!"
        target_mounted=false
        
        # Versuche CIFS-Share neu zu mounten
        if mount_cifs_target; then
            target_mounted=true
            echo "$(date): Target-Mount erfolgreich wiederhergestellt"
        fi
    fi
    
    if ! $source_mounted || ! $target_mounted; then
        send_webhook "error" "mount_failure_source_${source_mounted}_target_${target_mounted}"
        return 1
    fi
    
    return 0
}

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
    local max_attempts=90  # Erhöht für mehr Sicherheit
    local attempt=0
    local last_size=0
    local current_size
    local unchanged_count=0
    local check_interval=3  # Längere Intervalle für bessere Stabilität
    local min_wait_time=60  # Mindestwartezeit reduziert
    local min_file_size=1024  # Mindestgröße 1KB

    echo "$(date): Starte Überprüfung der Datei ${FILENAME} auf Vollständigkeit"
    echo "$(date): Warte ${min_wait_time} Sekunden, um sicherzustellen, dass die Datei vollständig geschrieben wurde..."
    sleep $min_wait_time

    while [ $attempt -lt $max_attempts ]; do
        echo "$(date): Versuch $((attempt + 1))/$max_attempts - Prüfe Datei ${FILENAME}"
        
        # Prüfe ob Datei existiert und lesbar ist
        if [ ! -r "${SOURCE_DIR}/${FILENAME}" ]; then
            echo "$(date): Datei ${FILENAME} ist nicht lesbar (Versuch $((attempt + 1)))"
            sleep $check_interval
            attempt=$((attempt + 1))
            continue
        fi

        # Prüfe die Dateigröße
        current_size=$(stat -f %z "${SOURCE_DIR}/${FILENAME}" 2>/dev/null || stat -c %s "${SOURCE_DIR}/${FILENAME}")
        echo "$(date): Aktuelle Dateigröße: ${current_size} Bytes"
        
        # Prüfe ob Datei mindestens die Mindestgröße hat
        if [ "$current_size" -lt $min_file_size ]; then
            echo "$(date): Datei ${FILENAME} ist zu klein (${current_size} Bytes < ${min_file_size} Bytes) - warte weiter"
            sleep $check_interval
            attempt=$((attempt + 1))
            continue
        fi
        
        if [ "$current_size" = "$last_size" ]; then
            unchanged_count=$((unchanged_count + 1))
            echo "$(date): Dateigröße unverändert (${unchanged_count}/5)"  # Reduziert für schnellere Verarbeitung
            if [ $unchanged_count -ge 5 ]; then
                echo "$(date): Versuche vollständigen Lesevorgang für ${FILENAME}"
                
                # Mehrfacher Lesevorgang zur Sicherheit
                local read_success=true
                for i in 1 2 3; do
                    echo "$(date): Lesevorgang ${i}/3 für ${FILENAME}"
                    if ! dd if="${SOURCE_DIR}/${FILENAME}" of=/dev/null bs=1M 2>/dev/null; then
                        echo "$(date): Fehler beim Lesevorgang ${i}/3 von ${FILENAME}"
                        read_success=false
                        break
                    fi
                    sleep 1
                done
                
                if $read_success; then
                    echo "$(date): Datei ${FILENAME} erfolgreich vollständig gelesen (3x bestätigt)"
                    
                    # Zusätzliche Wartezeit nach erfolgreichem Lesen
                    echo "$(date): Warte weitere 10 Sekunden zur Sicherheit..."
                    sleep 10
                    
                    return 0
                else
                    echo "$(date): Fehler beim vollständigen Lesen von ${FILENAME}"
                    unchanged_count=0  # Reset für weitere Versuche
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
    local retries_target=10
    local count_target=0
    until [ -d "${TARGET_DIR}" ] && [ -w "${TARGET_DIR}" ]; do
        echo "$(date): Ziel ${TARGET_DIR} ist nicht verfügbar oder nicht beschreibbar. Versuch $((count_target+1)) von ${retries_target}."
        echo "$(date): Prüfe Mount-Status..."
        mountpoint -q "${TARGET_DIR}" && echo "$(date): Verzeichnis ist gemountet" || echo "$(date): Verzeichnis ist NICHT gemountet"
        ls -la "${TARGET_DIR}" 2>/dev/null || echo "$(date): Kann Verzeichnis nicht auflisten"
        sleep 15
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

echo "$(date): Quelle ${SOURCE_DIR} ist gemountet."

# Prüfe, ob das TARGET_DIR gemountet ist. Falls nicht, versuche es zu mounten.
echo "$(date): Prüfe Target-Verzeichnis ${TARGET_DIR}..."
if mountpoint -q "${TARGET_DIR}"; then
    echo "$(date): Target ${TARGET_DIR} ist bereits gemountet."
else
    echo "$(date): Target ${TARGET_DIR} ist nicht gemountet. Versuche CIFS-Share zu mounten..."
    if mount_cifs_target; then
        echo "$(date): Target ${TARGET_DIR} erfolgreich gemountet."
    else
        echo "$(date): WARNUNG: Target ${TARGET_DIR} konnte nicht gemountet werden. Service startet trotzdem."
        send_webhook "error" "target_mount_failed_startup"
    fi
fi

echo "$(date): Starte Initialisierung..."

# Debug-Informationen ausgeben
debug_mount_status

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
    # Prüfe und stelle Mounts wieder her falls nötig
    if ! check_and_restore_mounts; then
        echo "$(date): Mount-Probleme erkannt. Warte 60 Sekunden vor erneutem Versuch..."
        sleep 60
        continue
    fi
    
    for file in "${SOURCE_DIR}"/*.pdf; do
        # Falls keine PDF-Datei existiert, wird die Schleife übersprungen
        [ -e "$file" ] || continue
        FILENAME=$(basename "$file")
        process_file "$FILENAME"
    done
    sleep 5
done
