-- Applied to production as one of several smaller migrations (see DECISIONS D9).

create or replace function public.require_owner() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then
    raise exception 'permission denied: portfolio owner required' using errcode = '42501';
  end if;
end $$;

create or replace function public.require_manage(bid uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if bid is null then perform public.require_owner(); return; end if;
  if not public.can_manage_business(bid) then
    raise exception 'permission denied for business %', bid using errcode = '42501';
  end if;
end $$;

create or replace function public.is_service() returns boolean
language sql stable as $$
  -- JWT role as set by PostgREST (both legacy and current GUC forms), or a
  -- direct database session such as pg_cron. Clients always connect via
  -- `authenticator`, so session_user cannot be spoofed from the API.
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
                  nullif(current_setting('request.jwt.claim.role', true), '')) = 'service_role'
      or session_user in ('postgres','supabase_admin');
$$;

revoke execute on function public.require_owner() from public, anon, authenticated;
revoke execute on function public.require_manage(uuid) from public, anon, authenticated;
revoke execute on function public.is_service() from public, anon, authenticated;
