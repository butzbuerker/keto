# Verwende ein leichtgewichtiges Alpine Linux als Basis-Image
FROM alpine:latest

# Installiere notwendige Tools: inotify-tools, bash, coreutils, curl und cifs-utils
RUN apk add --no-cache inotify-tools bash coreutils curl cifs-utils

# Kopiere das Überwachungsskript in das Image
COPY entrypoint.sh /entrypoint.sh

# Setze die notwendigen Berechtigungen, damit das Skript ausführbar ist
RUN chmod +x /entrypoint.sh

# Definiere das Skript als Entry-Point, damit es beim Start des Containers ausgeführt wird
ENTRYPOINT ["/entrypoint.sh"]
