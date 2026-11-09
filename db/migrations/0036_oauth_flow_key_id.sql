-- 0036: an OIDC flow remembers the key that encrypted its PKCE verifier.
--
-- 0004 created `auth.oauth_flows` with only the ciphertext. `startAuth`
-- encrypted under the active share key and `finishAuth` decrypted under
-- whatever key was active at callback time, so rotating
-- SHARE_CODE_ACTIVE_KEY_ID between the two broke every login in flight. The
-- row now carries the id `encryptWith` returned, and the callback uses it.
--
-- Existing rows are given an empty id because the information was never
-- recorded; they expire within the flow TTL and a callback for one fails the
-- decrypt instead of being read with the wrong key. The column is not null so
-- a new insert cannot omit it.

alter table auth.oauth_flows add column if not exists key_id text;
update auth.oauth_flows set key_id = '' where key_id is null;
alter table auth.oauth_flows alter column key_id set not null;
