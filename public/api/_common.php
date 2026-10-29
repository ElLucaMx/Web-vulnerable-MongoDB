<?php
declare(strict_types=1);

use MongoDB\Client;

const NOSQL_LAB_DEFAULT_CONFIG = '/etc/nosql-injection-lab/config.php';

function api_json(int $status, array $payload): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, max-age=0');
    header('X-Content-Type-Options: nosniff');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function api_method(string $expected): void
{
    $actual = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
    if ($actual !== strtoupper($expected)) {
        header('Allow: ' . strtoupper($expected));
        api_json(405, ['ok' => false, 'error' => 'Método HTTP no permitido.']);
    }
}

function api_start_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    session_name('NOSQLLABSESSID');
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'domain' => '',
        'secure' => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'),
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
    session_start();
}

function api_config(): array
{
    $path = getenv('NOSQL_LAB_CONFIG') ?: NOSQL_LAB_DEFAULT_CONFIG;
    if (!is_file($path) || !is_readable($path)) {
        error_log('NoSQL Lab: falta la configuración privada: ' . $path);
        api_json(500, ['ok' => false, 'error' => 'La aplicación no está configurada. Revise la instalación.']);
    }
    $config = require $path;
    if (!is_array($config) || empty($config['mongo_uri']) || empty($config['database'])) {
        error_log('NoSQL Lab: configuración incompleta.');
        api_json(500, ['ok' => false, 'error' => 'La configuración de la aplicación no es válida.']);
    }
    return $config;
}

function api_database(): \MongoDB\Database
{
    static $database = null;
    if ($database instanceof \MongoDB\Database) {
        return $database;
    }

    $root = dirname(__DIR__, 2);
    $autoload = $root . '/vendor/autoload.php';
    if (!is_file($autoload)) {
        error_log('NoSQL Lab: no se encuentra vendor/autoload.php.');
        api_json(500, ['ok' => false, 'error' => 'Faltan dependencias de PHP. Ejecute el instalador.']);
    }
    require_once $autoload;
    $config = api_config();

    try {
        $client = new Client($config['mongo_uri'], [], [
            'typeMap' => [
                'root' => 'MongoDB\\Model\\BSONDocument',
                'document' => 'MongoDB\\Model\\BSONDocument',
                'array' => 'MongoDB\\Model\\BSONArray',
            ],
        ]);
        $database = $client->selectDatabase($config['database']);
        // Fuerza una operación de red antes de devolver la conexión.
        $database->selectCollection('web_users')->findOne(
            ['username' => '__nosql_lab_connection_check__'],
            ['projection' => ['_id' => 1], 'maxTimeMS' => 2500]
        );
        return $database;
    } catch (Throwable $e) {
        error_log('NoSQL Lab: error al conectar con MongoDB: ' . $e->getMessage());
        api_json(503, ['ok' => false, 'error' => 'No se puede conectar con MongoDB. Revise el servicio y la configuración.']);
    }
}

/**
 * Conecta a MongoDB como la cuenta individual del usuario web autenticado.
 * La cuenta técnica de login solo tiene find sobre web_users; las lecturas de
 * datos quedan limitadas además por los roles MongoDB específicos de cada cuenta.
 */
function api_user_database(string $username): \MongoDB\Database
{
    static $databases = [];
    if (isset($databases[$username]) && $databases[$username] instanceof \MongoDB\Database) {
        return $databases[$username];
    }

    $root = dirname(__DIR__, 2);
    $autoload = $root . '/vendor/autoload.php';
    if (!is_file($autoload)) {
        error_log('NoSQL Lab: no se encuentra vendor/autoload.php para la conexión individual.');
        api_json(500, ['ok' => false, 'error' => 'Faltan dependencias de PHP. Ejecute el instalador.']);
    }
    require_once $autoload;
    $config = api_config();
    $uri = $config['mongo_user_uris'][$username] ?? null;
    if (!is_string($uri) || $uri === '') {
        error_log('NoSQL Lab: no hay una conexión MongoDB individual configurada para ' . $username);
        api_json(403, ['ok' => false, 'error' => 'No existe una cuenta de base de datos para este usuario.']);
    }

    try {
        $client = new Client($uri, [], [
            'typeMap' => [
                'root' => 'MongoDB\\Model\\BSONDocument',
                'document' => 'MongoDB\\Model\\BSONDocument',
                'array' => 'MongoDB\\Model\\BSONArray',
            ],
        ]);
        $databases[$username] = $client->selectDatabase($config['database']);
        return $databases[$username];
    } catch (Throwable $e) {
        error_log('NoSQL Lab: error al crear la conexión MongoDB individual: ' . $e->getMessage());
        api_json(503, ['ok' => false, 'error' => 'No se pudo abrir la conexión de base de datos del usuario.']);
    }
}

function api_require_user(): array
{
    api_start_session();
    if (!isset($_SESSION['user']) || !is_array($_SESSION['user']) || !isset($_SESSION['user']['username'], $_SESSION['user']['collections'])) {
        api_json(401, ['ok' => false, 'error' => 'La sesión no está autenticada.']);
    }
    return $_SESSION['user'];
}
