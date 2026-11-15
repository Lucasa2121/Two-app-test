-- Cherrydale Management App: monthly KPI history foundation.
-- Review against existing Supabase schema before applying. NOT deployed automatically.
-- Each month stores the latest approved MTD values, never a sum of uploads.
create table if not exists public.store_monthly_history (
  month date primary key,
  report_end date not null,
  gp numeric not null default 0,
  voice numeric not null default 0,
  upgrades numeric not null default 0,
  cru numeric not null default 0,
  firstnet numeric not null default 0,
  internet numeric not null default 0,
  opportunities numeric not null default 0,
  events numeric not null default 0,
  hometech numeric not null default 0,
  apo numeric,
  updated_at timestamptz not null default now(),
  constraint store_month_start check (extract(day from month)=1)
);
create table if not exists public.employee_monthly_history (
  employee_id uuid not null references public.team_profiles(user_id) on delete cascade,
  month date not null,
  report_end date not null,
  gp numeric not null default 0,
  voice numeric not null default 0,
  upgrades numeric not null default 0,
  cru numeric not null default 0,
  firstnet numeric not null default 0,
  internet numeric not null default 0,
  opportunities numeric not null default 0,
  events numeric not null default 0,
  hometech numeric not null default 0,
  apo numeric,
  updated_at timestamptz not null default now(),
  primary key(employee_id,month),
  constraint employee_month_start check (extract(day from month)=1)
);
-- Independent store rows survive employee deletion.
create index if not exists employee_monthly_history_month_idx on public.employee_monthly_history(month);
alter table public.store_monthly_history enable row level security;
alter table public.employee_monthly_history enable row level security;
-- Only active administrators may read history. Writes should go through a
-- server-side transactional RPC, not a browser insert or update.
drop policy if exists store_monthly_admin_read on public.store_monthly_history;
create policy store_monthly_admin_read on public.store_monthly_history
for select to authenticated using (exists (
 select 1 from public.team_profiles p where p.user_id=auth.uid()
 and p.active=true and p.role='admin'
));
drop policy if exists employee_monthly_admin_read on public.employee_monthly_history;
create policy employee_monthly_admin_read on public.employee_monthly_history
for select to authenticated using (exists (
 select 1 from public.team_profiles p where p.user_id=auth.uid()
 and p.active=true and p.role='admin'
));
-- RLS policies alone do not grant SELECT privileges to the API role.
grant select on public.store_monthly_history to authenticated;
grant select on public.employee_monthly_history to authenticated;
revoke all on public.store_monthly_history from anon;
revoke all on public.employee_monthly_history from anon;
-- Retention job should delete rows with month older than the 18-month window
-- AFTER a separately verified store backup has completed. Do not schedule yet.
-- Deactivation must be a server-side transaction that verifies store totals
-- before purging employee-owned records and revoking auth access.
