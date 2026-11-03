insert into probe (id, note) values (1, 'seed') on conflict (id) do nothing;
