# PostgreSQL Backup Automation (Ansible)

Deploys and schedules the hybrid PostgreSQL backup workflow from
[`pg_backup.sh`](../pg_backup.sh) via the `pg_backup` role:

1. Installs PostgreSQL client tools (`pg_dump`, `pg_dumpall`, `psql`, `pg_restore`).
2. Creates the backup and log directories.
3. Optionally deploys a `.pgpass` file for password-based auth.
4. Templates the backup script (globals dump, per-database custom-format
   dumps, `pg_restore -l` validation, corrupt-file quarantine, and
   retention cleanup) to the target host.
5. Schedules it via cron.

## Usage

```bash
cd postgresql/ansible
cp inventory/hosts.ini inventory/hosts.ini.local   # edit with your real hosts
ansible-playbook -i inventory/hosts.ini playbook.yml
```

## Configuration

Override role defaults (see `roles/pg_backup/defaults/main.yml`) in
`group_vars/postgresql_servers.yml`, per-host in `host_vars/`, or with
`-e` on the command line. Key variables:

| Variable | Purpose |
|---|---|
| `pg_backup_db_user` | DB role used for the dumps |
| `pg_backup_os_user` | OS user that owns the script/cron job (peer auth normally requires this to match `pg_backup_db_user`) |
| `pg_backup_dir` / `pg_backup_log_dir` | Where backups/logs are written |
| `pg_backup_days_to_keep` | Retention window (days) |
| `pg_backup_cron_hour` / `pg_backup_cron_minute` | Schedule |
| `pg_backup_use_pgpass` / `pg_backup_password` | Enable password auth via a templated `.pgpass` |
| `pg_backup_run_now` | Run the script once immediately after deploying, to smoke-test it |

## Password auth

If the DB user can't rely on peer/trust auth, store the password in an
Ansible Vault file and reference it:

```bash
ansible-vault create group_vars/postgresql_servers/vault.yml
# vault_pg_backup_password: "supersecret"
```

then set in `group_vars/postgresql_servers.yml`:

```yaml
pg_backup_use_pgpass: true
pg_backup_password: "{{ vault_pg_backup_password }}"
```

and run with `--ask-vault-pass` or `--vault-password-file`.

## Using with Semaphore UI

This role needs no changes to run as a Semaphore (ansible-semaphore) Task
Template — Semaphore just invokes `ansible-playbook` against this repo. To
wire it up:

1. **Repository** — add this git repo to the Semaphore project (branch
   `main`).
2. **Key Store** — add the SSH key used to reach the DB host(s). If the
   connecting user needs a sudo/become password (this playbook uses
   `become: true`), either grant it passwordless sudo or store the
   become password as a vaulted variable (see below) rather than typing
   it into Semaphore directly.
3. **Inventory** — either:
   - point Semaphore's "File" inventory type at
     `postgresql/ansible/inventory/hosts.ini`, and edit that file's
     `[postgresql_servers]` group with your real hosts, **or**
   - define hosts directly in Semaphore's own static inventory UI. In
     that case set the group name to `postgresql_servers`, or pass
     `-e pg_backup_target_hosts=<your_group_name>` (Environment extra
     var) if you'd rather keep Semaphore's own naming.
4. **Environment** — use this for non-secret overrides (extra-vars JSON),
   e.g. `{"pg_backup_days_to_keep": 90}`. Don't put `pg_backup_password`
   here in plaintext unless your Semaphore version supports masked
   secret variables — prefer the Vault approach below, which also works
   if you ever run the playbook by hand outside Semaphore.
5. **Vault Password** — if you use the `.pgpass` / Ansible Vault flow
   from the section below, create a Key Store entry holding the vault
   password and attach it to the Template's "Vault Password" field.
   Semaphore then supplies `--vault-password-file` automatically.
6. **Task Template** — Playbook Filename: `postgresql/ansible/playbook.yml`.
   No `ansible.cfg` tuning is required: the role's `roles/` directory is
   discovered automatically because it's a sibling of `playbook.yml`
   regardless of Semaphore's working directory, and Semaphore supplies
   its own `-i` flag so the checked-in `ansible.cfg`'s inventory default
   is only used for ad-hoc runs outside Semaphore.

### Terraform

If Terraform (on the other VM) provisions the DB host(s), this role is
decoupled from that — it only needs a working inventory entry (IP/DNS +
SSH access) once the VM exists. If you want Semaphore to chain
"Terraform apply" straight into this playbook (e.g. feed the new host's
IP in automatically), that requires a Semaphore Integration/webhook or a
Terraform output → dynamic inventory step, which isn't set up here; say
the word if you want that wired up too.

## Restores

Restore procedures are unchanged from
[`manual_pg_restore.sh`](../manual_pg_restore.sh) — this role only
automates taking and scheduling backups.
