#!/bin/bash
# Instala los temporizadores systemd (de usuario) que automatizan respaldos,
# verificación, mantenimiento y monitoreo.  Desinstalar: ./instalar_tareas.sh --quitar
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.config/systemd/user"
mkdir -p "$DEST" "$RAIZ/logs"

#        nombre                comando                         calendario
TAREAS=("backup-logico|backup_logico.sh|*-*-* 02:00:00"
        "backup-fisico|backup_fisico.sh|Sun *-*-* 03:00:00"
        "verificar-backup|verificar_backup.sh|Mon *-*-* 04:00:00"
        "mant-diario|mantenimiento.sh diario|*-*-* 03:30:00"
        "mant-semanal|mantenimiento.sh semanal|Sun *-*-* 04:30:00"
        "monitoreo|monitoreo.sh|*:0/5")

if [[ "${1:-}" == "--quitar" ]]; then
  for t in "${TAREAS[@]}"; do
    n="hotel-${t%%|*}"; systemctl --user disable --now "$n.timer" 2>/dev/null || true
    rm -f "$DEST/$n.service" "$DEST/$n.timer"
  done
  systemctl --user daemon-reload; echo "Tareas eliminadas"; exit 0
fi

for t in "${TAREAS[@]}"; do
  IFS='|' read -r nombre cmd cal <<<"$t"
  n="hotel-$nombre"
  cat > "$DEST/$n.service" <<UNIT
[Unit]
Description=Hotel DB - $nombre
[Service]
Type=oneshot
SuccessExitStatus=1
WorkingDirectory=$RAIZ
ExecStart=/bin/bash -c '$RAIZ/scripts/$cmd >> $RAIZ/logs/$nombre.log 2>&1'
UNIT
  cat > "$DEST/$n.timer" <<UNIT
[Unit]
Description=Programación de hotel-$nombre
[Timer]
OnCalendar=$cal
Persistent=true
[Install]
WantedBy=timers.target
UNIT
done
systemctl --user daemon-reload
for t in "${TAREAS[@]}"; do systemctl --user enable --now "hotel-${t%%|*}.timer"; done
systemctl --user list-timers 'hotel-*'
