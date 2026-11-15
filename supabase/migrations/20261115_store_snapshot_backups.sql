-- Independent, append-only backup of store-level monthly totals.
-- Deploy AFTER monthly history, snapshots, and sync trigger migrations.
-- This preserves store totals independently of employee-linked records.
-- It does not authorize employee deletion or automatic retention pruning.
create table if not exists public.store_snapshot_backups (
  id bigint generated always as identity primary key,
  month date not null,
  report_end date not null,
  gp numeric not null,
  voice numeric not null,
  upgrades numeric not null,
  cru numeric not null,
  firstnet numeric not null,
  internet numeric not null,
  opportunities numeric not null,
  events numeric not null,
  hometech numeric not null,
  apo numeric,
  source_snapshot_digest text not null,
  captured_at timestamptz not null default now(),
  captured_by uuid,
  unique(month,source_snapshot_digest)
);
create index if not exists store_snapshot_backups_month_idx
 on public.store_snapshot_backups(month,captured_at desc);
alter table public.store_snapshot_backups enable row level security;
revoke all on public.store_snapshot_backups from public,anon,authenticated;
create policy store_snapshot_backups_admin_read on public.store_snapshot_backups
 for select to authenticated using (exists (
 select 1 from public.team_profiles p where p.user_id=auth.uid()
 and p.active and p.role='admin'));
grant select on public.store_snapshot_backups to authenticated;

create or replace function public.management_backup_store_snapshot()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_digest text;
begin
 -- Only snapshot-driven history writes qualify; source PDF still requires manual verification.
 select md5(s.rows::text || '|' || s.report_end::text)
 into v_digest from public.management_kpi_snapshots s where s.report_month=new.month;
 if v_digest is null then
   raise exception 'Store backup requires an approved source snapshot';
 end if;
 insert into public.store_snapshot_backups
 (month,report_end,gp,voice,upgrades,cru,firstnet,internet,
  opportunities,events,hometech,apo,source_snapshot_digest,captured_by)
 values
 (new.month,new.report_end,new.gp,new.voice,new.upgrades,new.cru,new.firstnet,new.internet,
  new.opportunities,new.events,new.hometech,new.apo,v_digest,auth.uid())
 on conflict(month,source_snapshot_digest) do nothing;
 return new;
end $$;
revoke all on function public.management_backup_store_snapshot() from public,anon,authenticated;
drop trigger if exists management_backup_store_history on public.store_monthly_history;
create trigger management_backup_store_history
after insert or update on public.store_monthly_history
for each row execute function public.management_backup_store_snapshot();

-- Explicitly deny browser modifications. Backup rows are append-only by application design.
-- Database owners and service-role operations remain privileged: deletion protections
-- and independent restoration drills are required before enabling employee purge.
