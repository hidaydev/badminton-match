-- Fix stale status values: 'published' → 'locked'
--
-- Sessions locked before migration 000046 have status='published'
-- instead of status='locked'. The get_session function uses
-- status <> 'draft' for the locked field, so both values work.
-- But for consistency, update 'published' to 'locked'.

update bm.sessions
set status = 'locked',
    updated_at = now()
where status = 'published';
