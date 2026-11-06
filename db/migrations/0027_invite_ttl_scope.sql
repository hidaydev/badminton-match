-- 0027: `community.invite_ttl_days` was seeded as a platform key even though the
-- settings screen offers it per community and the invite store is about to read
-- the community layer. The scope column is what the API enforces, so it has to
-- match the registry and the L2 write path.
update platform.config
   set scope = 'community'
 where key = 'community.invite_ttl_days' and scope <> 'community';
