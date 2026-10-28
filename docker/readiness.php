<?php
require_once '/opt/mooship/environment.php';
try {
    if (!\Mooship\ready(\Mooship\settings())) {
        throw new RuntimeException('Database installation or version check failed.');
    }
    echo "ready\n";
} catch (Throwable $error) {
    http_response_code(503);
    echo "not ready\n";
    exit(1);
}
