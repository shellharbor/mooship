<?php
// Shared environment contract for the immutable Moodle runtime.
namespace Mooship;

function value(string $name, string $default = ''): string {
    $value = getenv($name);
    return $value === false || $value === '' ? $default : $value;
}

function secret(string $name, bool $required = true): string {
    $value = value($name);
    $file = value($name . '_FILE');
    if ($value !== '' && $file !== '') {
        throw new \InvalidArgumentException("Set either {$name} or {$name}_FILE, not both.");
    }
    if ($file !== '') {
        if ($file[0] !== '/' || !is_file($file) || !is_readable($file) || filesize($file) > 65536) {
            throw new \InvalidArgumentException("Cannot read the secret file for {$name}.");
        }
        $contents = @file_get_contents($file);
        if ($contents === false) {
            throw new \InvalidArgumentException("Cannot read the secret file for {$name}.");
        }
        $value = rtrim($contents, "\r\n");
    }
    if ($required && $value === '') {
        throw new \InvalidArgumentException("A secret is required for {$name}.");
    }
    return $value;
}

function flag(string $name): bool {
    $value = value($name, 'false');
    $result = filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
    if ($result === null) {
        throw new \InvalidArgumentException("Invalid boolean setting: {$name}.");
    }
    return $result;
}

function settings(): array {
    $type = value('MOODLE_DB_TYPE', 'pgsql');
    if (!in_array($type, ['pgsql', 'mysqli'], true)) {
        throw new \InvalidArgumentException('MOODLE_DB_TYPE must be pgsql or mysqli.');
    }
    $host = value('MOODLE_DB_HOST', 'db');
    $name = value('MOODLE_DB_NAME', 'moodle');
    $user = value('MOODLE_DB_USER', 'moodle');
    if (!preg_match('/^[a-zA-Z0-9_.:-]+$/D', $host)) {
        throw new \InvalidArgumentException('Invalid MOODLE_DB_HOST.');
    }
    foreach ([$name, $user] as $identifier) {
        if (!preg_match('/^[a-zA-Z][a-zA-Z0-9_]{0,62}$/D', $identifier)) {
            throw new \InvalidArgumentException('Invalid database name or user.');
        }
    }
    $port = value('MOODLE_DB_PORT', $type === 'pgsql' ? '5432' : '3306');
    if (!ctype_digit($port) || (int)$port < 1 || (int)$port > 65535) {
        throw new \InvalidArgumentException('Invalid MOODLE_DB_PORT.');
    }
    $prefix = value('MOODLE_DB_PREFIX', 'mdl_');
    if (!preg_match('/^[a-z][a-z0-9_]{0,9}$/D', $prefix)) {
        throw new \InvalidArgumentException('MOODLE_DB_PREFIX must contain 1-10 safe characters.');
    }
    $wwwroot = rtrim(value('MOODLE_WWWROOT'), '/');
    $url = parse_url($wwwroot);
    if (!filter_var($wwwroot, FILTER_VALIDATE_URL) || !is_array($url) ||
        !in_array($url['scheme'] ?? '', ['http', 'https'], true) ||
        isset($url['user']) || isset($url['pass']) || isset($url['query']) || isset($url['fragment']) ||
        !empty($url['path'])) {
        throw new \InvalidArgumentException('MOODLE_WWWROOT must be an HTTP(S) origin without a subdirectory.');
    }
    return [
        'type' => $type, 'host' => $host, 'name' => $name, 'user' => $user,
        'password' => secret('MOODLE_DB_PASSWORD'), 'port' => (int)$port,
        'prefix' => $prefix, 'wwwroot' => $wwwroot,
        'reverseproxy' => flag('MOODLE_REVERSE_PROXY'), 'sslproxy' => flag('MOODLE_SSL_PROXY'),
    ];
}

function connection(array $configuration): \PDO {
    if ($configuration['type'] === 'pgsql') {
        $dsn = "pgsql:host={$configuration['host']};port={$configuration['port']};" .
            "dbname={$configuration['name']};connect_timeout=5";
    } else {
        $dsn = "mysql:host={$configuration['host']};port={$configuration['port']};" .
            "dbname={$configuration['name']};charset=utf8mb4";
    }
    return new \PDO($dsn, $configuration['user'], $configuration['password'], [
        \PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION, \PDO::ATTR_TIMEOUT => 5,
    ]);
}

function validate(array $configuration): void {
    $workers = value('PHP_FPM_MAX_CHILDREN', '4');
    if (!ctype_digit($workers) || (int)$workers < 2 || (int)$workers > 256) {
        throw new \InvalidArgumentException('PHP_FPM_MAX_CHILDREN must be between 2 and 256.');
    }
    if (!is_writable('/var/moodledata') || !is_writable('/tmp')) {
        throw new \RuntimeException('The Moodle data directory and /tmp must be writable by UID 1000.');
    }
    if (!is_file('/opt/moodle/version.php')) {
        throw new \RuntimeException('The image does not contain Moodle source.');
    }
}

function ready(array $configuration): bool {
    validate($configuration);
    $metadata = json_decode(file_get_contents('/opt/mooship/version.json'), true, 512, JSON_THROW_ON_ERROR);
    $database = connection($configuration);
    $query = $database->prepare("SELECT value FROM {$configuration['prefix']}config WHERE name = :name");
    $query->execute(['name' => 'version']);
    $version = $query->fetchColumn();
    return $version !== false && (float)$version === (float)$metadata['version'];
}
