-- 33 · Tableau de bord administrateur plateforme (Emmanuel)
-- Lecture consolidée des clients, changement de formule, pilotage NAYA (commission, mise en ligne).
-- Toutes les fonctions vérifient is_platform_admin() ; aucune donnée n'est modifiée par cette migration.

-- Vue d'ensemble de chaque organisation cliente
create or replace function public.admin_orgs_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
    select jsonb_build_object(
      'id', o.id, 'name', o.name, 'created_at', o.created_at, 'staff_code', o.staff_code,
      'owner_email', (select u.email from auth.users u where u.id = o.created_by),
      'owner_last_login', (select u.last_sign_in_at from auth.users u where u.id = o.created_by),
      'phone', (select coalesce(e.public_whatsapp, e.public_phone, e.phone) from public.establishments e where e.organization_id = o.id and coalesce(e.public_whatsapp, e.public_phone, e.phone) is not null order by e.created_at limit 1),
      'city', (select e.city from public.establishments e where e.organization_id = o.id order by e.created_at limit 1),
      'plan', p.name, 'plan_slug', p.slug, 'monthly_price', p.monthly_price,
      'status', s.status, 'billing_cycle', s.billing_cycle, 'trial_end_at', s.trial_end_at, 'period_end', s.current_period_end, 'suspended_reason', s.suspended_reason,
      'establishments', (select count(*) from public.establishments e where e.organization_id = o.id and e.is_active),
      'rooms', (select count(*) from public.rooms r where r.organization_id = o.id and r.is_active),
      'users', (select count(*) from public.organization_members m where m.organization_id = o.id and m.is_active),
      'reservations_30d', (select count(*) from public.reservations r where r.organization_id = o.id and r.created_at > now() - interval '30 days'),
      'last_activity', (select max(a.created_at) from public.audit_log a where a.organization_id = o.id),
      'paid_total', (select coalesce(sum(pa.amount), 0) from public.payments pa where pa.organization_id = o.id and pa.status = 'succeeded'),
      'naya_listed', exists (select 1 from public.marketplace_listings m where m.organization_id = o.id and m.listed),
      'naya_month', (select count(*) from public.reservations r where r.organization_id = o.id and r.source = 'naya' and r.created_at >= date_trunc('month', now()) and r.status not in ('cancelled','no_show','pending')),
      'establishments_list', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'listed', coalesce(m.listed, false), 'commission_pct', m.commission_pct) order by e.created_at), '[]'::jsonb)
                               from public.establishments e left join public.marketplace_listings m on m.establishment_id = e.id where e.organization_id = o.id and e.is_active)
    ) x
    from public.organizations o
    left join public.subscriptions s on s.organization_id = o.id
    left join public.plans p on p.id = s.plan_id
  ) t), '[]'::jsonb);
end $$;

-- Changer la formule d'un client (offerte, migration, geste commercial)
create or replace function public.admin_change_plan(p_org uuid, p_plan_slug text, p_cycle text default 'monthly', p_months int default 1)
returns void language plpgsql security definer set search_path = '' as $$
declare v_plan public.plans;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  select * into v_plan from public.plans where slug = p_plan_slug and is_active;
  if v_plan.id is null then raise exception 'Formule introuvable ou inactive.'; end if;
  if p_cycle not in ('monthly','yearly') then raise exception 'Périodicité invalide.'; end if;
  if coalesce(p_months, 0) not between 0 and 36 then raise exception 'Durée invalide (0 à 36 mois).'; end if;
  update public.subscriptions set
    plan_id = v_plan.id, billing_cycle = p_cycle, status = 'active', suspended_reason = null,
    current_period_start = now(),
    current_period_end = case when p_months > 0 then greatest(coalesce(current_period_end, now()), now()) + make_interval(months => p_months) else coalesce(current_period_end, now() + interval '1 month') end
  where organization_id = p_org;
  if not found then raise exception 'Abonnement introuvable.'; end if;
  insert into public.subscription_events (organization_id, event_type, details, actor_id)
  values (p_org, 'admin_plan_changed', jsonb_build_object('plan', p_plan_slug, 'cycle', p_cycle, 'months', p_months), auth.uid());
end $$;

-- Retirer / remettre un établissement sur NAYA (modération)
create or replace function public.admin_marketplace_listing(p_establishment uuid, p_listed boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  update public.marketplace_listings set listed = p_listed, updated_at = now() where establishment_id = p_establishment;
  if not found then raise exception 'Cet établissement ne s''est jamais inscrit sur NAYA.'; end if;
  insert into public.audit_log (organization_id, establishment_id, entity, entity_id, action, summary, actor_id, actor_role)
  select organization_id, id, 'reglages', id, case when p_listed then 'naya_on' else 'naya_off' end,
         case when p_listed then 'Remis en ligne sur NAYA par l''administrateur' else 'Retiré de NAYA par l''administrateur' end, auth.uid(), 'platform_admin'
  from public.establishments where id = p_establishment;
end $$;

-- Réservations NAYA et commissions dues, par établissement, pour un mois
create or replace function public.admin_naya_overview(p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m0 date := date_trunc('month', coalesce(p_month, current_date))::date; m1 date := (date_trunc('month', coalesce(p_month, current_date)) + interval '1 month')::date;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  return jsonb_build_object('month', m0,
    'rows', coalesce((select jsonb_agg(x order by (x->>'commission')::numeric desc) from (
      select jsonb_build_object('establishment', e.name, 'organization', o.name, 'organization_id', o.id,
        'bookings', count(r.id), 'pending', count(r.id) filter (where r.status = 'pending'),
        'cancelled', count(r.id) filter (where r.status in ('cancelled','no_show')),
        'revenue', coalesce(sum(r.total_amount) filter (where r.status not in ('pending','cancelled','no_show')), 0),
        'commission', coalesce(sum(r.total_amount * coalesce(r.commission_pct, 0) / 100) filter (where r.status not in ('pending','cancelled','no_show')), 0)) x
      from public.reservations r join public.establishments e on e.id = r.establishment_id join public.organizations o on o.id = r.organization_id
      where r.source = 'naya' and r.check_in >= m0 and r.check_in < m1
      group by e.id, e.name, o.id, o.name) t), '[]'::jsonb),
    'listed', (select count(*) from public.marketplace_listings where listed));
end $$;

revoke execute on function public.admin_orgs_overview() from public, anon;
revoke execute on function public.admin_change_plan(uuid, text, text, int) from public, anon;
revoke execute on function public.admin_marketplace_listing(uuid, boolean) from public, anon;
revoke execute on function public.admin_naya_overview(date) from public, anon;
grant execute on function public.admin_orgs_overview() to authenticated;
grant execute on function public.admin_change_plan(uuid, text, text, int) to authenticated;
grant execute on function public.admin_marketplace_listing(uuid, boolean) to authenticated;
grant execute on function public.admin_naya_overview(date) to authenticated;
