#!/bin/bash
# entrypoint.sh - Überwacht den Quellordner auf neue PDF-Dateien und verschiebt sie in den Zielordner.

# Verzeichnis, in dem neue Dateien ankommen (z. B. NAS-Ordner, per Volume gemountet)
SOURCE_DIR="/data/source"

# Verzeichnis, in das die Dateien verschoben werden (z. B. Canon Hotfolder, per Volume gemountet)
TARGET_DIR="/data/target"

echo "Überwache Verzeichnis: ${SOURCE_DIR} auf neue PDF-Dateien..."

# Starte die Überwachung des Quellordners mit inotifywait
# -m: kontinuierlicher Überwachungsmodus
# -e create: beobachte Dateierstellungsereignisse
# --format '%f': Ausgabe nur des Dateinamens
inotifywait -m -e create --format '%f' "${SOURCE_DIR}" | while read FILENAME; do
    # Verarbeite nur Dateien, die auf .pdf enden
    if [[ "${FILENAME}" == *.pdf ]]; then
        echo "$(date): Neue PDF-Datei erkannt: ${FILENAME}"
        
        # Kurze Wartezeit, damit die Datei vollständig geschrieben wird
        sleep 2
        
        # Verschiebe die Datei in den Zielordner
        mv "${SOURCE_DIR}/${FILENAME}" "${TARGET_DIR}/"
        if [ $? -eq 0 ]; then
            echo "$(date): Datei ${FILENAME} erfolgreich nach ${TARGET_DIR} verschoben."
        else
            echo "$(date): Fehler beim Verschieben von ${FILENAME}."
            # Hier kann ein Retry-Mechanismus ergänzt werden, falls nötig
        fi
    fi
done
