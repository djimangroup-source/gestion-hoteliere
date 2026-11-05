-- 49 · Centre de contrôle administrateur (lecture seule)
-- Une fonction réservée à l'administrateur plateforme, qui regroupe les indicateurs
-- du centre de contrôle. Aucune table modifiée, aucune donnée écrite.

create or replace function public.admin_cockpit()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare r jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;

  select jsonb_build_object(
    'signups_month', (select count(*) from public.organizations o where not o.is_test and o.created_at >= date_trunc('month', now())),
    'signups_prev', (select count(*) from public.organizations o where not o.is_test
                       and o.created_at >= date_trunc('month', now()) - interval '1 month' and o.created_at < date_trunc('month', now())),

    'revenue_6m', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'total', coalesce(t.total, 0)) order by m), '[]'::jsonb)
                   from generate_series(date_trunc('month', now()) - interval '5 months', date_trunc('month', now()), interval '1 month') m
                   left join (select date_trunc('month', coalesce(p.paid_at, p.created_at)) mm, sum(p.amount) total
                              from public.payments p join public.organizations o on o.id = p.organization_id
                              where p.status = 'succeeded' and not o.is_test group by 1) t on t.mm = m),

    'by_type', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
                  select coalesce(e.property_type, 'hotel') k, count(distinct e.organization_id) n
                  from public.establishments e join public.organizations o on o.id = e.organization_id
                  where e.is_active and not o.is_test group by 1) x),

    'by_city', (select coalesce(jsonb_agg(jsonb_build_object('city', city, 'count', n) order by n desc), '[]'::jsonb) from (
                  select coalesce(nullif(trim(e.city), ''), 'Non renseignée') city, count(distinct e.organization_id) n
                  from public.establishments e join public.organizations o on o.id = e.organization_id
                  where e.is_active and not o.is_test group by 1 order by 2 desc limit 6) x),

    'near_limit', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'plan', p.name, 'rooms', rc.n, 'max', p.max_rooms) order by rc.n desc), '[]'::jsonb)
                   from public.organizations o
                   join public.subscriptions s on s.organization_id = o.id
                   join public.plans p on p.id = s.plan_id
                   join lateral (select count(*) n from public.rooms rm where rm.organization_id = o.id and rm.is_active) rc on true
                   where not o.is_test and p.max_rooms is not null and p.max_rooms > 0 and rc.n >= ceil(p.max_rooms * 0.8)),

    'never_used', (select count(*) from public.organizations o where not o.is_test
                     and o.created_at < now() - interval '3 days'
                     and not exists (select 1 from public.reservations rr where rr.organization_id = o.id)),

    'active_today', (select count(distinct a.organization_id) from public.audit_log a join public.organizations o on o.id = a.organization_id
                       where not o.is_test and a.created_at >= date_trunc('day', now())),
    'active_week', (select count(distinct a.organization_id) from public.audit_log a join public.organizations o on o.id = a.organization_id
                      where not o.is_test and a.created_at > now() - interval '7 days'),

    'naya_today', (select count(*) from public.reservations rr where rr.source = 'naya' and rr.created_at >= date_trunc('day', now())),
    'naya_month', (select count(*) from public.reservations rr where rr.source = 'naya' and rr.created_at >= date_trunc('month', now())),
    'naya_cancel_month', (select count(*) from public.reservations rr where rr.source = 'naya' and rr.status = 'cancelled' and rr.created_at >= date_trunc('month', now())),
    'travelers', (select count(distinct f.user_id) from public.traveler_favorites f),

    'listings_incomplete', (select count(*) from public.establishments e join public.organizations o on o.id = e.organization_id
                              where e.is_active and not o.is_test and (e.latitude is null or coalesce(e.public_cover_url, '') = '' or coalesce(array_length(e.amenities, 1), 0) = 0)),

    'low_reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'org', o.name, 'org_id', o.id, 'rating', v.rating, 'comment', left(coalesce(v.comment, ''), 140), 'at', v.submitted_at) order by v.submitted_at desc), '[]'::jsonb)
                    from public.reviews v join public.organizations o on o.id = v.organization_id
                    where v.status = 'submitted' and v.rating <= 2 and v.submitted_at > now() - interval '30 days'),

    'localities_pending', (select count(*) from public.localities l where l.status <> 'valide'),

    'requests_24h', (select count(*) from public.rate_events re where re.created_at > now() - interval '24 hours'),
    'requests_by_kind', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
                           select split_part(re.key, ':', 1) k, count(*) n from public.rate_events re
                           where re.created_at > now() - interval '24 hours' group by 1) x),
    'id_docs_30d', (select count(*) from public.id_doc_events d where d.created_at > now() - interval '30 days'),

    'journal', (select coalesce(jsonb_agg(j order by j->>'at' desc), '[]'::jsonb) from (select j from (
                  (select jsonb_build_object('at', o.created_at, 'kind', 'signup', 'text', 'Nouveau compte : ' || o.name, 'org_id', o.id) j
                     from public.organizations o where not o.is_test order by o.created_at desc limit 10)
                  union all
                  (select jsonb_build_object('at', coalesce(p.paid_at, p.created_at), 'kind', case when p.status = 'succeeded' then 'payment' else 'payment_pending' end,
                          'text', case when p.status = 'succeeded' then 'Paiement reçu : ' else 'Paiement à valider : ' end || o.name || ' · ' || p.amount::bigint || ' F', 'org_id', o.id)
                     from public.payments p join public.organizations o on o.id = p.organization_id
                     where not o.is_test order by coalesce(p.paid_at, p.created_at) desc limit 10)
                  union all
                  (select jsonb_build_object('at', s.updated_at, 'kind', 'suspended', 'text', 'Compte suspendu : ' || o.name, 'org_id', o.id)
                     from public.subscriptions s join public.organizations o on o.id = s.organization_id
                     where s.status = 'suspended' and not o.is_test order by s.updated_at desc limit 10)
                  union all
                  (select jsonb_build_object('at', v.submitted_at, 'kind', 'review', 'text', 'Avis ' || v.rating || '/5 : ' || o.name, 'org_id', o.id)
                     from public.reviews v join public.organizations o on o.id = v.organization_id
                     where v.status = 'submitted' and not o.is_test order by v.submitted_at desc limit 10)
                ) u where j->>'at' is not null order by j->>'at' desc limit 12) w)
  ) into r;
  return r;
end $$;

revoke execute on function public.admin_cockpit() from public, anon;
grant execute on function public.admin_cockpit() to authenticated;
