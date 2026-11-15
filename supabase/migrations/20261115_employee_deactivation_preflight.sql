-- Management employee departure: preflight guard, development branch only.
-- This intentionally does NOT delete employee records or revoke auth.
-- Complete deletion requires inventory of ALL user-linked tables and a
-- server-side Auth Admin API call, coordinated with an audited transaction.
create or replace function public.management_employee_deactivation_preflight(p_employee_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_admin uuid := auth.uid();
  v_employee public.team_profiles%rowtype;
  v_latest date;
  v_months integer;
  v_employee_months integer;
begin
  if v_admin is null or not exists (
    select 1 from public.team_profiles p
    where p.user_id=v_admin and p.active is true and p.role='admin'
  ) then
    raise exception 'Administrator authorization required' using errcode='42501';
  end if;
  if p_employee_id is null or p_employee_id=v_admin then
    raise exception 'Cannot deactivate this account';
  end if;
  select * into v_employee from public.team_profiles
   where user_id=p_employee_id;
  if not found then raise exception 'Employee not found'; end if;
  if v_employee.role='admin' then
    raise exception 'Demote administrator before employee deletion';
  end if;
  -- A store snapshot is independent of the employee's foreign keys.
  select max(report_end),count(*) into v_latest,v_months
  from public.store_monthly_history;
  select count(*) into v_employee_months
  from public.employee_monthly_history where employee_id=p_employee_id;
  return jsonb_build_object(
    'employee_id',p_employee_id,
    'att_uid',v_employee.att_uid,
    'active',v_employee.active,
    'store_months',v_months,
    'employee_months',v_employee_months,
    'latest_store_report_end',v_latest,
    'store_history_present',v_months>0,
    'ready_for_purge',false,
    'blockers',jsonb_build_array(
      'Store snapshots must be independently verified against the original approved PDF',
      'Inventory all user-linked tables, audit logs and legal retention obligations',
      'Implement privileged Auth account removal and atomic data cleanup'
    )
  );
end $$;
revoke all on function public.management_employee_deactivation_preflight(uuid) from public,anon;
grant execute on function public.management_employee_deactivation_preflight(uuid) to authenticated;
