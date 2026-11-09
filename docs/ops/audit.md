# Audit trail controls

`account.audit` is the record of who changed what. Three controls protect it,
and one is still missing in this release.

## What is enforced today

| Control | Where | What it prevents |
|---|---|---|
| the application role cannot update or delete audit rows | `db/migrations/0004_platform.sql` | a bug or an injection in the API rewriting history |
| retention runs as `bm2_audit_prune`, not `bm2_owner` | `ops/db/roles.sql`, `ops/systemd/majadu-audit-retention.service` | the credential that can change the schema also erasing the record |
| a daily digest is written next to the dumps | `ops/scripts/audit-digest.sh`, `majadu-audit-digest.timer` | an edit by a role that can write the table leaving no trace once the file leaves the host |

`ops/db/roles.sql` creates `bm2_audit_prune` with `SELECT` and `DELETE` on
`account.audit` and no other right. Enable login once for the password in
`majadu-tools.env`:

```sql
alter role bm2_audit_prune login password '<secret>';
```

The digest is a JSON file per UTC day in `MAJADU_BACKUP_DIR`:

```json
{"rows":1234,"digest":"<md5 of the hashed rows>","at":"2026-11-10T02:10:00Z"}
```

Copy the backup directory off the host on the same schedule as the dumps. A
digest that only exists on the host it describes proves nothing.

## What is still missing

- **No append-only trigger.** `bm2_owner` can still `update` or `delete`
  `account.audit` with no trigger and no signature. The grant is a real control
  for the application, not for a privileged operator.
- **Retention is a configuration value without a legal basis.** The window is
  365 days (`docs/privacy.md`); nothing records why that number.
- **The digest is only as good as the copy.** It is written to the backup
  directory; until that directory is copied off the host, it shares the disk's
  fate.

Closing the first item needs a migration under `db/migrations` (a `before
update or delete` trigger that raises unless the session sets a maintenance
flag). That file is outside this change set.
