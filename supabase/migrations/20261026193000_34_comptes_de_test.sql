-- 34 · Comptes de test (administrateur plateforme)
-- • organizations.is_test : un client de test n'apparaît jamais dans la recherche NAYA (sa fiche reste visible par lien direct, pour essayer).
-- • Le tableau de bord distingue les comptes de test. Migration additive, sans modification de données.

alter table public.organizations add column if not exists is_test boolean not null default false;

-- Recherche NAYA : exclut les comptes de test
create or replace function public.market_search(p_city text default null, p_check_in date default null, p_check_out date default null, p_adults int default 1)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_dates boolean := p_check_in is not null and p_check_out is not null and p_check_out > p_check_in and p_check_in >= current_date;
begin
  if p_check_out is not null and p_check_in is not null and p_check_out - p_check_in > 60 then v_dates := false; end if;
  return coalesce((select jsonb_agg(x order by (x->>'available')::boolean desc, (x->>'price_from')::numeric nulls last) from (
    select jsonb_build_object('slug', e.slug, 'name', coalesce(e.public_name, e.name), 'city', e.city, 'tagline', e.public_tagline,
      'cover', coalesce(e.public_cover_url, (select r.photos->>0 from public.rooms r where r.establishment_id = e.id and r.is_active and jsonb_array_length(coalesce(r.photos, '[]'::jsonb)) > 0 limit 1)),
      'photos', coalesce(e.public_photos, '[]'::jsonb), 'auto_confirm', m.auto_confirm,
      'rating', (select round(avg(v.rating), 1) from public.reviews v where v.establishment_id = e.id and v.status = 'submitted' and v.is_published),
      'reviews', (select count(*) from public.reviews v where v.establishment_id = e.id and v.status = 'submitted' and v.is_published),
      'price_from', (select min(r.base_rate) from public.rooms r where r.establishment_id = e.id and r.is_active and r.base_rate > 0),
      'available', case when v_dates then exists (select 1 from public.rooms r where r.establishment_id = e.id and r.is_active and r.base_rate > 0
          and public._market_room(e.id, coalesce(nullif(trim(r.room_type), ''), 'Chambre'), p_check_in, p_check_out, p_adults) is not null) else true end,
      'nights', case when v_dates then p_check_out - p_check_in end) x
    from public.establishments e join public.marketplace_listings m on m.establishment_id = e.id
    where m.listed and e.is_active and e.slug is not null and public.org_can_write(e.organization_id)
      and not exists (select 1 from public.organizations ot where ot.id = e.organization_id and ot.is_test)
      and (p_city is null or p_city = '' or e.city ilike '%' || p_city || '%' or coalesce(e.public_name, e.name) ilike '%' || p_city || '%')
  ) s), '[]'::jsonb);
end $$;


-- Vue d'ensemble administrateur : ajoute l'indicateur de test
create or replace function public.admin_set_test(p_org uuid, p_test boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  update public.organizations set is_test = p_test where id = p_org;
  insert into public.subscription_events (organization_id, event_type, details, actor_id)
  values (p_org, case when p_test then 'admin_marked_test' else 'admin_unmarked_test' end, '{}'::jsonb, auth.uid());
end $$;
revoke execute on function public.admin_set_test(uuid, boolean) from public, anon;
grant execute on function public.admin_set_test(uuid, boolean) to authenticated;

create or replace function public.admin_orgs_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
    select jsonb_build_object(
      'id', o.id, 'name', o.name, 'is_test', o.is_test, 'created_at', o.created_at, 'staff_code', o.staff_code,
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

