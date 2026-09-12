# PostgreSQL Backup Automation (Ansible)

Deploys and schedules the hybrid PostgreSQL backup workflow from
[`pg_backup.sh`](../pg_backup.sh) via the `pg_backup` role:

1. Installs PostgreSQL client tools (`pg_dump`, `pg_dumpall`, `psql`, `pg_restore`).
2. Creates the backup and log directories.
3. Optionally deploys a `.pgpass` file for password-based auth.
4. Templates the backup script (globals dump, per-database custom-format
   dumps, `pg_restore -l` validation, corrupt-file quarantine, and
   retention cleanup) to the target host.
5. Runs it.

Scheduling is meant to be owned by **Semaphore's own Task Template
Schedule** (a cron expression configured in Semaphore, not on the target
VM) — see [Using with Semaphore UI](#using-with-semaphore-ui). Each
scheduled run re-applies the idempotent setup steps and then executes
the backup, so config drift self-heals and every run is a fresh backup.
An OS-level cron job on the target host is also supported
(`pg_backup_cron_enabled: true`) for cases where you want the host to
schedule itself independently of Semaphore, but leave it off (default)
when Semaphore is the scheduler to avoid double backups.

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
| `pg_backup_cron_enabled` | Also schedule via OS crontab on the target host (default `false` — leave off when Semaphore's own Schedule is the scheduler) |
| `pg_backup_cron_hour` / `pg_backup_cron_minute` | Only used when `pg_backup_cron_enabled: true` |
| `pg_backup_use_pgpass` | Enable password auth via `.pgpass` (instead of peer/trust) |
| `pg_backup_manage_pgpass` | `"auto"` (prefer an existing `.pgpass`, fall back to `pg_backup_password`), or force `true`/`false` — see [Password auth](#password-auth) |
| `pg_backup_password` | Password used only when the role ends up rendering `.pgpass` itself |
| `pg_backup_run_now` | Execute the backup during this run (default `true` — this is what makes a scheduled Semaphore run actually take a backup; set `false` for a deploy-only run) |

## Password auth

If the DB user can't rely on peer/trust auth, set `pg_backup_use_pgpass:
true`. `pg_backup_manage_pgpass` controls where the file's contents come
from, and defaults to `"auto"`:

1. **Prefer a `.pgpass` already on the VM.** If
   `pg_backup_pgpass_path` (default `/home/{{ pg_backup_os_user }}/.pgpass`)
   already exists with `0600` permissions — placed manually, dropped by a
   secrets agent (Vault, SOPS, etc.), or left over from a previous run —
   the role leaves it alone and never touches `pg_backup_password` at
   all. This is the strongest option: Ansible/Semaphore never see the
   plaintext credential.
2. **Fall back to `pg_backup_password` if it's missing or unsafe.** If
   the file isn't there, or has the wrong permissions, the role renders
   it from `pg_backup_password` instead. The simplest way to supply that
   in this setup: create a Semaphore Environment, add
   `pg_backup_password` marked as a **secret** value, and attach that
   Environment to the Task Template — nothing is committed to git, and
   Semaphore masks it in task logs.
3. **Fail loudly if neither is available**, with a message telling you
   to either provision the file or set `pg_backup_password`.

You can override the auto-detection:

```yaml
pg_backup_manage_pgpass: true   # always render from pg_backup_password, even if a file already exists
pg_backup_manage_pgpass: false  # always require an externally-provisioned file; never fall back
```

An Ansible Vault file is also a valid source for `pg_backup_password`
if you'd rather not use Semaphore secrets (e.g. for ad-hoc runs outside
Semaphore):

```bash
ansible-vault create group_vars/postgresql_servers/vault.yml
# vault_pg_backup_password: "supersecret"
```

```yaml
pg_backup_password: "{{ vault_pg_backup_password }}"
```

and run with `--ask-vault-pass` or `--vault-password-file` (or attach
the vault password as a Semaphore Key Store entry — see below).

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
7. **Schedule** — add a Schedule to that Task Template with your desired
   cron expression (e.g. `0 2 * * *` for nightly at 02:00). With the
   defaults (`pg_backup_run_now: true`, `pg_backup_cron_enabled: false`),
   every scheduled Semaphore run both re-applies the idempotent setup
   (packages/dirs/script/`.pgpass`) and executes a backup — no cron job
   on the DB VM itself.

Two optional Task Templates if you'd rather separate "apply config" from
"take a backup" (e.g. to redeploy the script without triggering a
backup, or to trigger a backup on-demand without the setup checks):

| Template | Playbook Filename / args |
| --- | --- |
| Deploy config | `postgresql/ansible/playbook.yml` with CLI arg `--tags deploy` |
| Run backup | `postgresql/ansible/playbook.yml` with CLI arg `--tags run` |

Put the Schedule on the "Run backup" template in that case; run "Deploy
config" manually whenever role variables or the script template change.

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
