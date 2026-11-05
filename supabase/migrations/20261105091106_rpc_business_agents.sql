-- Applied to production as one of several smaller migrations (see DECISIONS D9).

create or replace function public.create_business(
  p_name text, p_slug text, p_template_key text,
  p_description text default null, p_category text default null, p_business_model text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_modules text[];
begin
  perform public.require_owner();
  select modules into v_modules from public.business_templates where key = p_template_key;
  if v_modules is null then raise exception 'unknown template %', p_template_key using errcode = '22023'; end if;

  insert into public.businesses(name, slug, template_key, description, category, business_model, status, created_by)
  values (trim(p_name), lower(trim(p_slug)), p_template_key, p_description, p_category,
          coalesce(p_business_model, p_template_key), 'proposed', auth.uid())
  returning id into v_id;

  insert into public.business_modules(business_id, module_key)
  select v_id, unnest(v_modules);

  perform public.write_audit('user', 'create_business', 'businesses', v_id::text, v_id,
    jsonb_build_object('template', p_template_key));
  return v_id;
end $$;

create or replace function public.set_business_status(p_business uuid, p_status public.business_status, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_old public.business_status;
begin
  perform public.require_owner();
  select status into v_old from public.businesses where id = p_business for update;
  if v_old is null then raise exception 'business not found' using errcode = 'P0002'; end if;
  -- Launching (-> active) is a Level 3 decision; only the owner can do it, and it is audited.
  update public.businesses set status = p_status where id = p_business;
  perform public.write_audit('user', 'set_business_status', 'businesses', p_business::text, p_business,
    jsonb_build_object('from', v_old, 'to', p_status, 'note', p_note));
end $$;

create or replace function public.create_agent(
  p_business uuid, p_name text, p_role text, p_responsibilities text[] default '{}',
  p_autonomy_level smallint default 1, p_model_tier text default 'economical')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_manage(p_business);
  if p_autonomy_level >= 3 then perform public.require_owner(); end if;
  insert into public.agents(business_id, scope, name, role, responsibilities, autonomy_level, model_tier)
  values (p_business, case when p_business is null then 'portfolio' else 'business' end::public.agent_scope,
          p_name, p_role, coalesce(p_responsibilities,'{}'), p_autonomy_level, p_model_tier)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.set_agent_state(p_agent uuid, p_state public.agent_admin_state)
returns void language plpgsql security definer set search_path = public as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.agents where id = p_agent;
  if not found then raise exception 'agent not found' using errcode = 'P0002'; end if;
  perform public.require_manage(v_bid);
  update public.agents set admin_state = p_state where id = p_agent;
end $$;

revoke execute on function public.create_business(text,text,text,text,text,text) from public, anon;
revoke execute on function public.set_business_status(uuid, public.business_status, text) from public, anon;
revoke execute on function public.create_agent(uuid,text,text,text[],smallint,text) from public, anon;
revoke execute on function public.set_agent_state(uuid, public.agent_admin_state) from public, anon;
grant execute on function public.is_owner(), public.can_access_business(uuid), public.can_manage_business(uuid) to authenticated;
grant execute on function
  public.create_business(text,text,text,text,text,text),
  public.set_business_status(uuid, public.business_status, text),
  public.create_agent(uuid,text,text,text[],smallint,text),
  public.set_agent_state(uuid, public.agent_admin_state)
to authenticated;
