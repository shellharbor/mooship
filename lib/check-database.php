<?php
// Standalone patched PHP 8.2+ probe: no Moodle bootstrap, schema changes, or credential output.
$mode = getenv('MOOSHIP_DB_CHECK') ?: 'connect';
try {
    $host = getenv('MOOSHIP_DB_HOST');
    $port = (int)getenv('MOOSHIP_DB_PORT');
    if ($mode === 'tcp') {
        $address = strpos($host, ':') === false ? $host : "[{$host}]";
        $socket = @stream_socket_client("tcp://{$address}:{$port}", $code, $message, 5);
        if (!$socket) {
            throw new RuntimeException('The native database is unreachable from the PHP container.');
        }
        fclose($socket);
        exit(0);
    }
    $engine = getenv('MOOSHIP_DB_TYPE') === 'postgres' ? 'pgsql' : 'mysql';
    $name = getenv('MOOSHIP_DB_NAME');
    $dsn = "{$engine}:host={$host};port={$port};dbname={$name}";
    $dsn .= $engine === 'pgsql' ? ';connect_timeout=5' : ';charset=utf8mb4';
    $db = new PDO($dsn, getenv('MOOSHIP_DB_USER'), getenv('MOOSHIP_DB_PASSWORD'), [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5,
    ]);
    $db->query('SELECT 1');
    if ($mode === 'installed') {
        $tables = $engine === 'pgsql'
            ? $db->query('SELECT tablename FROM pg_tables WHERE schemaname = current_schema()')->fetchAll(PDO::FETCH_COLUMN)
            : $db->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN);
        if (!$tables) {
            exit(3); // An empty, reachable database may be initialized.
        }
        if (!in_array('mdl_config', $tables, true) ||
            !$db->query("SELECT value FROM mdl_config WHERE name = 'version'")->fetchColumn()) {
            fwrite(STDERR, "[ERROR] The database is partially installed; investigate before retrying.\n");
            exit(4);
        }
    } elseif ($mode !== 'connect') {
        throw new RuntimeException('Unknown database check.');
    }
} catch (Throwable $error) {
    // Driver exceptions can contain connection details. Report a fixed actionable message.
    fwrite(STDERR, "[ERROR] Database probe failed from PHP. Check the host, port, credentials, "
        . "listen_addresses/pg_hba.conf (PostgreSQL), bind-address/grants (MySQL), and firewall.\n");
    exit(1);
}
