#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR='/opt/nosql-injection-lab'
STATE_DIR='/etc/nosql-injection-lab'
STATE_FILE="$STATE_DIR/installer.env"
CONFIG_FILE="$STATE_DIR/config.php"
SITE_FILE='/etc/apache2/sites-available/000-00-nosql-injection-lab.conf'
SITE_NAME='000-00-nosql-injection-lab.conf'
ADMIN_FILE='/root/.nosql-injection-lab-admin.env'
DEFAULT_MONGO_URI='mongodb://127.0.0.1:27017/admin?serverSelectionTimeoutMS=3000'

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; echo "ERROR: el instalador ha fallado en la línea ${LINENO} (código ${rc}). No se declara la instalación como correcta." >&2; exit "$rc"' ERR

[[ "$(id -u)" -eq 0 ]] || die 'Ejecuta el instalador como root: sudo bash install.sh'
[[ -r /etc/os-release ]] || die 'No se puede identificar el sistema operativo.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == 'debian' ]] || die "Se requiere Debian. Sistema detectado: ${PRETTY_NAME:-desconocido}."
[[ "${VERSION_ID:-}" == '12' || "${VERSION_ID:-}" == '13' ]] || die "Este instalador está preparado para Debian 12/13; versión detectada: ${VERSION_ID:-desconocida}."

command -v mongosh >/dev/null 2>&1 || die 'No se encuentra mongosh. Instala el shell oficial de MongoDB antes de continuar; no se instalará otro servidor de base de datos.'
command -v systemctl >/dev/null 2>&1 || die 'No se encuentra systemctl; no se puede verificar el servicio MongoDB.'
if systemctl is-active --quiet mongod; then
  MONGO_SERVICE='mongod'
elif systemctl is-active --quiet mongodb; then
  MONGO_SERVICE='mongodb'
else
  die 'MongoDB no está activo (se probaron los servicios mongod y mongodb). Arranca la instancia existente y vuelve a ejecutar el instalador.'
fi
if ! command -v python3 >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 iproute2 openssl
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MONGO_CONFIG="$(systemctl show "$MONGO_SERVICE" -p ExecStart --value | sed -nE 's/.*--config(=|[[:space:]]+)([^ ;}]+).*/\2/p' | head -n1)"
if [[ -z "$MONGO_CONFIG" ]]; then
  if [[ -f /etc/mongod.conf ]]; then MONGO_CONFIG='/etc/mongod.conf'
  elif [[ -f /etc/mongodb.conf ]]; then MONGO_CONFIG='/etc/mongodb.conf'
  else die "No se pudo detectar el archivo de configuración de MongoDB desde systemd."; fi
fi
[[ -f "$MONGO_CONFIG" ]] || die "El servicio $MONGO_SERVICE hace referencia a un archivo inexistente: $MONGO_CONFIG"
[[ -f "$SCRIPT_DIR/scripts/mongodb_config.py" ]] || die 'Falta scripts/mongodb_config.py; extrae de nuevo el ZIP corregido antes de instalar.'

# Preserva el acceso remoto ya configurado y añade loopback para la conexión local de PHP.
# Si MongoDB no escuchaba en una IP LAN concreta, selecciona la primera IPv4 global.
MONGO_LAN_IP=''
while IFS= read -r listener; do
  [[ -n "$listener" ]] || continue
  addr="${listener##* }"
  if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:27017$ ]]; then
    host="${addr%:27017}"
    if [[ "$host" != '127.0.0.1' && "$host" != '0.0.0.0' ]]; then MONGO_LAN_IP="$host"; break; fi
  fi
done < <(ss -lntH 'sport = :27017' 2>/dev/null | awk '{print $4}' || true)
if [[ -z "$MONGO_LAN_IP" ]]; then
  MONGO_LAN_IP="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); if(a[1] !~ /^127\./) {print a[1]; exit}}' || true)"
fi
[[ -n "$MONGO_LAN_IP" ]] || die 'No se encontró una IPv4 de red para permitir la administración remota de MongoDB. Configura una interfaz de red en la VM y vuelve a ejecutar.'

if [[ ! -e "${MONGO_CONFIG}.pre-nosql-injection-lab" ]]; then
  cp -a "$MONGO_CONFIG" "${MONGO_CONFIG}.pre-nosql-injection-lab"
  echo "Copia previa de configuración: ${MONGO_CONFIG}.pre-nosql-injection-lab"
fi

apply_mongo_config_change() {
  local mode="$1"; shift
  local temp_copy output final_state
  temp_copy="$(mktemp)"
  cp -a "$MONGO_CONFIG" "$temp_copy"
  case "$mode" in
    ensure-bind) output="$(python3 "$SCRIPT_DIR/scripts/mongodb_config.py" "$MONGO_CONFIG" ensure-bind "$@")" ;;
    enable-auth) output="$(python3 "$SCRIPT_DIR/scripts/mongodb_config.py" "$MONGO_CONFIG" enable-auth)" ;;
    disable-auth) output="$(python3 "$SCRIPT_DIR/scripts/mongodb_config.py" "$MONGO_CONFIG" disable-auth)" ;;
    recovery-local) output="$(python3 "$SCRIPT_DIR/scripts/mongodb_config.py" "$MONGO_CONFIG" recovery-local "$@")" ;;
    *) rm -f "$temp_copy"; die "Modo de configuración MongoDB desconocido: $mode" ;;
  esac
  printf '%s\n' "$output" | sed '$d'
  final_state="$(printf '%s\n' "$output" | tail -n1)"
  if [[ "$final_state" == 'changed' ]]; then
    if ! systemctl restart "$MONGO_SERVICE"; then
      cat "$temp_copy" > "$MONGO_CONFIG"
      systemctl restart "$MONGO_SERVICE" >/dev/null 2>&1 || true
      rm -f "$temp_copy"
      die "MongoDB no reinició tras el cambio de configuración. Se ha restaurado el archivo previo a esta modificación: $MONGO_CONFIG. Consulta journalctl -u $MONGO_SERVICE."
    fi
    if ! systemctl is-active --quiet "$MONGO_SERVICE"; then
      cat "$temp_copy" > "$MONGO_CONFIG"
      systemctl restart "$MONGO_SERVICE" >/dev/null 2>&1 || true
      rm -f "$temp_copy"
      die "MongoDB no quedó activo tras el cambio; se ha restaurado la configuración previa a esta modificación."
    fi
  fi
  rm -f "$temp_copy"
}

# No ocultar los errores de la verificación: guardar el URI en una variable evita
# pedir credenciales por pantalla, mientras mongosh informa de authSource/roles.
admin_uri_works() {
  local uri="$1" output_file
  output_file="$(mktemp)"
  if mongosh "$uri" --quiet --eval 'const s=db.runCommand({connectionStatus:1}); const a=(s.authInfo||{}).authenticatedUsers||[]; if(s.ok!==1 || a.length===0) quit(2); const r=db.getSiblingDB("admin").runCommand({usersInfo:1}); quit(r.ok===1?0:3);' >"$output_file" 2>&1; then
    rm -f "$output_file"
    return 0
  fi
  printf 'Diagnóstico de mongosh al verificar la cuenta administrativa:\n' >&2
  sed -E 's#mongodb://[^[:space:]@]+:[^@[:space:]]+@#mongodb://[credenciales-ocultas]@#g' "$output_file" >&2
  rm -f "$output_file"
  return 1
}

# Recuperación de una ejecución previa que activó authorization pero no consiguió
# verificar al administrador generado. Solo es admisible si la copia previa demuestra
# que la autorización no estaba habilitada antes de este laboratorio.
repair_generated_admin() {
  local backup="${MONGO_CONFIG}.pre-nosql-injection-lab" answer candidate repair_eval
  [[ -r "$ADMIN_FILE" && -r "$backup" ]] || return 1
  # shellcheck disable=SC1090
  source "$ADMIN_FILE"
  [[ "${ADMIN_USER:-}" =~ ^nosql_lab_admin_[A-Za-z0-9_]+$ && "${ADMIN_PASSWORD:-}" =~ ^[a-f0-9]{48}$ ]] || return 1
  if grep -Eq '^[[:space:]]*authorization:[[:space:]]*enabled([[:space:]#]|$)' "$backup"; then
    return 1
  fi
  echo
  echo 'La instalación anterior parece haber activado la autenticación, pero la cuenta administrativa generada no se valida.'
  echo 'La copia original indica que la autorización no estaba activada antes del laboratorio.'
  echo 'Para reparar la cuenta, MongoDB se reiniciará temporalmente sin autenticación y escuchando SOLO en 127.0.0.1.'
  echo 'La administración remota se interrumpirá durante unos segundos; los equipos de la LAN no podrán entrar mientras se repara.'
  read -r -p '¿Autorizas esta reparación local automática? [s/N]: ' answer
  [[ "$answer" =~ ^([sS]|[sS][iI])$ ]] || return 1

  log 'Reparando el administrador MongoDB generado por el instalador'
  local recovery_config
  recovery_config="$(mktemp)"
  cp -a "$MONGO_CONFIG" "$recovery_config"
  if ! apply_mongo_config_change recovery-local --ip 127.0.0.1; then
    cat "$recovery_config" > "$MONGO_CONFIG"
    rm -f "$recovery_config"
    systemctl restart "$MONGO_SERVICE" >/dev/null 2>&1 || true
    die 'No se pudo restringir MongoDB a loopback para la reparación. Se ha restaurado la configuración previa.'
  fi
  if ! mongosh "$DEFAULT_MONGO_URI" --quiet --eval 'quit(db.runCommand({ping:1}).ok===1?0:1)' >/dev/null 2>&1; then
    cat "$recovery_config" > "$MONGO_CONFIG"
    rm -f "$recovery_config"
    systemctl restart "$MONGO_SERVICE" >/dev/null 2>&1 || true
    die 'MongoDB no responde por loopback durante la reparación. Se restauró la configuración anterior; consulta journalctl.'
  fi
  repair_eval="var newAdminUser='${ADMIN_USER}'; var newAdminPassword='${ADMIN_PASSWORD}'; const a=db.getSiblingDB('admin'); const old=a.getUser(newAdminUser); if(old){a.updateUser(newAdminUser,{pwd:newAdminPassword,roles:[{role:'root',db:'admin'}]});}else{a.createUser({user:newAdminUser,pwd:newAdminPassword,roles:[{role:'root',db:'admin'}]});} print('Cuenta administrativa reparada.');"
  if ! mongosh "$DEFAULT_MONGO_URI" --quiet --eval "$repair_eval"; then
    cat "$recovery_config" > "$MONGO_CONFIG"
    rm -f "$recovery_config"
    systemctl restart "$MONGO_SERVICE" >/dev/null 2>&1 || true
    die 'No se pudo recrear la cuenta administrativa. Se restauró la configuración anterior; consulta los logs de MongoDB.'
  fi
  # Restaura exactamente la configuración que había antes de la reparación:
  # authorization habilitado y listener LAN para administración remota.
  cat "$recovery_config" > "$MONGO_CONFIG"
  rm -f "$recovery_config"
  if ! systemctl restart "$MONGO_SERVICE" || ! systemctl is-active --quiet "$MONGO_SERVICE"; then
    die 'La cuenta se reparó, pero MongoDB no pudo reiniciarse con su configuración original. Consulta journalctl -u mongod.'
  fi
  candidate="mongodb://${ADMIN_USER}:${ADMIN_PASSWORD}@127.0.0.1:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000"
  if admin_uri_works "$candidate"; then
    ADMIN_URI="$candidate"
    echo 'La cuenta administrativa se ha reparado y verificado correctamente. La IP LAN y la autenticación originales están restauradas.'
    return 0
  fi
  die 'La reparación terminó, pero las credenciales siguen sin validarse. No sigas instalando; consulta journalctl -u mongod y el archivo de configuración.'
}

log 'Ajustando las interfaces de MongoDB sin eliminar la IP de administración remota'
apply_mongo_config_change ensure-bind --ip 127.0.0.1 --ip "$MONGO_LAN_IP"
PING_DIAGNOSTIC="$(mktemp)"
if ! mongosh "$DEFAULT_MONGO_URI" --quiet --eval 'quit(db.runCommand({ping:1}).ok===1?0:1)' >"$PING_DIAGNOSTIC" 2>&1; then
  if grep -Eiq 'authentication failed|requires authentication|not authorized|unauthorized' "$PING_DIAGNOSTIC"; then
    echo 'La conexión local responde, pero MongoDB exige autenticación. Se comprobarán las credenciales administrativas a continuación.'
  else
    cat "$PING_DIAGNOSTIC" >&2
    rm -f "$PING_DIAGNOSTIC"
    die "MongoDB no acepta la conexión local en 127.0.0.1:27017. Revisa $MONGO_CONFIG y journalctl -u $MONGO_SERVICE. La IP LAN que se intentó conservar es $MONGO_LAN_IP."
  fi
fi
rm -f "$PING_DIAGNOSTIC"
MONGO_LISTENERS_NOW="$(ss -lntH 'sport = :27017' 2>/dev/null | awk '{print $4}' || true)"
printf 'Listeners actuales de MongoDB:\n%s\n' "$MONGO_LISTENERS_NOW"
if ! grep -Fxq '127.0.0.1:27017' <<< "$MONGO_LISTENERS_NOW" \
  && ! grep -Fxq '0.0.0.0:27017' <<< "$MONGO_LISTENERS_NOW" \
  && ! grep -Fxq '*:27017' <<< "$MONGO_LISTENERS_NOW"; then
  die "MongoDB no aparece escuchando en loopback IPv4 o comodín tras editar $MONGO_CONFIG. No se puede garantizar la conexión local de PHP."
fi
if ! grep -Fxq "${MONGO_LAN_IP}:27017" <<< "$MONGO_LISTENERS_NOW" \
  && ! grep -Fxq '0.0.0.0:27017' <<< "$MONGO_LISTENERS_NOW" \
  && ! grep -Fxq '*:27017' <<< "$MONGO_LISTENERS_NOW"; then
  die "MongoDB no aparece escuchando en la IP LAN ${MONGO_LAN_IP}:27017. La aplicación necesita localhost y has solicitado conservar la administración remota; revisa $MONGO_CONFIG."
fi

log 'Detectando el estado de autorización de MongoDB'
if mongosh "$DEFAULT_MONGO_URI" --quiet --eval 'const r=db.getSiblingDB("admin").runCommand({usersInfo:1}); quit(r.ok===1?0:1)' >/dev/null 2>&1; then
  AUTH_ENABLED=0
  echo 'La autorización estaba desactivada. Para que MongoDB aplique de verdad los permisos por colección, se activará con un usuario administrador nuevo.'
  echo 'Esto hace que otros clientes que actualmente usan MongoDB sin credenciales tengan que autenticarse; la configuración original se conserva en la copia de seguridad.'
  if [[ -r "$ADMIN_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ADMIN_FILE"
  else
    suffix="$(openssl rand -hex 4)"
    ADMIN_USER="nosql_lab_admin_${suffix}"
    ADMIN_PASSWORD="$(openssl rand -hex 24)"
    umask 077
    printf 'ADMIN_USER=%s\nADMIN_PASSWORD=%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$ADMIN_FILE"
    chown root:root "$ADMIN_FILE"
    chmod 600 "$ADMIN_FILE"
  fi
  [[ "${ADMIN_USER:-}" =~ ^[A-Za-z0-9_]+$ && "${ADMIN_PASSWORD:-}" =~ ^[a-f0-9]{48}$ ]] || die "El archivo de credenciales administrativo $ADMIN_FILE no tiene el formato esperado. No se modificará automáticamente."
  ADMIN_EVAL="var newAdminUser='${ADMIN_USER}'; var newAdminPassword='${ADMIN_PASSWORD}'; const a=db.getSiblingDB('admin'); const old=a.getUser(newAdminUser); if(old){a.updateUser(newAdminUser,{pwd:newAdminPassword,roles:[{role:'root',db:'admin'}]});}else{a.createUser({user:newAdminUser,pwd:newAdminPassword,roles:[{role:'root',db:'admin'}]});} print('Administrador de MongoDB preparado.');"
  mongosh "$DEFAULT_MONGO_URI" --quiet --eval "$ADMIN_EVAL"
  apply_mongo_config_change enable-auth
  ADMIN_URI="mongodb://${ADMIN_USER}:${ADMIN_PASSWORD}@127.0.0.1:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000"
  if ! admin_uri_works "$ADMIN_URI"; then
    echo 'La comprobación inicial falló. Se intentará reparar la cuenta porque esta ejecución acaba de activar authorization.'
    repair_generated_admin || die "Se activó la autenticación, pero no se ha podido verificar la cuenta administrativa. Comprueba el diagnóstico anterior y journalctl -u $MONGO_SERVICE."
  fi
  AUTH_ENABLED=1
else
  AUTH_ENABLED=1
  echo 'La autorización está activa. Se usará una cuenta administrativa existente; sus credenciales no se guardarán en la configuración web.'
  ADMIN_URI=''
  if [[ -r "$ADMIN_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ADMIN_FILE"
    if [[ "${ADMIN_USER:-}" =~ ^[A-Za-z0-9_]+$ && "${ADMIN_PASSWORD:-}" =~ ^[a-f0-9]{48}$ ]]; then
      candidate="mongodb://${ADMIN_USER}:${ADMIN_PASSWORD}@127.0.0.1:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000"
      if admin_uri_works "$candidate"; then
        ADMIN_URI="$candidate"
      else
        echo 'Las credenciales guardadas para el administrador generado no pasan la verificación.'
        if repair_generated_admin; then ADMIN_URI="$candidate"; fi
      fi
    fi
  fi
  if [[ -z "$ADMIN_URI" ]]; then
    read -r -s -p 'Introduce la URI administrativa EXISTENTE de MongoDB (no se guardará por este instalador): ' ADMIN_URI
    printf '\n'
  fi
  [[ -n "$ADMIN_URI" ]] || die 'No se ha indicado una URI administrativa.'
  if ! admin_uri_works "$ADMIN_URI"; then
    die 'La URI no autentica o no permite administrar usuarios en admin. Revisa el diagnóstico anterior, usuario, contraseña, authSource y privilegios.'
  fi
fi

log 'Instalando Apache, PHP, Composer y herramientas de comprobación'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  apache2 libapache2-mod-php php-cli php-dev php-pear php-mongodb \
  build-essential autoconf make libtool \
  php-curl php-mbstring php-xml php-zip composer \
  pkg-config libssl-dev ca-certificates curl jq openssl iproute2 python3

# La librería seleccionada usa la rama 1.21.x del driver. En Debian 12/13 puede
# existir un paquete con otra versión; se instala 1.21.11 si no es compatible.
if ! php -r '$v = phpversion("mongodb") ?: "0"; exit((str_starts_with($v, "1.") && version_compare($v, "1.21.11", ">=")) ? 0 : 1);'; then
  log 'Ajustando la extensión mongodb a la rama compatible 1.21.11'
  mapfile -t MONGO_PHP_PACKAGES < <(dpkg-query -W -f='${binary:Package}\n' 'php*-mongodb' 2>/dev/null || true)
  if (( ${#MONGO_PHP_PACKAGES[@]} > 0 )); then apt-get purge -y "${MONGO_PHP_PACKAGES[@]}" || true; fi
  phpdismod mongodb >/dev/null 2>&1 || true
  pecl uninstall mongodb >/dev/null 2>&1 || true
  pecl channel-update pecl.php.net
  printf '\n' | pecl install mongodb-1.21.11
  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  install -d -m 755 "/etc/php/${PHP_VERSION}/mods-available"
  printf '%s\n' 'extension=mongodb.so' > "/etc/php/${PHP_VERSION}/mods-available/mongodb.ini"
  phpenmod mongodb
fi
php -r 'if (PHP_VERSION_ID < 80100) { fwrite(STDERR, "PHP 8.1 o posterior es obligatorio.\n"); exit(1); } if (!extension_loaded("mongodb")) { fwrite(STDERR, "La extensión mongodb no está cargada en CLI.\n"); exit(1); } $v=phpversion("mongodb"); if (!str_starts_with($v, "1.") || version_compare($v, "1.21.11", "<")) { fwrite(STDERR, "Versión de mongodb no compatible: ".$v."\n"); exit(1); }' || die 'No se ha podido preparar una versión compatible de PHP o de la extensión mongodb.'

# Copia solo los ficheros del proyecto; el código de la aplicación no contiene secretos.
install -d -m 750 "$APP_DIR"
if [[ "$SCRIPT_DIR" != "$APP_DIR" ]]; then
  for item in install.sh README.md composer.json .gitignore config scripts public; do
    [[ -e "$SCRIPT_DIR/$item" ]] || die "Falta el fichero del proyecto: $SCRIPT_DIR/$item"
    cp -a "$SCRIPT_DIR/$item" "$APP_DIR/"
  done
fi

install -d -o root -g www-data -m 750 "$STATE_DIR"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
else
  suffix="$(openssl rand -hex 4)"
  APP_DB_USER="nosql_lab_login_${suffix}"
  APP_DB_PASSWORD="$(openssl rand -hex 24)"
  APP_DB_ROLE="nosql_lab_login_read_${suffix}"
fi
# Migra de forma aditiva el estado de una ejecución anterior del laboratorio.
if [[ -z "${APP_DB_USER:-}" || -z "${APP_DB_PASSWORD:-}" || -z "${APP_DB_ROLE:-}" ]]; then die "El estado anterior $STATE_FILE no es válido; no se sobrescribirá automáticamente."; fi
suffix="${APP_DB_USER##*_}"
: "${ANA_DB_USER:=nosql_lab_ana_${suffix}}"
: "${ANA_DB_PASSWORD:=$(openssl rand -hex 24)}"
: "${ANA_DB_ROLE:=nosql_lab_ana_read_${suffix}}"
: "${BRUNO_DB_USER:=nosql_lab_bruno_${suffix}}"
: "${BRUNO_DB_PASSWORD:=$(openssl rand -hex 24)}"
: "${BRUNO_DB_ROLE:=nosql_lab_bruno_read_${suffix}}"
: "${CARLA_DB_USER:=nosql_lab_carla_${suffix}}"
: "${CARLA_DB_PASSWORD:=$(openssl rand -hex 24)}"
: "${CARLA_DB_ROLE:=nosql_lab_carla_read_${suffix}}"
for name in APP_DB_USER APP_DB_ROLE ANA_DB_USER ANA_DB_ROLE BRUNO_DB_USER BRUNO_DB_ROLE CARLA_DB_USER CARLA_DB_ROLE; do
  [[ "${!name}" =~ ^[A-Za-z0-9_]+$ ]] || die "El identificador guardado $name tiene un formato no válido."
done
for name in APP_DB_PASSWORD ANA_DB_PASSWORD BRUNO_DB_PASSWORD CARLA_DB_PASSWORD; do
  [[ "${!name}" =~ ^[a-f0-9]{48}$ ]] || die "El secreto guardado $name tiene un formato no válido."
done
umask 077
cat > "$STATE_FILE" <<STATE
APP_DB_USER=$APP_DB_USER
APP_DB_PASSWORD=$APP_DB_PASSWORD
APP_DB_ROLE=$APP_DB_ROLE
ANA_DB_USER=$ANA_DB_USER
ANA_DB_PASSWORD=$ANA_DB_PASSWORD
ANA_DB_ROLE=$ANA_DB_ROLE
BRUNO_DB_USER=$BRUNO_DB_USER
BRUNO_DB_PASSWORD=$BRUNO_DB_PASSWORD
BRUNO_DB_ROLE=$BRUNO_DB_ROLE
CARLA_DB_USER=$CARLA_DB_USER
CARLA_DB_PASSWORD=$CARLA_DB_PASSWORD
CARLA_DB_ROLE=$CARLA_DB_ROLE
STATE
chown root:root "$STATE_FILE"
chmod 600 "$STATE_FILE"

APP_MONGO_URI="mongodb://${APP_DB_USER}:${APP_DB_PASSWORD}@127.0.0.1:27017/nosql_lab?authSource=nosql_lab&serverSelectionTimeoutMS=3000"
ANA_MONGO_URI="mongodb://${ANA_DB_USER}:${ANA_DB_PASSWORD}@127.0.0.1:27017/nosql_lab?authSource=nosql_lab&serverSelectionTimeoutMS=3000"
BRUNO_MONGO_URI="mongodb://${BRUNO_DB_USER}:${BRUNO_DB_PASSWORD}@127.0.0.1:27017/nosql_lab?authSource=nosql_lab&serverSelectionTimeoutMS=3000"
CARLA_MONGO_URI="mongodb://${CARLA_DB_USER}:${CARLA_DB_PASSWORD}@127.0.0.1:27017/nosql_lab?authSource=nosql_lab&serverSelectionTimeoutMS=3000"

log 'Copiando el proyecto y creando los roles reales de MongoDB por colección'
EVAL="var appDbUser='${APP_DB_USER}'; var appDbPassword='${APP_DB_PASSWORD}'; var appRoleName='${APP_DB_ROLE}'; var anaDbUser='${ANA_DB_USER}'; var anaDbPassword='${ANA_DB_PASSWORD}'; var anaRoleName='${ANA_DB_ROLE}'; var brunoDbUser='${BRUNO_DB_USER}'; var brunoDbPassword='${BRUNO_DB_PASSWORD}'; var brunoRoleName='${BRUNO_DB_ROLE}'; var carlaDbUser='${CARLA_DB_USER}'; var carlaDbPassword='${CARLA_DB_PASSWORD}'; var carlaRoleName='${CARLA_DB_ROLE}'; load('${APP_DIR}/scripts/setup_db.js');"
mongosh "$ADMIN_URI" --quiet --eval "$EVAL"

log 'Generando la configuración privada para la conexión de login y las conexiones por usuario'
cat > "$CONFIG_FILE" <<PHP_CONFIG
<?php
declare(strict_types=1);
return [
    'mongo_uri' => '${APP_MONGO_URI}',
    'mongo_user_uris' => [
        'ana' => '${ANA_MONGO_URI}',
        'bruno' => '${BRUNO_MONGO_URI}',
        'carla' => '${CARLA_MONGO_URI}',
    ],
    'database' => 'nosql_lab',
    'max_documents' => 50,
];
PHP_CONFIG
chown root:www-data "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"
chown root:www-data "$STATE_DIR"
chmod 750 "$STATE_DIR"

log 'Instalando dependencias Composer'
cd "$APP_DIR"
export COMPOSER_ALLOW_SUPERUSER=1
if [[ -f composer.lock ]]; then
  composer install --no-interaction --prefer-dist --no-dev --optimize-autoloader
else
  composer update --no-interaction --prefer-dist --no-dev --optimize-autoloader
fi
composer check-platform-reqs --no-dev

log 'Configurando Apache sin publicar la configuración privada ni vendor/'
cat > "$SITE_FILE" <<APACHE
<VirtualHost *:80>
    ServerName nosql-injection-lab.local
    DocumentRoot ${APP_DIR}/public
    DirectoryIndex index.php

    <Directory ${APP_DIR}/public>
        Options -Indexes -Includes
        AllowOverride None
        Require all granted
    </Directory>

    <FilesMatch "(?i)^\\.">
        Require all denied
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/nosql-injection-lab-error.log
    CustomLog \${APACHE_LOG_DIR}/nosql-injection-lab-access.log combined
</VirtualHost>
APACHE
chown root:root "$SITE_FILE"
chmod 644 "$SITE_FILE"
a2enmod headers >/dev/null
a2enmod "php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" >/dev/null 2>&1 || true
a2ensite "$SITE_NAME" >/dev/null

chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 750 {} \;
find "$APP_DIR" -type f -exec chmod 640 {} \;
chmod 750 "$APP_DIR/install.sh" "$APP_DIR/scripts/test_injection.sh" "$APP_DIR/scripts/reset_lab_data.sh" "$APP_DIR/scripts/mongodb_config.py"
chmod 640 "$APP_DIR/scripts/setup_db.js" "$APP_DIR/scripts/check_mongo.php" "$APP_DIR/scripts/check_mongodb_roles.php"

apache2ctl configtest
systemctl enable --now apache2
systemctl reload apache2

log 'Ejecutando comprobaciones independientes de PHP/MongoDB y Apache'
php "$APP_DIR/scripts/check_mongo.php"
php "$APP_DIR/scripts/check_mongodb_roles.php"
if ! curl --fail --silent --show-error --max-time 8 http://127.0.0.1/ | grep -q 'NoSQL Lab'; then
  die 'Apache no devuelve la página de NoSQL Lab por HTTP. Consulta /var/log/apache2/nosql-injection-lab-error.log.'
fi

IP_LOCAL="$MONGO_LAN_IP"
if [[ -z "$IP_LOCAL" ]]; then IP_LOCAL="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
ADMIN_USER_DISPLAY='cuenta administrativa existente'
if [[ -r "$ADMIN_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ADMIN_FILE"
  ADMIN_USER_DISPLAY="$ADMIN_USER"
fi

cat <<SUMMARY

============================================================
 NoSQL Lab instalado
============================================================
 Web desde esta VM:          http://127.0.0.1/
 Web desde la LAN:           http://${IP_LOCAL:-IP-DE-LA-VM}/
 MongoDB local PHP:          127.0.0.1:27017
 MongoDB administración LAN: ${IP_LOCAL:-IP-DE-LA-VM}:27017
 DocumentRoot:               ${APP_DIR}/public
 Config privada:             ${CONFIG_FILE}
 Estado privado:             ${STATE_FILE}
 Config MongoDB:             ${MONGO_CONFIG}
 Copia original:             ${MONGO_CONFIG}.pre-nosql-injection-lab
 Base de datos:              nosql_lab
 Log Apache:                 /var/log/apache2/nosql-injection-lab-error.log
 Pruebas web:                sudo bash ${APP_DIR}/scripts/test_injection.sh
 Pruebas roles MongoDB:      sudo php ${APP_DIR}/scripts/check_mongodb_roles.php
 Restaurar semillas:         sudo bash ${APP_DIR}/scripts/reset_lab_data.sh
 Usuario admin MongoDB:      ${ADMIN_USER_DISPLAY}
SUMMARY
if [[ -r "$ADMIN_FILE" ]]; then
  echo " Credenciales admin nuevas/gestionadas: sudo cat ${ADMIN_FILE}"
  echo " URI remota (sustituye USUARIO y CONTRASEÑA): mongodb://USUARIO:CONTRASEÑA@${IP_LOCAL:-IP-DE-LA-VM}:27017/admin?authSource=admin"
fi
cat <<'WARNING'

 IMPORTANTE:
 - MongoDB conserva la interfaz LAN para administración y también escucha en loopback.
 - La autorización de MongoDB está activa y cada cuenta de usuario tiene find solo en su colección.
 - Restringe TCP/27017 en el firewall a los equipos de administración; no expongas ese puerto a Internet.
 - El login tiene intencionadamente una NoSQL Injection. Mantén esta VM en el laboratorio.
WARNING
