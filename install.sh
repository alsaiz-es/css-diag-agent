#!/usr/bin/env bash
set -euo pipefail

# Instalador unificado css_diag_agent
# Uso: ./install.sh [--all | --diagnet | --vmwatch | --alerts | --status | --uninstall]
#   Sin argumentos equivale a --all
# Compatible con systemd e init.d (detección automática)

BASE="/opt/css_diag_agent"
LOG_DIR="/var/log/css_diag_agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detectar init system
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT_SYS="systemd"
else
  INIT_SYS="initd"
fi

mkdir -p "$BASE" "$LOG_DIR"

# Instalar conf solo si no existe (no machacar configuración del usuario)
if [[ ! -f "$BASE/diagnet.conf" ]]; then
  install -m 0644 "${SCRIPT_DIR}/diagnet.conf" "$BASE/diagnet.conf"
  echo "Configuración instalada en $BASE/diagnet.conf — editar según entorno."
else
  echo "Configuración existente en $BASE/diagnet.conf — no se sobreescribe."
fi

echo "Init system detectado: $INIT_SYS"

# --- Funciones systemd ---

systemd_install_diagnet() {
  install -m 0644 "${SCRIPT_DIR}/diagnet/echo_server.service" /etc/systemd/system/
  install -m 0644 "${SCRIPT_DIR}/diagnet/diagnet.service"     /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now echo_server.service
  systemctl enable --now diagnet.service
}

systemd_install_vmwatch() {
  install -m 0644 "${SCRIPT_DIR}/vmwatch/vmwatch.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now vmwatch.service
}

systemd_install_alerts() {
  install -m 0644 "${SCRIPT_DIR}/alerts/diagnet-alert.service" /etc/systemd/system/
  install -m 0644 "${SCRIPT_DIR}/alerts/diagnet-alert.timer"   /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now diagnet-alert.timer
}

systemd_status() {
  local units=(echo_server.service diagnet.service vmwatch.service diagnet-alert.timer)
  for unit in "${units[@]}"; do
    printf "  %-28s " "$unit"
    if systemctl is-enabled "$unit" 2>/dev/null | grep -q enabled; then
      systemctl is-active "$unit" 2>/dev/null || true
    else
      echo "no instalado"
    fi
  done
}

systemd_uninstall() {
  for svc in diagnet-alert.timer diagnet-alert.service echo_server.service diagnet.service vmwatch.service; do
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc"
  done
  systemctl daemon-reload
}

# --- Funciones init.d ---

initd_install_svc() {
  local src="$1" name="$2"
  install -m 0755 "$src" "/etc/init.d/${name}"
  if command -v update-rc.d >/dev/null 2>&1; then
    update-rc.d "$name" defaults
  elif command -v chkconfig >/dev/null 2>&1; then
    chkconfig --add "$name"
    chkconfig "$name" on
  fi
  "/etc/init.d/${name}" start
}

initd_install_diagnet() {
  initd_install_svc "${SCRIPT_DIR}/diagnet/echo_server.init" "css-echo-server"
  initd_install_svc "${SCRIPT_DIR}/diagnet/diagnet.init" "css-diagnet"
}

initd_install_vmwatch() {
  initd_install_svc "${SCRIPT_DIR}/vmwatch/vmwatch.init" "css-vmwatch"
}

initd_install_alerts() {
  install -m 0644 "${SCRIPT_DIR}/alerts/diagnet-alert.cron" /etc/cron.d/css-diagnet-alert
}

initd_status() {
  local svcs=(css-echo-server css-diagnet css-vmwatch)
  for svc in "${svcs[@]}"; do
    printf "  %-28s " "$svc"
    if [ -x "/etc/init.d/${svc}" ]; then
      "/etc/init.d/${svc}" status 2>/dev/null || true
    else
      echo "no instalado"
    fi
  done
  printf "  %-28s " "css-diagnet-alert (cron)"
  if [ -f /etc/cron.d/css-diagnet-alert ]; then
    echo "instalado"
  else
    echo "no instalado"
  fi
}

initd_uninstall() {
  for svc in css-diagnet css-echo-server css-vmwatch; do
    if [ -x "/etc/init.d/${svc}" ]; then
      "/etc/init.d/${svc}" stop 2>/dev/null || true
      if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d -f "$svc" remove
      elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --del "$svc"
      fi
      rm -f "/etc/init.d/${svc}"
    fi
  done
  rm -f /etc/cron.d/css-diagnet-alert
}

# --- Funciones comunes de instalación ---

install_diagnet() {
  local D="$BASE/diagnet"; mkdir -p "$D"
  install -m 0755 "${SCRIPT_DIR}/diagnet/diagnet.sh"        "$D/"
  install -m 0755 "${SCRIPT_DIR}/diagnet/echo_server.py"    "$D/"
  install -m 0755 "${SCRIPT_DIR}/diagnet/diagnet_report.sh" "$D/"
  "${INIT_SYS}_install_diagnet"
  echo "DiagNet instalado. Echo en :$(grep -oP 'PEER_PORT=\K[0-9]+' "$BASE/diagnet.conf" 2>/dev/null || echo 9400) y sondas activas."
}

install_vmwatch() {
  local D="$BASE/vmwatch"; mkdir -p "$D"
  install -m 0755 "${SCRIPT_DIR}/vmwatch/vmwatch.sh"  "$D/"
  install -m 0755 "${SCRIPT_DIR}/vmwatch/snapshot.sh"  "$D/"
  install -m 0755 "${SCRIPT_DIR}/vmwatch/tcpdump.sh"   "$D/"
  "${INIT_SYS}_install_vmwatch"
  echo "VMWatch instalado."
}

install_alerts() {
  local D="$BASE/alerts"; mkdir -p "$D"
  install -m 0755 "${SCRIPT_DIR}/alerts/diagnet_alert.sh" "$D/"
  "${INIT_SYS}_install_alerts"
  echo "Alertas instaladas (cada 5 min)."
}

show_status() {
  echo "=== css_diag_agent — estado ($INIT_SYS) ==="
  echo "Conf: $BASE/diagnet.conf $([ -f "$BASE/diagnet.conf" ] && echo '[OK]' || echo '[NO EXISTE]')"
  echo "Logs: $LOG_DIR"
  echo
  "${INIT_SYS}_status"
}

do_uninstall() {
  echo "Parando y deshabilitando servicios ($INIT_SYS)..."
  "${INIT_SYS}_uninstall"
  echo "Servicios eliminados."
  echo "Binarios en $BASE y logs en $LOG_DIR NO se borran (por seguridad)."
  echo "Para eliminar completamente: rm -rf $BASE $LOG_DIR"
}

MODE="${1:---all}"
case "$MODE" in
  --all)       install_diagnet; install_vmwatch; install_alerts ;;
  --diagnet)   install_diagnet ;;
  --vmwatch)   install_vmwatch ;;
  --alerts)    install_alerts ;;
  --status)    show_status; exit 0 ;;
  --uninstall) do_uninstall; exit 0 ;;
  *)           echo "Uso: $0 [--all | --diagnet | --vmwatch | --alerts | --status | --uninstall]"; exit 1 ;;
esac

echo "Logs en: $LOG_DIR"
echo "Conf en: $BASE/diagnet.conf"
