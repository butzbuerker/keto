# Keto - PDF File Processor

Ein Docker-basierter Service zur Überwachung und Verarbeitung von PDF-Dateien zwischen NAS und Canon-Drucker.

## Features

- Überwachung eines Quellverzeichnisses auf neue PDF-Dateien
- Automatisches Verschieben von Dateien in ein Zielverzeichnis
- Webhook-Benachrichtigungen für verschiedene Events
- Robuste Fehlerbehandlung bei Netzwerkproblemen
- Detaillierte Logs und Debug-Informationen
- Automatische Datei-Vollständigkeits-Prüfung

## Architektur

Das System verwendet **Host-Mounts** für maximale Stabilität:

- **Source:** NAS-Share wird als Host-Mount bereitgestellt
- **Target:** Canon-Hotfolder wird als Host-Mount bereitgestellt
- **Container:** Überwacht und verarbeitet Dateien zwischen den gemounteten Verzeichnissen

## Konfiguration

### Host-System Setup (Raspberry Pi)

**1. CIFS-Mounts in `/etc/fstab` konfigurieren:**

```bash
sudo nano /etc/fstab
```

Füge folgende Zeilen hinzu:
```
//192.168.2.21/jdf_pdf /mnt/nas_folder       cifs    credentials=/etc/samba/credentials_nas,iocharset=utf8,vers=3.0  0  0
//192.168.2.11/pdf_jdf /mnt/canon_hotfolder  cifs    credentials=/etc/samba/credentials_canon,iocharset=utf8,vers=3.0  0  0
```

**2. Credentials-Dateien erstellen:**

```bash
# NAS Credentials
sudo nano /etc/samba/credentials_nas
```
```
username=your_nas_user
password=your_nas_password
```

```bash
# Canon Credentials
sudo nano /etc/samba/credentials_canon
```
```
username=pdf_jdf
password=VMR-phz_zbn.eat7yfw
```

**3. Berechtigungen setzen:**
```bash
sudo chmod 600 /etc/samba/credentials_*
sudo chown root:root /etc/samba/credentials_*
```

**4. Mounts testen:**
```bash
sudo mount -a
mountpoint /mnt/nas_folder && echo "NAS-Mount OK" || echo "NAS-Mount fehlt"
mountpoint /mnt/canon_hotfolder && echo "Canon-Mount OK" || echo "Canon-Mount fehlt"
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
      - "/mnt/canon_hotfolder:/data/target:rw"
    restart: unless-stopped
    environment:
      - WEBHOOK_URL=${WEBHOOK_URL}
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "sh", "-c", "mountpoint -q /data/source"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### Umgebungsvariablen

Erstelle eine `.env` Datei:
```env
WEBHOOK_URL=https://your-webhook-url.com
```

## Installation und Deployment

```bash
# Repository klonen
git clone https://github.com/butzbuerker/keto.git
cd keto

# Container bauen und starten
docker-compose build --no-cache
docker-compose up -d

# Logs überwachen
docker-compose logs -f keto
```

## Troubleshooting

### Problem: Dateien werden nicht im Zielverzeichnis angezeigt

**Mögliche Ursachen:**

1. **Host-Mount nicht verfügbar**
   - Das Canon-Hotfolder ist nicht gemountet
   - Prüfe: `mountpoint /mnt/canon_hotfolder`

2. **CIFS-Credentials falsch**
   - Canon-Credentials sind abgelaufen oder falsch
   - Prüfe: `/etc/samba/credentials_canon`

3. **Netzwerkprobleme**
   - Canon-Drucker ist nicht erreichbar
   - Prüfe: `ping 192.168.2.11`

**Lösungsansätze:**

1. **Host-Mounts prüfen:**
   ```bash
   mountpoint /mnt/nas_folder && echo "NAS OK" || echo "NAS fehlt"
   mountpoint /mnt/canon_hotfolder && echo "Canon OK" || echo "Canon fehlt"
   ```

2. **Mounts neu laden:**
   ```bash
   sudo mount -a
   ```

3. **Container-Logs prüfen:**
   ```bash
   docker-compose logs -f keto
   ```

4. **Container-Mounts prüfen:**
   ```bash
   docker exec keto mountpoint -q /data/source && echo "Source OK" || echo "Source fehlt"
   docker exec keto mountpoint -q /data/target && echo "Target OK" || echo "Target fehlt"
   ```

### Problem: Container startet nicht

**Mögliche Ursachen:**

1. **Host-Mounts nicht verfügbar**
   - Beide Verzeichnisse müssen beim Container-Start gemountet sein
   - Prüfe: `mountpoint /mnt/nas_folder /mnt/canon_hotfolder`

2. **Docker-Volume-Probleme**
   - Berechtigungsprobleme bei den Docker-Volumes

**Lösungsansätze:**

1. **Host-Mounts erzwingen:**
   ```bash
   sudo mount -a
   ```

2. **Container neu starten:**
   ```bash
   docker-compose down
   docker-compose up -d
   ```

### Problem: Dateien werden nicht verarbeitet

**Mögliche Ursachen:**

1. **Datei-Vollständigkeits-Prüfung schlägt fehl**
   - Dateien werden noch geschrieben
   - Prüfe die Logs für "Dateigröße unverändert"

2. **Berechtigungsprobleme**
   - Container kann nicht auf Verzeichnisse zugreifen

**Lösungsansätze:**

1. **Logs analysieren:**
   ```bash
   docker-compose logs keto | grep -E "(Dateigröße|Vollständigkeit|Fehler)"
   ```

2. **Berechtigungen prüfen:**
   ```bash
   docker exec keto ls -la /data/source /data/target
   ```

## Monitoring

### Webhook-Benachrichtigungen

Der Service sendet Webhook-Benachrichtigungen für folgende Events:

- `file_moved`: Datei erfolgreich verschoben
- `file_moved_after_error`: Datei nach vorherigem Fehler verschoben
- `error`: Verschiedene Fehlertypen
- `target_not_mounted_FILENAME`: Zielverzeichnis nicht verfügbar
- `source_not_mounted`: Quellverzeichnis nicht verfügbar
- `target_not_available_startup`: Target nicht verfügbar beim Start

### Logs

Die Logs enthalten detaillierte Informationen über:

- **Mount-Status:** Beide Verzeichnisse werden beim Start geprüft
- **Dateiverarbeitung:** Vollständige Überwachung des Verarbeitungsprozesses
- **Datei-Vollständigkeit:** 60 Sekunden Wartezeit + Größenprüfung + Lesevorgang-Test
- **Fehlerbehandlung:** Detaillierte Fehlermeldungen und Retry-Logik
- **Debug-Informationen:** Mount-Status, Credentials (versteckt), Verzeichnis-Inhalte

```bash
# Logs anzeigen
docker-compose logs keto

# Logs verfolgen
docker-compose logs -f keto

# Spezifische Events suchen
docker-compose logs keto | grep -E "(erfolgreich|Fehler|WARNUNG)"
```

### Healthcheck

Der Container hat einen Healthcheck, der prüft, ob das Source-Verzeichnis gemountet ist:

```bash
# Healthcheck-Status prüfen
docker-compose ps
```

## Wartung

### Neustart nach Updates

```bash
# Code aktualisieren
git pull

# Container neu bauen und starten
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

### Host-System Neustart

Nach einem Neustart des Raspberry Pi:

1. **Mounts werden automatisch wiederhergestellt** (durch `/etc/fstab`)
2. **Container startet automatisch** (durch `restart: unless-stopped`)
3. **Service ist sofort verfügbar**

### Backup und Wiederherstellung

**Wichtige Dateien:**
- `/etc/fstab` - Mount-Konfiguration
- `/etc/samba/credentials_*` - CIFS-Credentials
- `docker-compose.yaml` - Container-Konfiguration
- `.env` - Umgebungsvariablen

## Technische Details

### Datei-Verarbeitung

1. **Erkennung:** Polling alle 5 Sekunden nach neuen PDF-Dateien
2. **Wartezeit:** 60 Sekunden für vollständige Datei-Übertragung
3. **Vollständigkeits-Prüfung:** 
   - Größenprüfung (5x unverändert)
   - Lesevorgang-Test (3x bestätigt)
   - Zusätzliche 10 Sekunden Sicherheit
4. **Verschiebung:** `mv` Befehl mit Retry-Logik
5. **Benachrichtigung:** Webhook für erfolgreiche Verarbeitung

### Fehlerbehandlung

- **Exponentieller Backoff:** 10s, 20s, 40s, 80s, 160s
- **Retry-Limit:** 5 Versuche, dann 1 Stunde Pause
- **Automatische Wiederherstellung:** Service läuft auch bei Mount-Problemen
- **Detaillierte Logs:** Alle Schritte werden protokolliert

### Sicherheit

- **Credentials:** In separaten Dateien mit 600-Berechtigungen
- **Container:** Läuft ohne privilegierte Rechte
- **Netzwerk:** Nur interne CIFS-Verbindungen
- **Logs:** Keine Passwörter in Logs sichtbar
