-- Horus Hotel — Migration 14 : rapport financier sur une période.
-- Appliquée le 17/10/2026 (version 20261017133415).
-- Test (annulé) : 2 chambres, séjour 3 nuits à 20 000 F avec 6 000 F de remise, période de 10 jours
-- → 3 nuits vendues, CA 54 000 F, occupation 15 %, ADR 18 000 F, RevPAR 2 700 F, impayé 24 000 F ; rôle ménage refusé.

-- Chiffre d'affaires hébergement (au prorata des nuits de la période), occupation, ADR, RevPAR, encaissements,
-- dépenses, impayés, répartition par origine et par chambre, série quotidienne.
create or replace function public.financial_report(p_org uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_days int;
begin
  if not public.has_org_role(p_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Période invalide.'; end if;
  v_days := p_to - p_from + 1;
  if v_days > 366 then raise exception 'Période limitée à 366 jours.'; end if;

  with days as (select generate_series(p_from, p_to, interval '1 day')::date d),
  rooms as (select count(*)::numeric n from public.rooms where organization_id = p_org and is_active),
  -- une ligne par nuit vendue dans la période (prix net de la remise répartie sur les nuits)
  nights as (
    select d.d, r.id res_id, r.room_id, r.source,
           r.nightly_rate - case when (r.check_out - r.check_in) > 0 then r.discount / (r.check_out - r.check_in) else 0 end as rev
    from public.reservations r join days d on d.d >= r.check_in and d.d < r.check_out
    where r.organization_id = p_org and r.status in ('confirmed','checked_in','checked_out')
  ),
  cash as (
    select created_at::date d, kind, method, amount from public.cash_movements
    where organization_id = p_org and created_at >= p_from and created_at < p_to + 1
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
    'expenses', (select coalesce(sum(amount), 0) from cash where kind = 'expense'),
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
revoke execute on function public.financial_report(uuid, date, date) from public, anon;
grant execute on function public.financial_report(uuid, date, date) to authenticated;

/* ROLLBACK :
drop function if exists public.financial_report(uuid, date, date);
*/
