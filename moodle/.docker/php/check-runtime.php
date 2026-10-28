<?php
// Shared build/startup guard. The actual PHP runtime cannot be overridden by environment settings.
function mooship_check_php_version(string $actual, array $policy): void {
    if (!preg_match('/^[0-9]+\.[0-9]+\.[0-9]+$/D', $actual)) {
        throw new RuntimeException('A verified stable PHP patch version is required.');
    }
    $branch = implode('.', array_slice(explode('.', $actual), 0, 2));
    $minimum = $policy['minimum_php'][$branch] ?? null;
    if ($minimum === null || version_compare($actual, $minimum, '<')) {
        throw new RuntimeException('PHP ' . $actual . ' is prohibited. Required: ' . implode(', ', $policy['minimum_php']));
    }
}

function mooship_check_runtime(?string $moodle = null): void {
    $policy = json_decode(file_get_contents(__DIR__ . '/runtime-policy.json'), true, 512, JSON_THROW_ON_ERROR);
    mooship_check_php_version(PHP_VERSION, $policy);
    if ($moodle === null) {
        return;
    }
    $php = implode('.', array_slice(explode('.', PHP_VERSION), 0, 2));
    mooship_check_moodle_version($moodle, $php, $policy);
}

function mooship_check_moodle_version(string $moodle, string $php, array $policy): void {
    $normalized = substr_count($moodle, '.') === 1 ? $moodle . '.0' : $moodle;
    if (!preg_match('/^[0-9]+\.[0-9]+(?:\.[0-9]+)?$/D', $moodle)
        || version_compare($normalized, $policy['minimum_moodle'], '<')) {
        throw new RuntimeException('Moodle 4.3 or newer is required.');
    }
    $branch = implode('.', array_slice(explode('.', $moodle), 0, 2));
    if (!in_array($php, $policy['moodle_php'][$branch] ?? [], true)) {
        throw new RuntimeException('Unverified or incompatible Moodle/PHP pair: ' . $moodle . ' / ' . $php);
    }
}

function mooship_moodle_release(string $directory): string {
    $source = is_file($directory . '/public/version.php') ? $directory . '/public/version.php' : $directory . '/version.php';
    if (!is_file($source)) {
        throw new RuntimeException('Cannot verify installed Moodle: version.php is missing.');
    }
    $pattern = <<<'REGEX'
~^\s*\$release\s*=\s*(['"])([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?:[ \t][^'"\r\n]*)?\1\s*;~m
REGEX;
    if (preg_match_all($pattern, file_get_contents($source), $matches) !== 1) {
        throw new RuntimeException('Cannot verify a stable Moodle release from version.php.');
    }
    return $matches[2][0];
}

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath($_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    try {
        $moodle = ($argv[1] ?? null) === '--source' ? mooship_moodle_release($argv[2] ?? '/var/www/html') : ($argv[1] ?? null);
        mooship_check_runtime($moodle);
    } catch (Throwable $error) {
        fwrite(STDERR, '[ERROR] ' . $error->getMessage() . PHP_EOL);
        exit(1);
    }
}
