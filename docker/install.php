<?php
// Pass installer options in PHP memory so passwords never enter process arguments.
require_once '/opt/mooship/environment.php';
try {
    $configuration = \Mooship\settings();
    \Mooship\validate($configuration);
    if (!\Mooship\flag('MOODLE_AGREE_LICENSE')) {
        throw new InvalidArgumentException('Set MOODLE_AGREE_LICENSE=true to install Moodle.');
    }
    $email = \Mooship\value('MOODLE_ADMIN_EMAIL');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
        throw new InvalidArgumentException('A valid MOODLE_ADMIN_EMAIL is required.');
    }
    $password = \Mooship\secret('MOODLE_ADMIN_PASSWORD');
    $mooshipInstallConnection = \Mooship\connection($configuration);
    if ($configuration['type'] === 'pgsql') {
        $locked = $mooshipInstallConnection->query(
            "SELECT pg_try_advisory_lock(hashtext(current_database()), hashtext('mooship-install'))"
        )->fetchColumn();
        $tables = $mooshipInstallConnection->query(
            'SELECT tablename FROM pg_tables WHERE schemaname = current_schema()'
        )->fetchAll();
    } else {
        $lock = $mooshipInstallConnection->prepare('SELECT GET_LOCK(:name, 0)');
        $lock->execute(['name' => 'mooship-' . substr(hash('sha256', $configuration['name']), 0, 40)]);
        $locked = $lock->fetchColumn();
        $tables = $mooshipInstallConnection->query('SHOW TABLES')->fetchAll();
    }
    if (!$locked || $tables) {
        throw new RuntimeException('Installation requires an empty database and an exclusive installer lock.');
    }
    $argv = [
        '/opt/moodle/admin/cli/install_database.php', '--agree-license',
        '--adminuser=' . \Mooship\value('MOODLE_ADMIN_USER', 'admin'), '--adminpass=' . $password,
        '--adminemail=' . $email, '--fullname=' . \Mooship\value('MOODLE_SITE_FULLNAME', 'Mooship Moodle'),
        '--shortname=' . \Mooship\value('MOODLE_SITE_SHORTNAME', 'Mooship'), '--lang=en',
    ];
    $argc = count($argv);
    $_SERVER['argv'] = $argv;
    $_SERVER['argc'] = $argc;
} catch (Throwable $error) {
    $message = $error instanceof PDOException ? 'Cannot connect to the installation database.' : $error->getMessage();
    fwrite(STDERR, '[ERROR] ' . $message . PHP_EOL);
    exit(1);
}
require '/opt/moodle/admin/cli/install_database.php';
