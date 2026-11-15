-- Development migration: keep monthly histories synchronized with compact snapshots.
-- Run after 20261115_monthly_kpi_history.sql and 20261115_management_kpi_snapshots.sql.
-- No changes to official AGT/ADT calculations or published employee KPI records.
--
-- A single snapshot is the source of truth for each report month.
-- Trigger execution is part of the save/undo transaction: any error rolls back
-- both the snapshot and its derived histories.
create or replace function public.management_sync_monthly_history()
returns trigger language plpgsql security definer
set search_path = '' as $$
declare
  v_month date;
  v_snapshot public.management_kpi_snapshots%rowtype;
begin
  -- NEW is undefined for DELETE triggers; choose the valid record explicitly.
  if tg_op='DELETE' then v_month := old.report_month;
  else v_month := new.report_month; end if;
  -- Remove derived records first. Undo DELETE removes the corresponding history;
  -- undo UPDATE/INSERT reconstructs it from the restored snapshot.
  delete from public.employee_monthly_history where month=v_month;
  delete from public.store_monthly_history where month=v_month;

  if tg_op='DELETE' then return old; end if;
  v_snapshot := new;

  -- All PDF rows count toward store totals, including unregistered staff.
  -- The APO aggregation rule is not confirmed: store APO remains NULL,
  -- never a fabricated sum or average.
  insert into public.store_monthly_history
    (month,report_end,gp,voice,upgrades,cru,firstnet,internet,
     opportunities,events,hometech,apo,updated_at)
  select v_month,v_snapshot.report_end,
    coalesce(sum((r.value->>'gp')::numeric),0),
    coalesce(sum((r.value->>'VGA')::numeric),0),
    coalesce(sum((r.value->>'UP')::numeric),0),
    coalesce(sum((r.value->>'CRU')::numeric),0),
    coalesce(sum((r.value->>'FN')::numeric),0),
    coalesce(sum((r.value->>'INT')::numeric),0),
    coalesce(sum((r.value->>'OPPS')::numeric),0),
    coalesce(sum((r.value->>'EVENTS')::numeric),0),
    coalesce(sum((r.value->>'htp')::numeric),0),
    null,now()
  from jsonb_array_elements(v_snapshot.rows) as r(value);

  -- Employee history is recorded only for uniquely matched registered UIDs.
  -- Unmatched PDF rows still contribute to store totals.
  -- If duplicate team profile UIDs exist, fail rather than double-count.
  if exists (
    select 1 from public.team_profiles p
    join jsonb_array_elements(v_snapshot.rows) as r(value)
      on p.att_uid=trim(r.value->>'uid')
    group by p.att_uid having count(*)>1
  ) then
    raise exception 'Duplicate registered employee UID in team_profiles';
  end if;

  insert into public.employee_monthly_history
    (employee_id,month,report_end,gp,voice,upgrades,cru,firstnet,
     internet,opportunities,events,hometech,apo,updated_at)
  select p.user_id,v_month,v_snapshot.report_end,
    (r.value->>'gp')::numeric,
    (r.value->>'VGA')::numeric,
    (r.value->>'UP')::numeric,
    (r.value->>'CRU')::numeric,
    (r.value->>'FN')::numeric,
    (r.value->>'INT')::numeric,
    (r.value->>'OPPS')::numeric,
    (r.value->>'EVENTS')::numeric,
    (r.value->>'htp')::numeric,
    (r.value->>'apo')::numeric,now()
  from jsonb_array_elements(v_snapshot.rows) as r(value)
  join public.team_profiles p on p.att_uid=trim(r.value->>'uid')
  where p.active is true;

  return new;
end $$;

drop trigger if exists management_snapshot_sync_history on public.management_kpi_snapshots;
create trigger management_snapshot_sync_history
after insert or update or delete on public.management_kpi_snapshots
for each row execute function public.management_sync_monthly_history();

revoke all on function public.management_sync_monthly_history() from public,anon,authenticated;

-- Note: 18-month retention is deliberately NOT enabled here. Automatic
-- pruning requires a verified independent store backup and must also account
-- for the one-step undo table. Until then, history is not silently deleted.
-- MoM/YoY read queries and dashboard UI are the next development milestone.
