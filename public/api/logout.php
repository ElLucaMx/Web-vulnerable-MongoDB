<?php
declare(strict_types=1);

require_once __DIR__ . '/_common.php';
api_method('POST');
api_start_session();
$_SESSION = [];
if (ini_get('session.use_cookies')) {
    $params = session_get_cookie_params();
    setcookie(session_name(), '', [
        'expires' => time() - 42000,
        'path' => $params['path'] ?: '/',
        'domain' => $params['domain'] ?? '',
        'secure' => (bool) $params['secure'],
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
}
session_destroy();
api_json(200, ['ok' => true, 'message' => 'Sesión cerrada.']);
