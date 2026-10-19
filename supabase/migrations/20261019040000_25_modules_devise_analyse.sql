-- Horus Hotel — Migration 25 :
-- • modules affichés au choix (le menu s'allège, aucune donnée ni fonction n'est supprimée) ;
-- • devise d'affichage par organisation ;
-- • analyse du résultat (revenus − dépenses) mois par mois.

alter table public.organizations
  add column if not exists enabled_modules jsonb check (enabled_modules is null or jsonb_typeof(enabled_modules) = 'array'),
  add column if not exists display_currency text not null default 'XOF'
    check (display_currency in ('XOF','XAF','GNF','EUR','USD','MAD','NGN','GHS','CDF','MGA'));

create or replace function public.business_analytics(p_org uuid, p_months int default 6)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_months int := least(greatest(coalesce(p_months, 6), 1), 24);
        v_start date := (date_trunc('month', now()) - make_interval(months => v_months - 1))::date;
        v_cur date := date_trunc('month', now())::date;
        v_rooms numeric;
begin
  if not public.has_org_role(p_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  select count(*) into v_rooms from public.rooms where organization_id = p_org and is_active;
  return (
  with months as (select generate_series(v_start, v_cur, interval '1 month')::date m),
  nights as (
    select date_trunc('month', d)::date m, r.nightly_rate - case when (r.check_out - r.check_in) > 0 then r.discount / (r.check_out - r.check_in) else 0 end rev
    from public.reservations r cross join lateral generate_series(r.check_in, r.check_out - 1, interval '1 day') d
    where r.organization_id = p_org and r.status in ('confirmed','checked_in','checked_out') and r.check_out > v_start and r.check_in <= (v_cur + interval '1 month')::date
  ),
  resto as (select date_trunc('month', created_at)::date m, outlet, total, cost_total from public.pos_sales where organization_id = p_org and status = 'paid' and created_at >= v_start),
  other_in as (select date_trunc('month', created_at)::date m, coalesce(category, 'Autres entrées') category, amount from public.cash_movements
               where organization_id = p_org and kind = 'income' and coalesce(category, '') not in ('Restaurant','Bar') and created_at >= v_start),
  exp as (
    select date_trunc('month', paid_on)::date m, category, nature, amount from public.expenses
     where organization_id = p_org and status in ('paid','pending') and paid_on >= v_start
    union all
    select date_trunc('month', created_at)::date, coalesce(category, 'Caisse'), 'operational', amount from public.cash_movements
     where organization_id = p_org and kind = 'expense' and expense_id is null and created_at >= v_start
  ),
  series as (
    select mo.m,
      coalesce((select round(sum(rev)) from nights n where n.m = mo.m), 0) rooms,
      coalesce((select count(*) from nights n where n.m = mo.m), 0) sold,
      coalesce((select sum(total) from resto x where x.m = mo.m), 0) resto,
      coalesce((select sum(cost_total) from resto x where x.m = mo.m), 0) resto_cost,
      coalesce((select sum(amount) from other_in o where o.m = mo.m), 0) other,
      coalesce((select sum(amount) from exp e where e.m = mo.m), 0) expenses,
      (least((mo.m + interval '1 month')::date, (now() + interval '1 day')::date) - mo.m) days
    from months mo
  )
  select jsonb_build_object(
    'currency', (select display_currency from public.organizations where id = p_org),
    'rooms_count', v_rooms,
    'series', (select jsonb_agg(jsonb_build_object('m', m, 'rooms', rooms, 'resto', resto, 'other', other, 'expenses', expenses + resto_cost,
                 'expenses_only', expenses, 'resto_cost', resto_cost,
                 'revenue', rooms + resto + other, 'result', rooms + resto + other - expenses - resto_cost, 'sold', sold,
                 'occupancy', case when v_rooms * days > 0 then round(sold * 100.0 / (v_rooms * days), 1) else 0 end,
                 'adr', case when sold > 0 then round(rooms / sold) else 0 end) order by m) from series),
    'expenses_by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'amount', t) order by t desc), '[]') from (select category, sum(amount) t from exp where m = v_cur group by category) x),
    'expenses_prev_by_category', (select coalesce(jsonb_object_agg(category, t), '{}') from (select category, sum(amount) t from exp where m = (v_cur - interval '1 month')::date group by category) x),
    'other_by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'amount', t) order by t desc), '[]') from (select category, sum(amount) t from other_in where m = v_cur group by category) x),
    'resto_by_outlet', (select coalesce(jsonb_object_agg(outlet, t), '{}') from (select outlet, sum(total) t from resto where m = v_cur group by outlet) x),
    'top_products', (select coalesce(jsonb_agg(x order by x.amount desc), '[]') from (
        select si.name, sum(si.qty) qty, sum(si.qty * si.unit_price) amount, sum(si.qty * (si.unit_price - si.unit_cost)) margin
        from public.pos_sale_items si join public.pos_sales s on s.id = si.sale_id
        where s.organization_id = p_org and s.status = 'paid' and s.created_at >= v_cur group by si.name order by 3 desc limit 5) x),
    'budget_over', (select coalesce(jsonb_agg(jsonb_build_object('category', b.category, 'budget', b.monthly_amount, 'spent', coalesce(e.t, 0)) order by coalesce(e.t, 0) - b.monthly_amount desc), '[]')
        from public.expense_budgets b left join (select category, sum(amount) t from exp where m = v_cur group by category) e on e.category = b.category
        where b.organization_id = p_org and b.monthly_amount > 0 and coalesce(e.t, 0) > b.monthly_amount),
    'unpaid_total', (select coalesce(sum(balance), 0) from public.reservation_balances where organization_id = p_org and balance > 0 and status in ('checked_in','checked_out')),
    'low_stock', (select count(*) from public.products where organization_id = p_org and is_active and track_stock and stock_qty <= alert_qty),
    'due_expenses', (select coalesce(sum(amount), 0) from public.expenses where organization_id = p_org and status = 'due' and due_date <= (now() + interval '7 days')::date)
  ));
end $function$;
revoke execute on function public.business_analytics(uuid, int) from public, anon;
grant execute on function public.business_analytics(uuid, int) to authenticated;
