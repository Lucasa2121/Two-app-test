-- Read-only verification queries to run AFTER history migrations are deployed.
-- Do not treat these checks as proof that original PDF values were correctly entered.
-- 1. All store history rows must match their approved source snapshot totals.
with source_totals as (
 select s.report_month as month,s.report_end,
 sum((r.value->>'gp')::numeric) gp,
 sum((r.value->>'VGA')::numeric) voice,
 sum((r.value->>'UP')::numeric) upgrades,
 sum((r.value->>'CRU')::numeric) cru,
 sum((r.value->>'FN')::numeric) firstnet,
 sum((r.value->>'INT')::numeric) internet,
 sum((r.value->>'OPPS')::numeric) opportunities,
 sum((r.value->>'EVENTS')::numeric) events,
 sum((r.value->>'htp')::numeric) hometech
 from public.management_kpi_snapshots s
 cross join lateral jsonb_array_elements(s.rows) r(value)
 group by s.report_month,s.report_end
)
select s.month,s.report_end,
 (h.month is not null and h.report_end=s.report_end
  and (h.gp,h.voice,h.upgrades,h.cru,h.firstnet,h.internet,
       h.opportunities,h.events,h.hometech)
    is not distinct from
      (s.gp,s.voice,s.upgrades,s.cru,s.firstnet,s.internet,
       s.opportunities,s.events,s.hometech)) as matches_approved_snapshot,
 exists(
  select 1 from public.store_snapshot_backups b
  where b.month=s.month and b.report_end=s.report_end
  and (b.gp,b.voice,b.upgrades,b.cru,b.firstnet,b.internet,
       b.opportunities,b.events,b.hometech,b.apo)
    is not distinct from
      (h.gp,h.voice,h.upgrades,h.cru,h.firstnet,h.internet,
       h.opportunities,h.events,h.hometech,h.apo)
 ) as has_matching_backup
from source_totals s
left join public.store_monthly_history h on h.month=s.month
order by s.month;

-- 2. Confirm backups remain after snapshot replacement/undo in isolated tests.
-- 3. Restore backup data into a separate temporary/test database and compare
--    month/report_end/all KPI columns. Never run destructive restore on production.
-- 4. Manually compare every approved source PDF against stored monthly totals.
-- 5. Do not enable permanent employee purge until all checks pass.
