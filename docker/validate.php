<?php
require_once '/opt/mooship/environment.php';
try {
    \Mooship\validate(\Mooship\settings());
} catch (Throwable $error) {
    fwrite(STDERR, '[ERROR] ' . $error->getMessage() . PHP_EOL);
    exit(1);
}
