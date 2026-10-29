<?php
declare(strict_types=1);

require_once __DIR__ . '/_common.php';
api_method('GET');
$user = api_require_user();

$collections = $user['collections'];
if (!is_array($collections)) {
    error_log('NoSQL Lab: la lista de colecciones de sesión no es válida.');
    api_json(500, ['ok' => false, 'error' => 'Los permisos de la sesión no son válidos.']);
}
api_json(200, [
    'ok' => true,
    'user' => [
        'username' => $user['username'],
        'displayName' => $user['displayName'] ?? $user['username'],
    ],
    'collections' => array_values($collections),
]);
