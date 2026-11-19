#!/bin/bash
# Genera un certificado autofirmado para cifrar las conexiones (TLS) y activa SSL.
# En producción se reemplazaría por un certificado emitido por una CA de confianza.
set -euo pipefail

cd "$PGDATA"
if [[ ! -f server.key ]]; then
  openssl req -new -x509 -days 825 -nodes -newkey rsa:2048 \
    -subj "/C=SV/O=Hotel/CN=hotel-db" \
    -keyout server.key -out server.crt >/dev/null 2>&1
  chmod 600 server.key
  echo ">> Certificado SSL generado"
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -c "ALTER SYSTEM SET ssl = on;"
