/*
 * Inicialización idempotente de nosql_lab.
 * El instalador pasa variables aleatorias por mongosh --eval.
 * No elimina bases de datos, colecciones ni documentos ajenos a las semillas.
 */
const lab = db.getSiblingDB("nosql_lab");

if (typeof appDbUser !== "string" || typeof appDbPassword !== "string" || typeof appRoleName !== "string"
    || typeof anaDbUser !== "string" || typeof anaDbPassword !== "string" || typeof anaRoleName !== "string"
    || typeof brunoDbUser !== "string" || typeof brunoDbPassword !== "string" || typeof brunoRoleName !== "string"
    || typeof carlaDbUser !== "string" || typeof carlaDbPassword !== "string" || typeof carlaRoleName !== "string") {
  throw new Error("Faltan variables de usuario o rol; ejecuta install.sh o reset_lab_data.sh.");
}

function ensureRole(roleName, privileges) {
  const oldRole = lab.getRole(roleName, { showPrivileges: true });
  if (oldRole) {
    lab.updateRole(roleName, { privileges, roles: [] });
  } else {
    lab.createRole({ role: roleName, privileges, roles: [] });
  }
}

function ensureUser(userName, password, roleName) {
  const oldUser = lab.getUser(userName);
  const spec = { pwd: password, roles: [{ role: roleName, db: "nosql_lab" }] };
  if (oldUser) {
    lab.updateUser(userName, spec);
  } else {
    lab.createUser({ user: userName, ...spec });
  }
}

function findPrivilege(collectionName) {
  return {
    resource: { db: "nosql_lab", collection: collectionName },
    actions: ["find"]
  };
}

// Cuenta técnica: únicamente puede consultar web_users para ejecutar el login vulnerable.
ensureRole(appRoleName, [findPrivilege("web_users")]);
ensureUser(appDbUser, appDbPassword, appRoleName);

// Cada identidad de la aplicación se conecta después con una cuenta MongoDB propia.
// Estos roles son el control efectivo a nivel de base de datos; no dependen solo de PHP.
const dbUsers = [
  { username: anaDbUser, password: anaDbPassword, role: anaRoleName, collection: "pedidos_ana" },
  { username: brunoDbUser, password: brunoDbPassword, role: brunoRoleName, collection: "inventario_bruno" },
  { username: carlaDbUser, password: carlaDbPassword, role: carlaRoleName, collection: "incidencias_carla" }
];
dbUsers.forEach((user) => {
  ensureRole(user.role, [findPrivilege(user.collection)]);
  ensureUser(user.username, user.password, user.role);
});

// Contraseñas en claro solo para que la práctica demuestre el filtro vulnerable con $ne.
// No utilizar usuarios ni contraseñas reales en este laboratorio.
const userSeeds = [
  { username: "ana", password: "AnaDemo2026!", displayName: "Ana", collections: ["pedidos_ana"] },
  { username: "bruno", password: "BrunoDemo2026!", displayName: "Bruno", collections: ["inventario_bruno"] },
  { username: "carla", password: "CarlaDemo2026!", displayName: "Carla", collections: ["incidencias_carla"] }
];
userSeeds.forEach((user) => {
  lab.web_users.replaceOne({ username: user.username }, user, { upsert: true });
});

const orderSeeds = [
  { _id: "pedido-1001", cliente: "Cliente ficticio 01", producto: "Teclado mecánico", cantidad: 2, estado: "Preparando", fecha: "2026-10-21" },
  { _id: "pedido-1002", cliente: "Cliente ficticio 02", producto: "Ratón inalámbrico", cantidad: 1, estado: "Enviado", fecha: "2026-10-23" },
  { _id: "pedido-1003", cliente: "Cliente ficticio 03", producto: "Monitor 27 pulgadas", cantidad: 1, estado: "Pendiente", fecha: "2026-10-26" }
];
orderSeeds.forEach((doc) => lab.pedidos_ana.replaceOne({ _id: doc._id }, doc, { upsert: true }));

const inventorySeeds = [
  { _id: "articulo-2001", articulo: "Cable USB-C", existencias: 42, precio: 8.95, categoria: "Accesorios" },
  { _id: "articulo-2002", articulo: "SSD 1 TB", existencias: 13, precio: 74.5, categoria: "Almacenamiento" },
  { _id: "articulo-2003", articulo: "Hub USB", existencias: 0, precio: 19.99, categoria: "Accesorios" }
];
inventorySeeds.forEach((doc) => lab.inventario_bruno.replaceOne({ _id: doc._id }, doc, { upsert: true }));

const incidentSeeds = [
  { _id: "incidencia-3001", titulo: "Impresora sin conexión", descripcion: "La impresora de pruebas no responde en la red local.", prioridad: "Media", estado: "Abierta" },
  { _id: "incidencia-3002", titulo: "Actualización pendiente", descripcion: "Queda pendiente aplicar una actualización en el equipo ficticio.", prioridad: "Baja", estado: "En curso" },
  { _id: "incidencia-3003", titulo: "Disco con poco espacio", descripcion: "El volumen de laboratorio supera el 85 % de ocupación.", prioridad: "Alta", estado: "Abierta" }
];
incidentSeeds.forEach((doc) => lab.incidencias_carla.replaceOne({ _id: doc._id }, doc, { upsert: true }));

print("OK: cuentas, roles MongoDB por colección y semillas de nosql_lab preparados.");
