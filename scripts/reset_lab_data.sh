#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ejecuta este script con sudo: sudo bash scripts/reset_lab_data.sh" >&2
  exit 1
fi
STATE_FILE="/etc/nosql-injection-lab/installer.env"
ADMIN_FILE="/root/.nosql-injection-lab-admin.env"
APP_DIR="/opt/nosql-injection-lab"
if [[ ! -r "$STATE_FILE" || ! -r "$APP_DIR/scripts/setup_db.js" ]]; then
  echo "No se encuentra la instalación de NoSQL Lab." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$STATE_FILE"
command -v mongosh >/dev/null 2>&1 || { echo 'ERROR: mongosh no está disponible.' >&2; exit 1; }

printf '%s\n' 'ATENCIÓN: se restaurarán las tres cuentas ficticias y los documentos de ejemplo identificados por sus _id conocidos.'
printf '%s' 'No se borrarán bases de datos ni colecciones completas. Escribe RESET-NOSQL-LAB para continuar: '
read -r CONFIRM
if [[ "$CONFIRM" != 'RESET-NOSQL-LAB' ]]; then
  echo 'Operación cancelada.'
  exit 0
fi

ADMIN_URI=''
if [[ -r "$ADMIN_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ADMIN_FILE"
  candidate="mongodb://${ADMIN_USER}:${ADMIN_PASSWORD}@127.0.0.1:27017/admin?authSource=admin&serverSelectionTimeoutMS=3000"
  if mongosh "$candidate" --quiet --eval 'const r=db.getSiblingDB("admin").runCommand({usersInfo:1}); quit(r.ok===1?0:1)' >/dev/null 2>&1; then
    ADMIN_URI="$candidate"
  fi
fi
if [[ -z "$ADMIN_URI" ]]; then
  DEFAULT_URI='mongodb://127.0.0.1:27017/admin?serverSelectionTimeoutMS=3000'
  if mongosh "$DEFAULT_URI" --quiet --eval 'const r=db.getSiblingDB("admin").runCommand({usersInfo:1}); quit(r.ok===1?0:1)' >/dev/null 2>&1; then
    ADMIN_URI="$DEFAULT_URI"
  else
    echo 'MongoDB requiere una cuenta administrativa.'
    read -r -s -p 'Introduce la URI administrativa completa (no se guardará): ' ADMIN_URI
    printf '\n'
  fi
fi
if ! mongosh "$ADMIN_URI" --quiet --eval 'const r=db.getSiblingDB("admin").runCommand({usersInfo:1}); quit(r.ok===1?0:1)' >/dev/null 2>&1; then
  echo 'ERROR: la URI no permite consultar usersInfo en admin.' >&2
  exit 1
fi

EVAL="var appDbUser='${APP_DB_USER}'; var appDbPassword='${APP_DB_PASSWORD}'; var appRoleName='${APP_DB_ROLE}'; var anaDbUser='${ANA_DB_USER}'; var anaDbPassword='${ANA_DB_PASSWORD}'; var anaRoleName='${ANA_DB_ROLE}'; var brunoDbUser='${BRUNO_DB_USER}'; var brunoDbPassword='${BRUNO_DB_PASSWORD}'; var brunoRoleName='${BRUNO_DB_ROLE}'; var carlaDbUser='${CARLA_DB_USER}'; var carlaDbPassword='${CARLA_DB_PASSWORD}'; var carlaRoleName='${CARLA_DB_ROLE}'; load('${APP_DIR}/scripts/setup_db.js');"
if mongosh "$ADMIN_URI" --quiet --eval "$EVAL"; then
  echo 'Datos ficticios y roles de MongoDB restaurados. No se ha eliminado la base de datos.'
else
  echo 'ERROR: no se pudieron restaurar los datos; comprueba la URI y los privilegios administrativos.' >&2
  exit 1
fi
