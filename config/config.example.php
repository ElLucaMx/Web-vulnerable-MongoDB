<?php
/**
 * Ejemplo de configuración privada generada automáticamente por install.sh.
 * La configuración real está en /etc/nosql-injection-lab/config.php, fuera del DocumentRoot.
 */
return [
    // Cuenta técnica: solo permiso find sobre nosql_lab.web_users.
    'mongo_uri' => 'mongodb://USUARIO_TECNICO:CLAVE_ALEATORIA@127.0.0.1:27017/nosql_lab?authSource=nosql_lab',
    // Cuentas distintas con rol find sobre una única colección cada una.
    'mongo_user_uris' => [
        'ana' => 'mongodb://USUARIO_ANA:CLAVE_ALEATORIA@127.0.0.1:27017/nosql_lab?authSource=nosql_lab',
        'bruno' => 'mongodb://USUARIO_BRUNO:CLAVE_ALEATORIA@127.0.0.1:27017/nosql_lab?authSource=nosql_lab',
        'carla' => 'mongodb://USUARIO_CARLA:CLAVE_ALEATORIA@127.0.0.1:27017/nosql_lab?authSource=nosql_lab',
    ],
    'database' => 'nosql_lab',
    'max_documents' => 50,
];
