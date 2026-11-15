-- Permissions-only security hardening for existing Management/Employee RPCs.
-- No data changes or function-body changes. Deployment requires approval.
-- Revoke PUBLIC grants (inherited by anon), while preserving signed-in callers.
revoke execute on function public.admin_set_shift(uuid,date,boolean) from public,anon;
revoke execute on function public.admin_set_uploads(boolean) from public,anon;
revoke execute on function public.is_active_employee() from public,anon;
revoke execute on function public.is_team_admin() from public,anon;
revoke execute on function public.log_my_shift() from public,anon;
revoke execute on function public.publish_collective_report(date,date,jsonb) from public,anon;
revoke execute on function public.undo_my_shift() from public,anon;
grant execute on function public.admin_set_shift(uuid,date,boolean) to authenticated;
grant execute on function public.admin_set_uploads(boolean) to authenticated;
grant execute on function public.is_active_employee() to authenticated;
grant execute on function public.is_team_admin() to authenticated;
grant execute on function public.log_my_shift() to authenticated;
grant execute on function public.publish_collective_report(date,date,jsonb) to authenticated;
grant execute on function public.undo_my_shift() to authenticated;
