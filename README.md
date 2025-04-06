# Keto - Ordnerüberwachungsdienst

Dies ist ein internes Projekt, das einen Docker-basierten Ordnerüberwachungsdienst implementiert. Der Dienst überwacht einen Quellordner auf neue PDF-Dateien und verschiebt sie in einen Zielordner. Dies eignet sich beispielsweise, um Dateien, die über ein NAS oder einen FTP-Server eintreffen, automatisch in einen Druck Hotfolder zu verschieben.

## Architektur

- **Source Directory**: Der Ordner, in dem neue Dateien (z. B. PDF) ankommen.
- **Target Directory**: Der Ordner, in den die Dateien verschoben werden (z. B. der Canon Hotfolder).
- **Container**: Der Docker-Container überwacht mit `inotifywait` den Quellordner. Beim Erkennen neuer PDF-Dateien wird mit `mv` die Datei in den Zielordner verschoben.

## Enthaltene Dateien

- **Dockerfile**: Baut das Image auf Basis von Alpine Linux und installiert die notwendigen Tools (inotify-tools, bash, coreutils).
- **entrypoint.sh**: Das Bash-Skript, das den Quellordner überwacht und Dateien verschiebt.
- **docker-compose.yaml**: Definiert den Service, mountet lokale Ordner als Volumes und startet den Container.
- **README.md**: Dieses Dokument, das eine Übersicht und Anleitung für das Projekt bietet.

## Installation und Einsatz

1. **Repository klonen**:

   ```bash
   git clone https://github.com/butzbuerker/keto.git
   cd keto
