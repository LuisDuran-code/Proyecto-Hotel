#!/bin/bash
# Destruye contenedores y volúmenes y vuelve a crear el entorno desde cero.
# ¡CUIDADO! Borra todos los datos, respaldos y WAL archivados.
set -euo pipefail
cd "$(dirname "$0")/.."
read -r -p "Esto BORRA todos los datos del entorno Docker. ¿Continuar? (si/no) " r
[[ "$r" == "si" ]] || exit 1
docker compose down -v
docker compose up -d --build
