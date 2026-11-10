-- 69 · Analyse financière : indicateurs d'une période (lecture seule, aucune donnée modifiée).
create or replace function public._fin_period(p_org uuid, p_est uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_rooms int; v_days int := greatest(p_to - p_from, 1); v jsonb;
begin
  select count(*) into v_rooms from public.rooms where organization_id = p_org and is_active and (p_est is null or establishment_id = p_est);
  with nights as (
    select r.nightly_rate - case when (r.check_out - r.check_in) > 0 then r.discount / (r.check_out - r.check_in) else 0 end rev
    from public.reservations r cross join lateral generate_series(greatest(r.check_in, p_from), least(r.check_out, p_to) - 1, interval '1 day') d
    where r.organization_id = p_org and (p_est is null or r.establishment_id = p_est) and r.status in ('confirmed','checked_in','checked_out') and r.check_out > p_from and r.check_in < p_to),
  xs as (select coalesce(sum(total), 0) t from public.extra_sales where organization_id = p_org and (p_est is null or establishment_id = p_est) and status <> 'cancelled' and created_at >= p_from and created_at < p_to),
  cm as (select kind, method, coalesce(category, '') category, amount, expense_id from public.cash_movements where organization_id = p_org and (p_est is null or establishment_id = p_est) and created_at >= p_from and created_at < p_to),
  ex as (
    select category, nature, amount from public.expenses where organization_id = p_org and (p_est is null or establishment_id = p_est) and status in ('paid','pending') and paid_on >= p_from and paid_on < p_to
    union all select coalesce(nullif(category, ''), 'Caisse'), 'operational', amount from cm where kind = 'expense' and expense_id is null),
  disc as (select coalesce(sum(discount), 0) t from public.reservations where organization_id = p_org and (p_est is null or establishment_id = p_est) and status in ('confirmed','checked_in','checked_out') and check_in >= p_from and check_in < p_to)
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_days, 'rooms', v_rooms,
    'sold', (select count(*) from nights),
    'rev_rooms', (select coalesce(round(sum(rev)), 0) from nights),
    'rev_extras', (select t from xs),
    'rev_other', (select coalesce(sum(amount), 0) from cm where kind = 'income' and category <> 'Ventes annexes'),
    'expenses', (select coalesce(sum(amount), 0) from ex),
    'expenses_fixed', (select coalesce(sum(amount), 0) from ex where nature = 'fixed'),
    'expenses_by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'amount', t) order by t desc), '[]') from (select category, sum(amount) t from ex group by category) z),
    'collected', (select coalesce(sum(case when kind = 'refund' then -amount else amount end), 0) from cm where kind in ('payment','income','refund')),
    'collected_by_method', (select coalesce(jsonb_object_agg(method, t), '{}') from (select coalesce(method, 'autre') method, sum(case when kind = 'refund' then -amount else amount end) t from cm where kind in ('payment','income','refund') group by 1) z),
    'discounts', (select t from disc)
  ) into v;
  return v;
end $$;
revoke all on function public._fin_period(uuid, uuid, date, date) from public, anon, authenticated;

create or replace function public.finance_overview(p_org uuid, p_est uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare n int;
begin
  if not public.has_org_role(p_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > 400 then raise exception 'Période invalide.'; end if;
  n := p_to - p_from;
  return jsonb_build_object(
    'cur', public._fin_period(p_org, p_est, p_from, p_to),
    'prev', public._fin_period(p_org, p_est, p_from - n, p_from),
    'last_year', public._fin_period(p_org, p_est, (p_from - interval '1 year')::date, (p_to - interval '1 year')::date),
    'receivables', (select coalesce(sum(balance), 0) from public.reservation_balances where organization_id = p_org and (p_est is null or establishment_id = p_est) and balance > 0 and status in ('checked_in','checked_out')),
    'receivables_old', (select coalesce(sum(balance), 0) from public.reservation_balances where organization_id = p_org and (p_est is null or establishment_id = p_est) and balance > 0 and status = 'checked_out' and check_out < current_date - 7),
    'upcoming', (select coalesce(sum(total_amount), 0) from public.reservation_balances where organization_id = p_org and (p_est is null or establishment_id = p_est) and status in ('pending','confirmed') and check_in >= current_date and check_in < current_date + 30)
  );
end $$;
revoke all on function public.finance_overview(uuid, uuid, date, date) from public, anon;
grant execute on function public.finance_overview(uuid, uuid, date, date) to authenticated;
