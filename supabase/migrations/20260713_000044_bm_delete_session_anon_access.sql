-- Grant delete_session to anon for frontend access.
-- The frontend already has full write access via publish_session (anon-granted),
-- so adding delete access is consistent with the existing security model.
-- The function remains security definer with cascade-based cleanup.

grant execute on function bm.delete_session(text) to anon;
