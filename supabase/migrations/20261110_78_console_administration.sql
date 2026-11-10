-- 78 · Reprise dans la console des fonctions de l'ancien écran « Administration » :
-- paiements d'abonnement à valider, formules, lieux, moyens de paiement, réglages Nuittea.com.
-- Les fonctions existantes acceptent désormais aussi l'équipe Nuittea selon ses accès ; aucune donnée modifiée.

do $$ declare d text; begin
  foreach d in array array['admin_localities', 'admin_locality_save', 'admin_locality_merge'] loop
    execute replace(pg_get_functiondef(('public.' || d)::regproc), 'public.is_platform_admin()', '(public.is_platform_admin() or public.staff_can(''moderation''))');
  end loop;
  execute replace(pg_get_functiondef('public.confirm_subscription_payment'::regproc), 'public.is_platform_admin()', '(public.is_platform_admin() or public.staff_can(''finance''))');
  execute replace(pg_get_functiondef('public.fail_subscription_payment'::regproc), 'public.is_platform_admin()', '(public.is_platform_admin() or public.staff_can(''finance''))');
end $$;

create or replace function public.admin_billing_data()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not (public.staff_can('finance') or public.staff_can('settings')) then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object(
    'pending', coalesce((select jsonb_agg(z) from (select jsonb_build_object('id', y.id, 'at', y.created_at, 'amount', y.amount, 'method', y.payment_method, 'cycle', y.billing_cycle,
        'org', o.name, 'org_id', o.id, 'plan', p.name, 'ref', y.transaction_reference) z from public.payments y join public.organizations o on o.id = y.organization_id left join public.plans p on p.id = y.plan_id
        where y.status = 'pending' order by y.created_at) q), '[]'),
    'history', coalesce((select jsonb_agg(z) from (select jsonb_build_object('at', coalesce(y.paid_at, y.created_at), 'amount', y.amount, 'method', y.payment_method, 'cycle', y.billing_cycle,
        'org', o.name, 'plan', p.name, 'status', y.status, 'ref', y.transaction_reference) z from public.payments y join public.organizations o on o.id = y.organization_id left join public.plans p on p.id = y.plan_id
        where y.status <> 'pending' order by coalesce(y.paid_at, y.created_at) desc limit 60) q), '[]'),
    'plans', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'slug', p.slug, 'name', p.name, 'monthly_price', p.monthly_price, 'yearly_price', p.yearly_price, 'max_rooms', p.max_rooms,
        'max_users', p.max_users, 'max_properties', p.max_properties, 'trial_days', p.trial_days, 'is_trial', p.is_trial, 'is_public', p.is_public, 'is_active', p.is_active, 'is_quote_based', p.is_quote_based,
        'features', p.features, 'clients', (select count(*) from public.subscriptions s join public.organizations o on o.id = s.organization_id where s.plan_id = p.id and not o.is_test)) order by p.sort_order) from public.plans p), '[]'),
    'providers', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'kind', kind, 'is_active', is_active) order by sort_order) from public.payment_providers), '[]'),
    'settings', (select jsonb_object_agg(key, value) from public.platform_settings where key in ('naya_payment_instructions', 'naya_payment_delay_days', 'payout_fee_pct')));
end $$;

create or replace function public.admin_payment_decide(p_id uuid, p_ok boolean, p_reference text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare r jsonb; v_org uuid;
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  select organization_id into v_org from public.payments where id = p_id;
  if p_ok then
    if length(trim(coalesce(p_reference, ''))) < 3 then raise exception 'Saisissez la référence de la transaction.'; end if;
    r := public.confirm_subscription_payment(p_id, trim(p_reference), jsonb_build_object('validated_by', 'console', 'staff', auth.uid()));
  else
    perform public.fail_subscription_payment(p_id, coalesce(nullif(trim(p_reason), ''), 'Rejeté par l''équipe Nuittea'));
    r := '{}'::jsonb;
  end if;
  perform public._staff_log(case when p_ok then 'paiement_abonnement_valide' else 'paiement_abonnement_rejete' end, 'organization', v_org::text, jsonb_build_object('reference', p_reference, 'motif', p_reason));
  return r;
end $$;

create or replace function public.admin_plan_save(p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare v_before jsonb;
begin
  if not public.staff_can('settings') then raise exception 'Accès refusé.'; end if;
  select to_jsonb(x) - 'features' into v_before from public.plans x where id = p_id;
  if v_before is null then raise exception 'Formule introuvable.'; end if;
  update public.plans set
    monthly_price = coalesce((p->>'monthly_price')::int, monthly_price),
    yearly_price = case when p ? 'yearly_price' then nullif(p->>'yearly_price', '')::int else yearly_price end,
    max_rooms = case when p ? 'max_rooms' then nullif(p->>'max_rooms', '')::int else max_rooms end,
    max_users = case when p ? 'max_users' then nullif(p->>'max_users', '')::int else max_users end,
    max_properties = case when p ? 'max_properties' then nullif(p->>'max_properties', '')::int else max_properties end,
    trial_days = coalesce(nullif(p->>'trial_days', '')::int, trial_days),
    is_active = coalesce((p->>'is_active')::boolean, is_active),
    is_public = coalesce((p->>'is_public')::boolean, is_public),
    features = coalesce(p->'features', features),
    updated_at = now()
  where id = p_id;
  perform public._staff_log('formule_parametree', 'plan', p_id::text, jsonb_build_object('avant', v_before, 'modif', p));
end $$;

create or replace function public.admin_provider_set(p_code text, p_active boolean)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('settings') then raise exception 'Accès refusé.'; end if;
  update public.payment_providers set is_active = p_active where code = p_code;
  if not found then raise exception 'Moyen de paiement inconnu.'; end if;
  perform public._staff_log(case when p_active then 'moyen_paiement_active' else 'moyen_paiement_desactive' end, 'provider', p_code, '{}');
end $$;

revoke all on function public.admin_billing_data(), public.admin_payment_decide(uuid, boolean, text, text), public.admin_plan_save(uuid, jsonb), public.admin_provider_set(text, boolean) from public, anon;
grant execute on function public.admin_billing_data(), public.admin_payment_decide(uuid, boolean, text, text), public.admin_plan_save(uuid, jsonb), public.admin_provider_set(text, boolean) to authenticated;
