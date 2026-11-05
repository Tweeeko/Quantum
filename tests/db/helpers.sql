-- Test helpers. Session starts as superuser; user/service/anon contexts switch
-- session authorization to `authenticator`, exactly as PostgREST connects.
\set as_admin 'reset role; reset session authorization; select set_config(''request.jwt.claims'', '''', false);'
\set as_owner 'reset role; set session authorization authenticator; set role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}'', false);'
\set as_stranger 'reset role; set session authorization authenticator; set role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}'', false);'
\set as_manager 'reset role; set session authorization authenticator; set role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}'', false);'
\set as_service 'reset role; set session authorization authenticator; set role service_role; select set_config(''request.jwt.claims'', ''{"role":"service_role"}'', false);'
\set as_anon 'reset role; set session authorization authenticator; set role anon; select set_config(''request.jwt.claims'', ''{"role":"anon"}'', false);'
\pset tuples_only on
\pset format unaligned
\o /dev/null
