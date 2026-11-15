
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async req => {
 const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization,apikey,content-type',
  'Access-Control-Allow-Methods': 'POST,OPTIONS'
 };
 const respond = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers });

 if (req.method === 'OPTIONS') return new Response(null, { headers });
 if (req.method !== 'POST') return respond({ error: 'POST only' }, 405);

 try {
  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  const bearer = req.headers.get('Authorization') || '';
  const auth = createClient(url, anon, {
   global: { headers: { Authorization: bearer } }
  });

  const { data: { user }, error: authError } = await auth.auth.getUser();
  if (authError || !user) return respond({ error: 'Unauthorized' }, 401);

  const admin = createClient(url, service);
  const { data: caller } = await admin.from('team_profiles')
   .select('role,active').eq('user_id', user.id).single();

  if (!caller?.active || caller.role !== 'admin')
   return respond({ error: 'Admin required' }, 403);

  const body = await req.json();

  if (body.action === 'invite') {
   const { count } = await admin.from('team_profiles')
    .select('user_id', { count: 'exact', head: true })
    .eq('active', true);

   if ((count || 0) >= 10)
    return respond({ error: '10 active accounts maximum' }, 409);

   if (!['admin','employee'].includes(body.role) ||
       !body.name?.trim() || !body.uid?.trim() ||
       !body.email?.includes('@'))
    return respond({ error: 'Invalid team member details' }, 400);

   const { data, error } = await admin.auth.admin.inviteUserByEmail(
    body.email.trim(),
    { data: { full_name: body.name.trim() } }
   );

   if (error) return respond({ error: error.message }, 400);

   const { error: insertError } = await admin.from('team_profiles').insert({
    user_id: data.user.id,
    full_name: body.name.trim(),
    att_uid: body.uid.trim().toUpperCase(),
    role: body.role,
    active: true
   });

   if (insertError)
    return respond({
     error: 'Invitation created but profile failed: ' + insertError.message
    }, 400);

   await admin.from('audit_events').insert({
    actor_id: user.id,
    action: 'invite_account',
    target_id: data.user.id,
    detail: { role: body.role }
   });

   return respond({ ok: true });
  }

  if (body.action === 'update') {
   if (body.user_id === user.id)
    return respond({ error: 'Cannot change your own access' }, 400);

   const { data: target } = await admin.from('team_profiles')
    .select('role,active').eq('user_id', body.user_id).single();

   if (!target) return respond({ error: 'Account not found' }, 404);

   if (target.role === 'admin' &&
       (body.role === 'employee' || body.active === false)) {
    const { count } = await admin.from('team_profiles')
     .select('user_id', { count: 'exact', head: true })
     .eq('role', 'admin').eq('active', true);

    if ((count || 0) <= 1)
     return respond({ error: 'Cannot remove last active Admin' }, 409);
   }

   if (body.active === true && !target.active) {
    const { count } = await admin.from('team_profiles')
     .select('user_id', { count: 'exact', head: true })
     .eq('active', true);

    if ((count || 0) >= 10)
     return respond({ error: '10 active accounts maximum' }, 409);
   }

   const patch: Record<string,unknown> = {};

   if (typeof body.active === 'boolean')
    patch.active = body.active;

   if (['admin','employee'].includes(body.role))
    patch.role = body.role;

   if (!Object.keys(patch).length)
    return respond({ error: 'No valid change' }, 400);

   const { error } = await admin.from('team_profiles')
    .update(patch).eq('user_id', body.user_id);

   if (error) return respond({ error: error.message }, 400);

   await admin.from('audit_events').insert({
    actor_id: user.id,
    action: 'update_account',
    target_id: body.user_id,
    detail: patch
   });

   return respond({ ok: true });
  }

  return respond({ error: 'Unknown action' }, 400);
 } catch (e) {
  return respond({ error: String(e) }, 500);
 }
});
