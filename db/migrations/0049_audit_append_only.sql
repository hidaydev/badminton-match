-- 0049: account.audit is append-only in the database, not only by grant.
--
-- 0004 revoked UPDATE and DELETE from bm2_app, which stops the application.
-- The owner role keeps both, and the owner is also the role that runs
-- migrations and the retention tool, so a privileged mistake (or an attacker
-- holding the owner DSN) could rewrite the record of privileged actions
-- without leaving a trace.
--
-- The trigger rejects both statements for every role. The retention tool opts
-- in for the length of one transaction with
-- `set_config('majadu.audit_maintenance', 'on', true)`, so pruning stays
-- possible and nothing else can delete a row. UPDATE is never allowed: a
-- correction is a new audit row, not an edit of the old one.

create or replace function account.audit_append_only() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('majadu.audit_maintenance', true), '') = 'on' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;
  raise exception 'account.audit is append-only: % is not allowed', tg_op
    using errcode = '55000',
          hint = 'prune with tools/auditretention, which sets majadu.audit_maintenance';
end
$$;

create trigger audit_append_only
  before update or delete on account.audit
  for each row execute function account.audit_append_only();
