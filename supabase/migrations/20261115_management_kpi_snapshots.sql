-- Development-only migration: apply after reviewing the preceding history migration.
-- Compact approved KPI snapshots, independent of browser localStorage.
create table if not exists public.management_kpi_snapshots (
  report_month date primary key,
  report_start date not null,
  report_end date not null,
  rows jsonb not null,
  approved_by uuid not null,
  approved_at timestamptz not null default now(),
  constraint snapshot_month_first check (extract(day from report_month)=1),
  constraint snapshot_dates_valid check (report_start<=report_end and date_trunc('month',report_end)::date=report_month),
  constraint snapshot_rows_array check (jsonb_typeof(rows)='array')
);
create table if not exists public.management_kpi_snapshot_undo (
  report_month date primary key,
  previous_snapshot jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);
alter table public.management_kpi_snapshots enable row level security;
alter table public.management_kpi_snapshot_undo enable row level security;
revoke all on public.management_kpi_snapshots from anon, authenticated;
revoke all on public.management_kpi_snapshot_undo from anon, authenticated;

-- SECURITY DEFINER bypasses table RLS, so every RPC explicitly checks
-- authenticated admin membership. Never expose these functions to anon.
create or replace function public.management_save_kpi_snapshot(
  p_start date, p_end date, p_rows jsonb
) returns jsonb language plpgsql security definer
set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_month date := date_trunc('month',p_end)::date;
  v_previous jsonb;
  v_row jsonb;
  v_seen text[] := array[]::text[];
  v_att_uid text;
  v_key text;
  v_number numeric;
begin
  if v_uid is null or not exists (
    select 1 from public.team_profiles p
    where p.user_id=v_uid and p.active is true and p.role='admin'
  ) then raise exception 'Administrator authorization required' using errcode='42501'; end if;
  if p_start is null or p_end is null or p_start>p_end
    or p_start<>date_trunc('month',p_start)::date
    or date_trunc('month',p_start)<>date_trunc('month',p_end)
    or p_end>current_date then
    raise exception 'Invalid MTD report dates';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array'
     or jsonb_array_length(p_rows)=0 or jsonb_array_length(p_rows)>2000 then
    raise exception 'Expected 1 to 2000 employee KPI rows';
  end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row)<>'object' then raise exception 'Invalid row'; end if;
    v_att_uid := trim(v_row->>'uid');
    if v_att_uid is null or length(v_att_uid)<1 or length(v_att_uid)>64
       or v_att_uid=any(v_seen) then
      raise exception 'Missing, duplicate, or invalid employee UID';
    end if;
    v_seen := array_append(v_seen,v_att_uid);
    foreach v_key in array array['gp','apo','htp','VGA','UP','CRU','FN','INT','OPPS','EVENTS'] loop
      if not (v_row ? v_key) or jsonb_typeof(v_row->v_key)<>'number' then
        raise exception 'Missing or invalid KPI % for UID %',v_key,v_att_uid;
      end if;
      v_number := (v_row->>v_key)::numeric;
      if v_number<0 or v_number>1000000000 then
        raise exception 'Out-of-range KPI % for UID %',v_key,v_att_uid;
      end if;
    end loop;
  end loop;

  -- Serialize concurrent approvals for the same month, including first insert.
  perform pg_advisory_xact_lock(hashtextextended('management_kpi:'||v_month::text,0));
  select to_jsonb(s) into v_previous
    from public.management_kpi_snapshots s where s.report_month=v_month;
  if v_previous is not null and p_end<(v_previous->>'report_end')::date then
    raise exception 'Cannot replace a newer MTD snapshot with an older report';
  end if;
  insert into public.management_kpi_snapshot_undo(report_month,previous_snapshot,changed_by,changed_at)
  values(v_month,v_previous,v_uid,now())
  on conflict(report_month) do update set
    previous_snapshot=excluded.previous_snapshot,
    changed_by=excluded.changed_by,changed_at=excluded.changed_at;
  insert into public.management_kpi_snapshots
    (report_month,report_start,report_end,rows,approved_by,approved_at)
  values(v_month,p_start,p_end,p_rows,v_uid,now())
  on conflict(report_month) do update set
    report_start=excluded.report_start,report_end=excluded.report_end,
    rows=excluded.rows,approved_by=excluded.approved_by,approved_at=excluded.approved_at;
  return jsonb_build_object('month',v_month,'employee_count',jsonb_array_length(p_rows),'replaced',v_previous is not null);
end $$;

create or replace function public.management_undo_kpi_snapshot(p_month date)
returns jsonb language plpgsql security definer
set search_path = '' as $$
declare
 v_uid uuid := auth.uid();
 v_prior jsonb;
begin
 if v_uid is null or not exists (
   select 1 from public.team_profiles p
   where p.user_id=v_uid and p.active is true and p.role='admin'
 ) then raise exception 'Administrator authorization required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then
   raise exception 'Month must be the first day of the month';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('management_kpi:'||p_month::text,0));
 select previous_snapshot into v_prior from public.management_kpi_snapshot_undo
 where report_month=p_month for update;
 if not found then raise exception 'No undo available for this month'; end if;
 if v_prior is null then
   delete from public.management_kpi_snapshots where report_month=p_month;
 else
   insert into public.management_kpi_snapshots
    (report_month,report_start,report_end,rows,approved_by,approved_at)
   values((v_prior->>'report_month')::date,(v_prior->>'report_start')::date,
     (v_prior->>'report_end')::date,v_prior->'rows',
     (v_prior->>'approved_by')::uuid,(v_prior->>'approved_at')::timestamptz)
   on conflict(report_month) do update set
     report_start=excluded.report_start,report_end=excluded.report_end,
     rows=excluded.rows,approved_by=excluded.approved_by,approved_at=excluded.approved_at;
 end if;
 delete from public.management_kpi_snapshot_undo where report_month=p_month;
 return jsonb_build_object('month',p_month,'restored',v_prior is not null);
end $$;
revoke all on function public.management_save_kpi_snapshot(date,date,jsonb) from public,anon;
revoke all on function public.management_undo_kpi_snapshot(date) from public,anon;
grant execute on function public.management_save_kpi_snapshot(date,date,jsonb) to authenticated;
grant execute on function public.management_undo_kpi_snapshot(date) to authenticated;

-- Next integration milestone: map snapshot rows into store_monthly_history
-- and employee_monthly_history in the SAME transaction, then connect UI.
-- This migration intentionally does not modify official AGT/ADT records.
