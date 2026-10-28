<?php
// This configuration contains no credentials; secrets are supplied at runtime.
require_once '/opt/mooship/environment.php';
$configuration = \Mooship\settings();
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype = $configuration['type'];
$CFG->dblibrary = 'native';
$CFG->dbhost = $configuration['host'];
$CFG->dbname = $configuration['name'];
$CFG->dbuser = $configuration['user'];
$CFG->dbpass = $configuration['password'];
$CFG->prefix = $configuration['prefix'];
$CFG->dboptions = ['dbpersist' => false, 'dbsocket' => false, 'dbport' => $configuration['port']];
if ($configuration['type'] === 'mysqli') {
    $CFG->dboptions['dbcollation'] = 'utf8mb4_unicode_ci';
}
$CFG->wwwroot = $configuration['wwwroot'];
$CFG->dataroot = '/var/moodledata';
$CFG->directorypermissions = 02770;
$CFG->admin = 'admin';
$CFG->reverseproxy = $configuration['reverseproxy'];
$CFG->sslproxy = $configuration['sslproxy'];
$CFG->routerconfigured = true;
$CFG->xsendfile = 'X-Accel-Redirect';
$CFG->xsendfilealiases = ['/dataroot/' => $CFG->dataroot];
$CFG->disableupdateautodeploy = true;
if (\Mooship\value('MOODLE_REDIS_HOST') !== '') {
    $CFG->session_handler_class = '\core\session\redis';
    $CFG->session_redis_host = \Mooship\value('MOODLE_REDIS_HOST');
    $CFG->session_redis_port = (int)\Mooship\value('MOODLE_REDIS_PORT', '6379');
    $CFG->session_redis_auth = \Mooship\secret('MOODLE_REDIS_PASSWORD');
    $CFG->session_redis_prefix = 'mooship_session_';
}
require_once __DIR__ . '/lib/setup.php';
