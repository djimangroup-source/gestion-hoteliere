-- Horus Hotel — Migration 19 : trois formules (Essentiel, Pro, Business) à fonctions débloquées progressivement.
-- Validé par le propriétaire de la plateforme le 18/10/2026.
-- • Chambres illimitées partout. Standard, Premium et Enterprise sont retirées de la vente (non publiques) mais
--   restent actives pour les abonnés existants (NOEL LUXURY garde Premium jusqu'à son échéance, sans perte de fonction).
-- • Les fonctions verrouillées sont aussi bloquées côté serveur.

-- Fonctions vendues : clés utilisées par l'application
--   socle      : reception, reservations, clients, billing, payments, cash, housekeeping, basic_reports, users, pdf_export
--   Pro        : online_booking, expenses, owner_control, financial_reports, excel_export, notifications, multi_property
--   Business   : priority_support, training

update public.plans set
  description = 'L’essentiel pour gérer la réception, la caisse et les factures.',
  monthly_price = 5500, yearly_price = 55000, max_rooms = null, max_users = 2, max_properties = 1,
  features = '["reception","reservations","clients","billing","payments","cash","housekeeping","basic_reports","users","pdf_export"]'::jsonb,
  is_public = true, is_recommended = false, sort_order = 10, updated_at = now()
where slug = 'essentiel';

insert into public.plans (name, slug, description, monthly_price, yearly_price, currency, max_rooms, max_users, max_properties, features, is_trial, is_public, is_recommended, is_quote_based, sort_order, is_active)
values ('Pro', 'pro', 'Pilotez et contrôlez votre activité : réservation en ligne, dépenses, alertes, rapports.', 9500, 95000, 'XOF', null, 6, 10,
  '["reception","reservations","clients","billing","payments","cash","housekeeping","basic_reports","users","pdf_export","online_booking","expenses","owner_control","financial_reports","excel_export","notifications","multi_property"]'::jsonb,
  false, true, true, false, 20, true)
on conflict (slug) do nothing;

update public.plans set
  description = 'Pour les grandes équipes et les groupes : utilisateurs et établissements illimités, accompagnement prioritaire.',
  monthly_price = 15000, yearly_price = 150000, max_rooms = null, max_users = null, max_properties = null,
  features = '["reception","reservations","clients","billing","payments","cash","housekeeping","basic_reports","users","pdf_export","online_booking","expenses","owner_control","financial_reports","excel_export","notifications","multi_property","priority_support","training"]'::jsonb,
  is_public = true, is_recommended = false, is_quote_based = false, sort_order = 30, updated_at = now()
where slug = 'business';

-- Anciennes formules : retirées de la vente, les abonnés existants gardent tout (nouvelles clés ajoutées)
update public.plans set is_public = false, is_recommended = false,
  features = features || '["online_booking","expenses","owner_control","financial_reports","multi_property","priority_support","training"]'::jsonb, updated_at = now()
where slug in ('standard','premium','enterprise');

-- Essai : toutes les fonctions pour découvrir Pro et Business
update public.plans set max_rooms = null, max_users = 6, max_properties = 1,
  features = features || '["online_booking","expenses","owner_control","financial_reports","excel_export","notifications","multi_property"]'::jsonb, updated_at = now()
where slug = 'essai';

-- ===== Blocage côté serveur =====
create or replace function public.require_feature()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_label text := coalesce(tg_argv[1], 'Cette fonction');
begin
  if public.is_service_context() then return coalesce(new, old); end if;
  select organization_id into v_org from public.establishments where id = coalesce(new.establishment_id, old.establishment_id);
  if not public.org_has_feature(v_org, tg_argv[0]) then
    raise exception '% n’est pas disponible dans votre formule. Passez à la formule Pro pour en profiter.', v_label using errcode = 'P0001', hint = 'PLAN_FEATURE_' || upper(tg_argv[0]);
  end if;
  return coalesce(new, old);
end $$;
revoke execute on function public.require_feature() from public, anon, authenticated;
create trigger trg_000_expense_feature before insert or update on public.expenses for each row execute function public.require_feature('expenses', 'Le module Dépenses');
create trigger trg_000_recurring_feature before insert or update on public.recurring_charges for each row execute function public.require_feature('expenses', 'Le module Dépenses');
create trigger trg_000_budget_feature before insert or update on public.expense_budgets for each row execute function public.require_feature('expenses', 'Le module Dépenses');

-- Page publique : seulement si la formule inclut la réservation en ligne
create or replace function public.resolve_public_establishment(p_slug text)
returns public.establishments language plpgsql stable security definer set search_path = '' as $function$
declare e public.establishments; v text := lower(trim(coalesce(p_slug, '')));
begin
  select * into e from public.establishments where slug = v;
  if not found then
    select x.* into e from public.establishment_slug_history h join public.establishments x on x.id = h.establishment_id where h.old_slug = v;
  end if;
  if not found or not e.public_enabled or not e.is_active or not public.org_can_write(e.organization_id)
     or not public.org_has_feature(e.organization_id, 'online_booking') then return null; end if;
  return e;
end $function$;

-- Rapports financiers : formule Pro et plus
create or replace function public.financial_report(p_org uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_days int;
begin
  if not public.has_org_role(p_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  if not public.org_has_feature(p_org, 'financial_reports') and not public.is_platform_admin() then raise exception 'Les rapports financiers sont inclus dans la formule Pro.' using hint = 'PLAN_FEATURE_FINANCIAL_REPORTS'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Période invalide.'; end if;
  v_days := p_to - p_from + 1;
  if v_days > 366 then raise exception 'Période limitée à 366 jours.'; end if;

  with days as (select generate_series(p_from, p_to, interval '1 day')::date d),
  rooms as (select count(*)::numeric n from public.rooms where organization_id = p_org and is_active),
  nights as (
    select d.d, r.id res_id, r.room_id, r.source,
           r.nightly_rate - case when (r.check_out - r.check_in) > 0 then r.discount / (r.check_out - r.check_in) else 0 end as rev
    from public.reservations r join days d on d.d >= r.check_in and d.d < r.check_out
    where r.organization_id = p_org and r.status in ('confirmed','checked_in','checked_out')
  ),
  cash as (
    select created_at::date d, kind, method, amount, expense_id from public.cash_movements
    where organization_id = p_org and created_at >= p_from and created_at < p_to + 1
  ),
  exp as (
    select category, nature, amount from public.expenses
    where organization_id = p_org and status in ('paid','pending','rejected') and paid_on between p_from and p_to
    union all
    select 'Caisse (ancien)', 'operational', amount from cash where kind = 'expense' and expense_id is null
  ),
  series as (
    select d.d, coalesce(sum(n.rev), 0) rev, count(n.res_id) sold,
           (select coalesce(sum(case when kind in ('payment','income') then amount else 0 end), 0) from cash c where c.d = d.d) cash_in
    from days d left join nights n on n.d = d.d group by d.d order by d.d
  ),
  unpaid as (
    select b.id, b.guest_name, b.guest_phone, b.room_number, b.check_in, b.check_out, b.status, b.total_amount, b.paid, b.balance
    from public.reservation_balances b
    where b.organization_id = p_org and b.balance > 0 and b.status in ('checked_in','checked_out','confirmed') and b.check_in <= p_to
    order by b.check_out
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_days,
    'rooms', (select n from rooms),
    'available_nights', (select n from rooms) * v_days,
    'sold_nights', (select count(*) from nights),
    'room_revenue', (select coalesce(round(sum(rev)), 0) from nights),
    'occupancy_pct', case when (select n from rooms) * v_days > 0 then round((select count(*) from nights) * 100.0 / ((select n from rooms) * v_days), 1) else 0 end,
    'adr', case when (select count(*) from nights) > 0 then round((select sum(rev) from nights) / (select count(*) from nights)) else 0 end,
    'revpar', case when (select n from rooms) * v_days > 0 then round(coalesce((select sum(rev) from nights), 0) / ((select n from rooms) * v_days)) else 0 end,
    'cash_in', (select coalesce(sum(amount), 0) from cash where kind in ('payment','income')),
    'expenses', (select coalesce(sum(amount), 0) from exp),
    'expenses_fixed', (select coalesce(sum(amount), 0) from exp where nature = 'fixed'),
    'expenses_by_category', (select coalesce(jsonb_object_agg(category, t), '{}'::jsonb) from (select category, sum(amount) t from exp group by category) x),
    'deposits', (select coalesce(sum(amount), 0) from cash where kind = 'deposit'),
    'refunds', (select coalesce(sum(amount), 0) from cash where kind = 'refund'),
    'by_method', (select coalesce(jsonb_object_agg(method, t), '{}'::jsonb) from (select method, sum(case when kind in ('payment','income') then amount else -amount end) t from cash group by method) x),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'nights', c, 'revenue', round(rv)) order by rv desc), '[]'::jsonb) from (select source, count(*) c, sum(rev) rv from nights group by source) x),
    'by_room', (select coalesce(jsonb_agg(jsonb_build_object('room', number, 'nights', c, 'revenue', round(rv)) order by rv desc), '[]'::jsonb)
                from (select rm.number, count(n.*) c, coalesce(sum(n.rev), 0) rv from public.rooms rm left join nights n on n.room_id = rm.id where rm.organization_id = p_org and rm.is_active group by rm.number) x),
    'cancellations', (select count(*) from public.reservations where organization_id = p_org and status = 'cancelled' and check_in between p_from and p_to),
    'no_shows', (select count(*) from public.reservations where organization_id = p_org and status = 'no_show' and check_in between p_from and p_to),
    'unpaid_total', (select coalesce(sum(balance), 0) from unpaid),
    'unpaid', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from (select * from unpaid limit 200) u),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'rev', round(rev), 'sold', sold, 'cash', cash_in) order by d), '[]'::jsonb) from series)
  ) into v;
  return v;
end $$;
