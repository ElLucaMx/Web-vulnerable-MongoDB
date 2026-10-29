#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1}"
BASE_URL="${BASE_URL%/}"
TMP_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { printf '  [OK] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf '  [FALLO] %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() {
  local description="$1"; shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}
http_status() {
  local output_file="$1"; shift
  curl --silent --show-error --max-time 8 -o "$output_file" -w '%{http_code}' "$@"
}
json_true() { jq -e "$@" >/dev/null 2>&1; }

printf '\nNoSQL Lab: comprobaciones contra %s\n\n' "$BASE_URL"

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: instala curl y jq antes de ejecutar estas pruebas." >&2
  exit 2
fi
SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCAL_CONFIG="${NOSQL_LAB_CONFIG:-/etc/nosql-injection-lab/config.php}"
if [[ -f "$SCRIPT_ROOT/vendor/autoload.php" && -r "$LOCAL_CONFIG" ]]; then
  if ! command -v php >/dev/null 2>&1; then
    echo "ERROR: PHP CLI no está instalado." >&2
    exit 2
  fi
  if ! php -r 'exit(extension_loaded("mongodb") ? 0 : 1);'; then
    echo "ERROR: la extensión PHP mongodb no está cargada." >&2
    exit 2
  fi
  pass 'PHP CLI, extensión mongodb y dependencias Composer disponibles'
  if php "$SCRIPT_ROOT/scripts/check_mongo.php" >/dev/null 2>&1; then
    pass 'Conexión independiente de PHP a MongoDB y consulta de web_users'
  else
    fail 'Conexión independiente de PHP a MongoDB y consulta de web_users'
  fi
  if php "$SCRIPT_ROOT/scripts/check_mongodb_roles.php" >"$TMP_DIR/mongo-roles.log" 2>&1; then
    pass 'Roles MongoDB: cada usuario puede leer solo su colección y la cuenta técnica no lee datos'
  else
    cat "$TMP_DIR/mongo-roles.log" >&2
    fail 'Roles MongoDB efectivos por colección'
  fi
else
  echo 'INFO: modo remoto: no se ejecutan las comprobaciones locales de PHP/MongoDB; se comprobarán los endpoints HTTP.'
fi

STATUS="$(http_status "$TMP_DIR/home.html" "$BASE_URL/")" || STATUS=000
if [[ "$STATUS" == 200 ]] && grep -q 'NoSQL Lab' "$TMP_DIR/home.html"; then
  pass 'Apache sirve la página principal por HTTP 200'
else
  fail "Apache sirve la página principal (HTTP recibido: $STATUS)"
fi

# Los endpoints privados deben rechazar clientes sin sesión.
STATUS="$(http_status "$TMP_DIR/anon-collections.json" "$BASE_URL/api/collections.php")" || STATUS=000
if [[ "$STATUS" == 401 ]] && json_true '.ok == false' "$TMP_DIR/anon-collections.json"; then
  pass 'API de colecciones rechaza una sesión anónima (401)'
else
  fail "API de colecciones rechaza una sesión anónima (HTTP $STATUS)"
fi
STATUS="$(http_status "$TMP_DIR/anon-documents.json" "$BASE_URL/api/documents.php?collection=pedidos_ana")" || STATUS=000
if [[ "$STATUS" == 401 ]] && json_true '.ok == false' "$TMP_DIR/anon-documents.json"; then
  pass 'API de documentos rechaza una sesión anónima (401)'
else
  fail "API de documentos rechaza una sesión anónima (HTTP $STATUS)"
fi

# Todos los usuarios deben autenticarse con su contraseña legítima.
while IFS='|' read -r username password expected_collection; do
  jar="$TMP_DIR/${username}.jar"
  response="$TMP_DIR/${username}.json"
  STATUS="$(http_status "$response" -c "$jar" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg u "$username" --arg p "$password" '{username:$u,password:$p}')" \
    "$BASE_URL/api/login.php")" || STATUS=000
  if [[ "$STATUS" == 200 ]] && json_true --arg username "$username" '.ok == true and .user.username == $username' "$response"; then
    pass "Login legítimo de ${username}"
    STATUS="$(http_status "$TMP_DIR/${username}-collections.json" -b "$jar" "$BASE_URL/api/collections.php")" || STATUS=000
    if [[ "$STATUS" == 200 ]] && json_true --arg c "$expected_collection" '.ok == true and (.collections | length == 1) and .collections[0] == $c' "$TMP_DIR/${username}-collections.json"; then
      pass "${username} solo recibe su colección autorizada (${expected_collection})"
    else
      fail "Permisos de colecciones de ${username} (HTTP $STATUS)"
    fi
  else
    fail "Login legítimo de ${username} (HTTP $STATUS)"
  fi
done <<'USERS'
ana|AnaDemo2026!|pedidos_ana
bruno|BrunoDemo2026!|inventario_bruno
carla|CarlaDemo2026!|incidencias_carla
USERS

# Una contraseña incorrecta no debe funcionar.
STATUS="$(http_status "$TMP_DIR/wrong.json" -H 'Content-Type: application/json' \
  --data '{"username":"ana","password":"ESTA_NO_ES_LA_CLAVE"}' "$BASE_URL/api/login.php")" || STATUS=000
if [[ "$STATUS" == 401 ]] && json_true '.ok == false' "$TMP_DIR/wrong.json"; then
  pass 'Contraseña incorrecta rechazada (401)'
else
  fail "Contraseña incorrecta rechazada (HTTP $STATUS)"
fi

# Prueba principal: el objeto password.$ne debe llegar a la consulta MongoDB.
STATUS="$(http_status "$TMP_DIR/injection.json" -c "$TMP_DIR/injection.jar" \
  -H 'Content-Type: application/json' \
  --data '{"username":"ana","password":{"$ne":"NO_ES_LA_CONTRASENA_CORRECTA"}}' \
  "$BASE_URL/api/login.php")" || STATUS=000
if [[ "$STATUS" == 200 ]] && json_true '.ok == true and .user.username == "ana"' "$TMP_DIR/injection.json"; then
  pass 'Payload $ne autentica realmente como ana (no solo HTTP 200)'
else
  fail "Payload $ne autentica como ana (HTTP $STATUS); revisa versión y consulta MongoDB"
fi

STATUS="$(http_status "$TMP_DIR/injection-collections.json" -b "$TMP_DIR/injection.jar" "$BASE_URL/api/collections.php")" || STATUS=000
if [[ "$STATUS" == 200 ]] && json_true '.ok == true and (.collections | length == 1) and (.collections[0] == "pedidos_ana")' "$TMP_DIR/injection-collections.json"; then
  pass 'La sesión obtenida por inyección solo ve pedidos_ana'
else
  fail "Colecciones tras inyección (HTTP $STATUS)"
fi

STATUS="$(http_status "$TMP_DIR/injection-documents.json" -b "$TMP_DIR/injection.jar" "$BASE_URL/api/documents.php?collection=pedidos_ana")" || STATUS=000
if [[ "$STATUS" == 200 ]] && json_true '.ok == true and .collection == "pedidos_ana" and (.count > 0)' "$TMP_DIR/injection-documents.json"; then
  pass 'La sesión obtenida por inyección puede consultar documentos reales de pedidos_ana'
else
  fail "Consulta de pedidos_ana después de la inyección (HTTP $STATUS)"
fi

STATUS="$(http_status "$TMP_DIR/forbidden-documents.json" -b "$TMP_DIR/injection.jar" "$BASE_URL/api/documents.php?collection=inventario_bruno")" || STATUS=000
if [[ "$STATUS" == 403 ]] && json_true '.ok == false' "$TMP_DIR/forbidden-documents.json"; then
  pass 'Ana no puede consultar inventario_bruno alterando la petición (403)'
else
  fail "Acceso cruzado a inventario_bruno rechazado (HTTP $STATUS)"
fi

printf '\nResumen: %d correctas, %d fallidas.\n' "$PASS_COUNT" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; fi
exit 0
