-- 54 · Page Analyse : indicateurs complémentaires (remises, clients, jours de la semaine, ventes annexes, équipe, avis)
-- Fonction de lecture seule. Aucune table ni donnée modifiée.

create or replace function public.analytics_extras(p_org uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare v jsonb;
begin
  if not public.has_org_role(p_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  if not public.org_has_feature(p_org, 'financial_reports') and not public.is_platform_admin() then raise exception 'Les rapports financiers sont inclus dans la formule Pro.' using hint = 'PLAN_FEATURE_FINANCIAL_REPORTS'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Période invalide.'; end if;

  with res as (
    select r.* from public.reservations r
    where r.organization_id = p_org and r.status in ('confirmed','checked_in','checked_out') and r.check_in between p_from and p_to
  ),
  nights as (
    select d::date d from public.reservations r, generate_series(greatest(r.check_in, p_from), least(r.check_out - 1, p_to), interval '1 day') d
    where r.organization_id = p_org and r.status in ('confirmed','checked_in','checked_out') and r.check_out > p_from and r.check_in <= p_to
  ),
  firsts as (
    select guest_id, min(check_in) first_in from public.reservations
    where organization_id = p_org and guest_id is not null and status in ('confirmed','checked_in','checked_out') group by guest_id
  ),
  xs as (
    select x.label, x.category, x.qty, x.total, coalesce(i.unit_cost, null) unit_cost from public.extra_sales x left join public.extra_items i on i.id = x.item_id
    where x.organization_id = p_org and x.status <> 'cancelled' and x.created_at >= p_from and x.created_at < p_to + 1
  )
  select jsonb_build_object(
    'reservations', (select count(*) from res),
    'discounts', (select coalesce(sum(discount), 0) from res),
    'discount_count', (select count(*) from res where discount > 0),
    'avg_stay', (select coalesce(round(avg(check_out - check_in)::numeric, 1), 0) from res),
    'avg_lead', (select coalesce(round(avg(greatest(check_in - created_at::date, 0))::numeric, 1), 0) from res),
    'cancel_value', (select coalesce(sum(total_amount), 0) from public.reservations where organization_id = p_org and status in ('cancelled','no_show') and check_in between p_from and p_to),
    'weekday', (select coalesce(jsonb_object_agg(dw, c), '{}'::jsonb) from (select extract(isodow from d)::int dw, count(*) c from nights group by 1) w),
    'guests_new', (select count(distinct r.guest_id) from res r join firsts f on f.guest_id = r.guest_id where f.first_in >= p_from),
    'guests_returning', (select count(distinct r.guest_id) from res r join firsts f on f.guest_id = r.guest_id where f.first_in < p_from),
    'returning_revenue', (select coalesce(sum(r.total_amount), 0) from res r join firsts f on f.guest_id = r.guest_id where f.first_in < p_from),
    'top_guests', (select coalesce(jsonb_agg(t order by (t->>'revenue')::numeric desc), '[]'::jsonb) from (
        select jsonb_build_object('name', max(r.guest_name), 'stays', count(*), 'nights', sum(r.check_out - r.check_in), 'revenue', sum(r.total_amount)) t
        from res r group by coalesce(r.guest_id::text, lower(r.guest_name)) order by sum(r.total_amount) desc limit 10) g),
    'nationalities', (select coalesce(jsonb_object_agg(n, c), '{}'::jsonb) from (select coalesce(nullif(trim(g.nationality), ''), 'Non renseignée') n, count(distinct g.id) c from res r join public.guests g on g.id = r.guest_id group by 1 order by 2 desc limit 8) z),
    'by_staff', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'count', c, 'revenue', rv) order by rv desc), '[]'::jsonb) from (
        select case when r.created_by is null then 'En ligne / automatique' when m.id is null then 'Ancien membre'
               else coalesce(m.display_name, m.username, case m.role when 'owner' then 'Propriétaire' when 'admin' then 'Administrateur' when 'manager' then 'Gérant' when 'receptionist' then 'Réceptionniste' when 'accountant' then 'Comptable' else 'Membre' end) end nm, count(*) c, sum(r.total_amount) rv
        from res r left join public.organization_members m on m.user_id = r.created_by and m.organization_id = p_org group by 1) s),
    'extras_revenue', (select coalesce(sum(total), 0) from xs),
    'extras_cost', (select coalesce(sum(qty * unit_cost), 0) from xs where unit_cost is not null),
    'extras_by_item', (select coalesce(jsonb_agg(jsonb_build_object('label', label, 'qty', q, 'revenue', rv, 'cost', cs) order by rv desc), '[]'::jsonb) from (
        select label, sum(qty) q, sum(total) rv, sum(qty * unit_cost) cs from xs group by label order by sum(total) desc limit 15) e),
    'extras_by_cat', (select coalesce(jsonb_object_agg(category, rv), '{}'::jsonb) from (select category, sum(total) rv from xs group by category) c),
    'gaps', (select count(*) from public.cash_sessions where organization_id = p_org and status = 'closed' and gap_reason is not null and closed_at >= p_from and closed_at < p_to + 1),
    'rating', (select round(avg(rating)::numeric, 1) from public.reviews where organization_id = p_org and rating is not null and submitted_at >= p_from and submitted_at < p_to + 1),
    'rating_count', (select count(*) from public.reviews where organization_id = p_org and rating is not null and submitted_at >= p_from and submitted_at < p_to + 1),
    'fixed_monthly', (select coalesce(sum(amount), 0) from public.recurring_charges rc join public.establishments e on e.id = rc.establishment_id where e.organization_id = p_org and rc.is_active)
  ) into v;
  return v;
end $$;
revoke execute on function public.analytics_extras(uuid, date, date) from public, anon;
grant execute on function public.analytics_extras(uuid, date, date) to authenticated;
