<?php
declare(strict_types=1);

require_once __DIR__ . '/_common.php';
api_method('GET');
$user = api_require_user();

$requested = $_GET['collection'] ?? '';
if (!is_string($requested) || $requested === '') {
    api_json(400, ['ok' => false, 'error' => 'Debe indicar la colección que desea consultar.']);
}

// La autorización se vuelve a comprobar en el servidor para cada petición.
if (!in_array($requested, $user['collections'], true)) {
    api_json(403, ['ok' => false, 'error' => 'No tiene permiso para consultar esa colección.']);
}

try {
    $config = api_config();
    $limit = max(1, min(100, (int) ($config['max_documents'] ?? 50)));
    $cursor = api_user_database((string) $user['username'])->selectCollection($requested)->find([], [
        'limit' => $limit,
        'sort' => ['_id' => 1],
        'maxTimeMS' => 3000,
    ]);

    $documents = [];
    foreach ($cursor as $document) {
        $native = $document instanceof MongoDB\Model\BSONDocument
            ? $document->getArrayCopy()
            : (array) $document;
        $documents[] = json_decode(
            MongoDB\BSON\toJSON(MongoDB\BSON\fromPHP($native)),
            true,
            512,
            JSON_THROW_ON_ERROR
        );
    }
    api_json(200, [
        'ok' => true,
        'collection' => $requested,
        'count' => count($documents),
        'documents' => $documents,
    ]);
} catch (Throwable $e) {
    error_log('NoSQL Lab: error al consultar documentos: ' . $e->getMessage());
    api_json(503, ['ok' => false, 'error' => 'No se pudo consultar la colección. Compruebe el acceso a MongoDB.']);
}
