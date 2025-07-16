# Keto - PDF File Processor

Ein Docker-basierter Service zur Überwachung und Verarbeitung von PDF-Dateien zwischen NAS und Canon-Drucker.

## Features

- Überwachung eines Quellverzeichnisses auf neue PDF-Dateien
- Automatisches Verschieben von Dateien in ein Zielverzeichnis
- Webhook-Benachrichtigungen für verschiedene Events
- Robuste Fehlerbehandlung bei Netzwerkproblemen
- Automatische Wiederherstellung von CIFS-Mounts

## Konfiguration

### Umgebungsvariablen

Erstelle eine `.env` Datei mit folgenden Variablen:

```env
WEBHOOK_URL=https://your-webhook-url.com
CIFS_USERNAME=your_username
CIFS_PASSWORD=your_password
```

### Docker Compose

```yaml
version: "3.3"
services:
  keto:
    build: .
    container_name: keto
    volumes:
      - "/mnt/nas_folder:/data/source:rw"
      - "//CanonC810/pdf_jdf:/data/target:rw"
    restart: unless-stopped
    environment:
      - WEBHOOK_URL=${WEBHOOK_URL}
      - CIFS_USERNAME=${CIFS_USERNAME:-}
      - CIFS_PASSWORD=${CIFS_PASSWORD:-}
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "mountpoint", "-q", "/data/source"] && ["CMD", "mountpoint", "-q", "/data/target"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

## Troubleshooting

### Problem: Dateien werden nicht im Zielverzeichnis angezeigt

**Mögliche Ursachen:**

1. **CIFS-Mount verloren gegangen**
   - Der Container versucht automatisch, den CIFS-Share neu zu mounten
   - Prüfe die Logs: `docker logs keto`

2. **Netzwerkprobleme**
   - Der Canon-Drucker ist nicht erreichbar
   - Prüfe die Netzwerkverbindung zum Drucker

3. **Berechtigungsprobleme**
   - CIFS-Credentials sind falsch oder abgelaufen
   - Prüfe die Umgebungsvariablen

**Lösungsansätze:**

1. **Container neu starten:**
   ```bash
   docker-compose restart keto
   ```

2. **Logs prüfen:**
   ```bash
   docker logs keto -f
   ```

3. **Mount-Status prüfen:**
   ```bash
   docker exec keto mountpoint -q /data/target
   ```

4. **Manuelles Mounten testen:**
   ```bash
   docker exec keto mount -t cifs //CanonC810/pdf_jdf /data/target -o username=your_user,password=your_pass
   ```

### Problem: Container startet nicht

**Mögliche Ursachen:**

1. **Quellverzeichnis nicht verfügbar**
   - Das NAS-Verzeichnis `/mnt/nas_folder` ist nicht gemountet
   - Prüfe den Host-Mount-Status

2. **Docker-Volume-Probleme**
   - Berechtigungsprobleme bei den Docker-Volumes

**Lösungsansätze:**

1. **Host-Mounts prüfen:**
   ```bash
   mountpoint /mnt/nas_folder
   ```

2. **Docker-Volumes neu erstellen:**
   ```bash
   docker-compose down
   docker-compose up -d
   ```

## Monitoring

Der Service sendet Webhook-Benachrichtigungen für folgende Events:

- `file_moved`: Datei erfolgreich verschoben
- `file_moved_after_error`: Datei nach vorherigem Fehler verschoben
- `error`: Verschiedene Fehlertypen
- `mount_failure_source_X_target_Y`: Mount-Probleme
- `target_not_mounted_FILENAME`: Zielverzeichnis nicht verfügbar
- `source_not_mounted`: Quellverzeichnis nicht verfügbar

## Logs

Die Logs enthalten detaillierte Informationen über:
- Mount-Status der Verzeichnisse
- Dateiverarbeitung
- Fehler und Wiederherstellungsversuche
- Webhook-Benachrichtigungen

```bash
# Logs anzeigen
docker logs keto

# Logs verfolgen
docker logs keto -f
```
