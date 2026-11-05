-- Applied to production as one of several smaller migrations (see DECISIONS D9).

create or replace function public.decide_approval(p_approval uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.approvals;
begin
  perform public.require_owner();
  select * into v from public.approvals where id = p_approval for update;
  if not found then raise exception 'approval not found' using errcode = 'P0002'; end if;
  if v.status <> 'pending' then raise exception 'approval already %', v.status using errcode = '55000'; end if;
  if v.expires_at < now() then raise exception 'approval has expired' using errcode = '55000'; end if;

  update public.approvals set status = case when p_approve then 'approved' else 'rejected' end::public.approval_status,
    decided_by = auth.uid(), decided_at = now(), decision_note = p_note
  where id = p_approval;

  if v.task_id is not null then
    if p_approve then
      update public.tasks set status = 'queued', run_after = now() where id = v.task_id and status = 'awaiting_approval';
    else
      update public.tasks set status = 'cancelled', completed_at = now(),
        error = jsonb_build_object('message', 'rejected by owner', 'note', p_note)
      where id = v.task_id and status = 'awaiting_approval';
    end if;
  end if;

  perform public.write_audit('user', case when p_approve then 'approve' else 'reject' end, 'approvals',
    p_approval::text, v.business_id, jsonb_build_object('action', v.action, 'note', p_note,
      'financial_impact_minor', v.financial_impact_minor));
end $$;

create or replace function public.set_emergency_stop(p_active boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_owner();
  update public.system_controls set value = jsonb_build_object('active', p_active, 'reason', p_reason),
    updated_at = now(), updated_by = auth.uid()
  where key = 'emergency_stop';
  perform public.write_audit('user', case when p_active then 'emergency_stop_on' else 'emergency_stop_off' end,
    'system_controls', 'emergency_stop', null, jsonb_build_object('reason', p_reason));
  insert into public.notifications(category, priority, title, body)
  values ('security', 'critical',
          case when p_active then 'Emergency stop ACTIVATED' else 'Emergency stop released' end, p_reason);
end $$;

create or replace function public.record_manual_ledger_entry(
  p_business uuid, p_entry_type public.ledger_entry_type, p_amount_minor bigint,
  p_occurred_at timestamptz, p_payment_status public.payment_status, p_category text default null,
  p_description text default null, p_reference text default null, p_currency char(3) default 'GBP',
  p_is_test boolean default false, p_corrects uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_manage(p_business);
  if p_entry_type = 'revenue' and not public.is_owner() then
    raise exception 'only the owner may record manual revenue' using errcode = '42501';
  end if;
  insert into public.ledger_entries(business_id, entry_type, amount_minor, currency, occurred_at, payment_status,
    source, reference, category, description, is_test, corrects_entry_id, recorded_by)
  values (p_business, p_entry_type, p_amount_minor, upper(p_currency), p_occurred_at, p_payment_status,
    'manual', p_reference, p_category, p_description, p_is_test, p_corrects, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

revoke execute on function public.decide_approval(uuid,boolean,text) from public, anon;
revoke execute on function public.set_emergency_stop(boolean,text) from public, anon;
revoke execute on function public.record_manual_ledger_entry(uuid, public.ledger_entry_type, bigint, timestamptz, public.payment_status, text, text, text, char, boolean, uuid) from public, anon;
grant execute on function
  public.decide_approval(uuid,boolean,text),
  public.set_emergency_stop(boolean,text),
  public.record_manual_ledger_entry(uuid, public.ledger_entry_type, bigint, timestamptz, public.payment_status, text, text, text, char, boolean, uuid)
to authenticated;
