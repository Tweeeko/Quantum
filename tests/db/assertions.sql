-- Assertion functions (installed as superuser before tests).
create schema t;
grant usage on schema t to public;
create function t.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;
create function t.raises(sql text, msg text, expected_state text default null) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if expected_state is not null and sqlstate <> expected_state then
      raise exception 'FAIL: % (expected SQLSTATE %, got %: %)', msg, expected_state, sqlstate, sqlerrm;
    end if;
    raise notice 'ok - %', msg;
    return;
  end;
  raise exception 'FAIL: % (statement succeeded but should have failed)', msg;
end $$;
grant execute on all functions in schema t to public;
