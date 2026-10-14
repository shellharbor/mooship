# Mooship backup and restore

## Create a backup

```bash
sudo bash /opt/mooship/backup.sh --slug lms
sudo bash /opt/mooship/backup.sh --slug lms --archive /var/backups/mooship/lms-before-upgrade.tar.gz
```

`--create-backup` in `deploy-moodle.sh` runs the same backup procedure after installation and SSL acquisition. By default, the archive is stored at `/var/backups/mooship/<slug>_<timestamp>.tar.gz`. Existing archives are never overwritten; paths inside the project directory are prohibited.

The v1 format contains:

- `project/`: the complete project directory, including code, moodledata, `.env`, `config.php`, Compose, and nginx configuration;
- `database.dump`: a PostgreSQL custom dump or MySQL SQL dump;
- `certificates.tar`: the `/etc/letsencrypt` volume containing certificates, relative symlinks, and account data;
- `manifest.json`: slug, domain, database type, Moodle/PHP versions, native database mode, and SHA-256 hashes of the dump and certificates.

Previously running `php`, `cron`, `nginx`, and `certbot_renew` services are stopped during the snapshot. The database and Redis keep running. On success or failure, only those stopped services are restarted; an initially inactive project is not activated. This requires a short downtime window. External clients must not write to the database or files during the backup.

Free space is required for a temporary directory copy, dump, certificates, and final archive. Private temporary files are cleaned up on normal completion and errors; SIGKILL/power loss prevents cleanup. The archive is published only after writing completes, with mode `600`. Failure to resume services returns a nonzero exit code even if the archive already exists: check the site state.

The backup contains secrets and private SSL keys. Keep copies in secure storage: `--post-hook` can upload each new archive (for example with rclone to an encrypted remote), and `--keep N` limits local archives. Redis holds only sessions and is not backed up; users log in again after a restore. Shared nginxproxy recreates this site's entries from the template; shared proxy logs and manual changes are excluded.

Native databases require host clients: `pg_dump`/`pg_restore` or `mysqldump`/`mysql`. PostgreSQL uses the `postgres` system user; the MySQL dump is created by the application user. Clients must be compatible with the database server. Prepare the native server, its configuration, extensions, and network access on the destination host separately.

## Schedule backups

```bash
sudo bash /opt/mooship/schedule-backup.sh --slug lms --at 03:30 --keep 7 [--post-hook /usr/local/sbin/mooship-offsite]
sudo bash /opt/mooship/schedule-backup.sh --slug lms --status
sudo bash /opt/mooship/schedule-backup.sh --slug lms --disable
```

The schedule consists of `mooship-backup-<slug>.service` (type `oneshot`, running `backup.sh --slug <slug> --keep N` with low CPU and I/O priority) and `mooship-backup-<slug>.timer` (daily, up to 15 minutes of random delay, `Persistent=true` to catch up after downtime). Logs are in `journalctl -u mooship-backup-<slug>.service`; `doctor.sh` warns when the newest archive is older than 48 hours and fails when the last scheduled run failed. `remove.sh` removes the schedule with the project.

Retention (`--keep N`) only removes archives named `<slug>_YYYYMMDD_HHMMSS.tar.gz` in the archive's directory, keeping the newest N. It runs after the optional hook succeeds; a failed hook keeps every archive. Hooks run as root as `HOOK <archive> <slug>` and must be root-owned absolute paths that group and others cannot write.

## Restore a backup

```bash
sudo bash /opt/mooship/restore.sh --slug lms --archive /var/backups/mooship/lms-before-upgrade.tar.gz
# For native MySQL, add --db-root-password.
```

Use your own trusted v1 archive. Path and checksum validation does not make arbitrary Compose files or source code safe to run as root. Old project-file zip archives are incomplete backups and are rejected.

The target slug must match the archive and be free: the previous project's directory, network, volumes, containers, and site configs must be absent. The native database and its user must also be absent. The script requires entering the slug, does not replace existing data, and preserves the original domain and ports. Configure DNS and resolve port conflicts before restoring.

Before applying changes, the script validates the manifest, checksums, required files, archive entry types, relative paths, and symlinks. It then creates resources, restores the database and certificates, applies permissions, and starts the application. Native PostgreSQL tables are owned by the application user. The site is connected to the shared proxy after successful startup.

If restore fails after creating the directory, it and created resources are retained for diagnostics; there is no automatic rollback. Investigate the error first. Before retrying, explicitly remove only this failed project or fix the cause manually. The original archive is retained.

Check after restoring:

```bash
cd /var/www/lms
docker compose ps -a
docker compose exec -T nginx nginx -t
docker compose logs --tail 50 php cron
```

Then verify administrator login, access to an existing course, and downloading its file using the saved site protocol. `SITE_SCHEME=http` restores a working HTTP site without requiring a certificate; older archives without this key retain HTTPS behavior. For a native database, check connectivity from the PHP container. Restoring an HTTPS backup with an expired certificate requires renewal.

## Safe removal

`remove.sh` retains all backup archives. It automatically removes a native database only when `.mooship-native-database` matches the current type, name, user, and port. The marker is written after successful database and role creation; restore resets the old marker and creates a new one. A failed CREATE does not authorize deleting another project's database.

Old projects without a marker retain their native database and role when the directory is removed. Verify ownership and remove them separately by hand. Partially created native resources after a CREATE failure also require separate verification. Make a backup before removing a project.

## Repository checks

`tests/test_scripts.py` checks data preservation, service stop/resume behavior, private permissions, critical failures, four Compose variants, and HTTP/HTTPS/legacy archive restoration, including preservation of custom HTTP routes. `tests/test_state.py` checks archives and rejection of dangerous paths. Opt-in `tests/test_database_roundtrip.py` restores synthetic data on real PostgreSQL 17 and MySQL 8.4 through the production function, including native branches and PostgreSQL table ownership. Full deployment, DNS, and actual Let's Encrypt issuance are checked separately on the target server.
