<?php
declare(strict_types=1);

$configPath = getenv('NOSQL_LAB_CONFIG') ?: '/etc/nosql-injection-lab/config.php';
if (!is_file($configPath) || !is_readable($configPath)) {
    fwrite(STDERR, "ERROR: no se puede leer la configuración privada en {$configPath}.\n");
    exit(1);
}
$config = require $configPath;
$autoload = dirname(__DIR__) . '/vendor/autoload.php';
if (!is_file($autoload)) {
    fwrite(STDERR, "ERROR: falta vendor/autoload.php.\n");
    exit(1);
}
require $autoload;

$owned = [
    'ana' => 'pedidos_ana',
    'bruno' => 'inventario_bruno',
    'carla' => 'incidencias_carla',
];
$allCollections = array_values($owned);
$failed = false;

function failCheck(string $message): void
{
    global $failed;
    $failed = true;
    fwrite(STDERR, "[FALLO] {$message}\n");
}

function passCheck(string $message): void
{
    echo "[OK] {$message}\n";
}

function queryFirst(MongoDB\Client $client, string $collection): void
{
    $client->selectCollection('nosql_lab', $collection)->findOne([], ['maxTimeMS' => 2500]);
}

function isPermissionDenied(Throwable $e): bool
{
    return (int) $e->getCode() === 13
        || preg_match('/not authorized|unauthorized|not permitted/i', $e->getMessage()) === 1;
}

try {
    foreach ($owned as $username => $ownCollection) {
        $uri = $config['mongo_user_uris'][$username] ?? null;
        if (!is_string($uri) || $uri === '') {
            failCheck("No hay URI privada configurada para {$username}.");
            continue;
        }
        $client = new MongoDB\Client($uri);
        try {
            queryFirst($client, $ownCollection);
            passCheck("La cuenta MongoDB de {$username} puede consultar {$ownCollection}.");
        } catch (Throwable $e) {
            failCheck("La cuenta MongoDB de {$username} no puede consultar su propia colección {$ownCollection}: {$e->getMessage()}");
            continue;
        }

        foreach ($allCollections as $otherCollection) {
            if ($otherCollection === $ownCollection) {
                continue;
            }
            try {
                queryFirst($client, $otherCollection);
                failCheck("La cuenta MongoDB de {$username} también puede consultar {$otherCollection}; el rol es demasiado amplio.");
            } catch (Throwable $e) {
                if (isPermissionDenied($e)) {
                    passCheck("La cuenta MongoDB de {$username} no puede consultar {$otherCollection} (denegado por MongoDB).");
                } else {
                    failCheck("No se pudo confirmar una denegación de permisos para {$username} sobre {$otherCollection}: {$e->getMessage()}");
                }
            }
        }
    }

    // La cuenta usada únicamente para el login no debe acceder a colecciones de datos.
    $serviceUri = $config['mongo_uri'] ?? null;
    if (!is_string($serviceUri) || $serviceUri === '') {
        failCheck('No hay URI de conexión técnica configurada.');
    } else {
        $serviceClient = new MongoDB\Client($serviceUri);
        try {
            queryFirst($serviceClient, 'pedidos_ana');
            failCheck('La cuenta técnica de login puede leer pedidos_ana; debe limitarse a web_users.');
        } catch (Throwable $e) {
            if (isPermissionDenied($e)) {
                passCheck('La cuenta técnica de login no puede leer colecciones de datos.');
            } else {
                failCheck('No se pudo confirmar que la cuenta técnica carece de acceso a pedidos_ana: ' . $e->getMessage());
            }
        }
    }
} catch (Throwable $e) {
    failCheck('La comprobación de roles terminó con una excepción: ' . $e->getMessage());
}

if ($failed) {
    fwrite(STDERR, "\nERROR: al menos una comprobación de autorización MongoDB ha fallado.\n");
    exit(1);
}
echo "\nOK: MongoDB aplica permisos efectivos por colección.\n";
