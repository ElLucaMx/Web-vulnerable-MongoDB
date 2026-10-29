<?php
declare(strict_types=1);

require_once __DIR__ . '/_common.php';
api_method('POST');
api_start_session();

$raw = file_get_contents('php://input');
$data = json_decode($raw === false ? '' : $raw, true);

if (!is_array($data) || !isset($data['username']) || !isset($data['password'])) {
    api_json(400, ['ok' => false, 'error' => 'Debe indicar usuario y contraseña.']);
}

try {
    $users = api_database()->selectCollection('web_users');

    // Inyección NoSQL abierta: permite arrays/objetos directamente ($ne, etc.)
    $filter = [
        'username' => $data['username'],
        'password' => $data['password'],
    ];

    $user = $users->findOne($filter, [
        'projection' => ['username' => 1, 'displayName' => 1, 'collections' => 1],
        'maxTimeMS' => 3000,
    ]);

    if ($user === null) {
        api_json(401, ['ok' => false, 'error' => 'Usuario o contraseña incorrectos.']);
    }

    $allowedCollections = isset($user->collections) ? array_values($user->collections->getArrayCopy()) : [];

    session_regenerate_id(true);
    $_SESSION['user'] = [
        'username' => (string) ($user->username ?? 'usuario'),
        'displayName' => isset($user->displayName) ? (string) $user->displayName : (string) ($user->username ?? 'usuario'),
        'collections' => $allowedCollections,
    ];

    api_json(200, [
        'ok' => true,
        'user' => [
            'username' => $_SESSION['user']['username'],
             'displayName' => $_SESSION['user']['displayName'],
        ],
        'message' => 'Autenticación correcta.',
    ]);
} catch (Throwable $e) {
    api_json(503, ['ok' => false, 'error' => 'Error en la base de datos: ' . $e->getMessage()]);
}
