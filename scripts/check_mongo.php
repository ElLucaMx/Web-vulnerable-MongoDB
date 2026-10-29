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

try {
    $client = new MongoDB\Client($config['mongo_uri']);
    $database = $client->selectDatabase($config['database'] ?? 'nosql_lab');
    $user = $database->selectCollection('web_users')->findOne(
        ['username' => 'ana'],
        ['projection' => ['username' => 1], 'maxTimeMS' => 2500]
    );
    if ($user === null || ($user->username ?? null) !== 'ana') {
        throw new RuntimeException('La consulta de comprobación no encontró al usuario ana.');
    }
    echo "OK: PHP puede conectarse a MongoDB y consultar web_users.\n";
} catch (Throwable $e) {
    fwrite(STDERR, 'ERROR: comprobación MongoDB fallida: ' . $e->getMessage() . "\n");
    exit(1);
}
