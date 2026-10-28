# Examples for deploy-moodle.sh

Ready-to-use `deploy-moodle.sh` scenarios and samples of the files it generates. See [../README.md](../README.md) for the full documentation.

## Usage

1. The examples are in the `examples/` directory of the `mooship` folder, copied in full to the **server**, for example under `/opt/mooship/`.
2. Replace the domain, slug, email, and all `ChangeMe_*` passwords in the chosen file. Each file's header explains what to change.
3. Run the example from any directory:
   ```bash
   bash /opt/mooship/examples/02-mysql-explicit-slug.sh
   ```
   - The example script locates `deploy-moodle.sh` one directory above `examples/` and invokes it through `sudo`.
   - If the example is stored separately, specify the deployment folder: `DEPLOY_DIR=/opt/mooship bash 02-mysql-explicit-slug.sh`.

Before running, note that existing directories, Docker resources, and native databases/users are rejected. Their data is preserved.

For reinstallation, create a full backup first, then confirm `remove.sh` separately. Backup archives are preserved.

## Scenarios

| File | Scenario | Key flags |
|---|---|---|
| [01-minimal-postgres.sh](01-minimal-postgres.sh) | Minimal invocation: a generated slug is added to the domain (wildcard DNS required) | `--domain` `--db-type postgres` `--ssl-email` |
| [02-mysql-explicit-slug.sh](02-mysql-explicit-slug.sh) | Containerized MySQL with an explicit slug | `--slug lms` `--db-type mysql` |
| [03-moodle-5-version.sh](03-moodle-5-version.sh) | The newest Moodle 5.3.x: PHP 8.4 is selected automatically, and nginx's document root switches to `public/` | `--moodle-version 5.3` |
| [04-explicit-php-version.sh](04-explicit-php-version.sh) | An explicit PHP version instead of automatic selection | `--moodle-version 4.5.15` `--php-version 8.2` |
| [05-custom-admin.sh](05-custom-admin.sh) | Custom administrator username, password, and email | `--moodle-admin-user` `--moodle-admin-password` `--moodle-admin-email` |
| [06-site-names.sh](06-site-names.sh) | Full and short site names | `--moodle-site-fullname` `--moodle-site-shortname` |
| [07-native-postgres.sh](07-native-postgres.sh) | Host PostgreSQL instead of a container (`172.17.0.1:5432`) | `--db-native` |
| [08-basic-auth.sh](08-basic-auth.sh) | HTTP Basic Auth protecting the entire site | `--enable-basic-auth` `--auth-user` `--auth-password` |
| [09-no-ssl.sh](09-no-ssl.sh) | A working HTTP site without a certificate | `--no-ssl` |
| [10-production-full.sh](10-production-full.sh) | Production: fixed credentials and ports, registration, and a full backup (database, files, SSL) | `--db-postgres-*` `--port-*` `--smtp-*` `--profile` `--endpoint` `--create-backup` |

## Generated file samples

All sample values are placeholders.

| File | Description |
|---|---|
| [project.env.example](project.env.example) | `/var/www/<slug>/.env` for containerized PostgreSQL. All conditional sections (`AUTH_*`, `MOODLE_ADMIN_*`, `BACKUP_ARCHIVE_PATH`) are shown together |
| [config.php.example](config.php.example) | `/var/www/<slug>/public_html/config.php` for containerized PostgreSQL: `dbhost=<slug>_db`, internal port `5432`. MySQL uses `dbtype=mysqli` and port `3306`; a native database uses `dbhost=172.17.0.1` and the host database port |
| [endpoint-payload.json](endpoint-payload.json) | The PUT request body sent to `--endpoint` |
