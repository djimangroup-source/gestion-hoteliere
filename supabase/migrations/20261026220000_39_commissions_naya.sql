-- 39 · Commissions NAYA : dû, payé, solde
-- • Une commission est due dès que le séjour NAYA a commencé (arrivée passée ou du jour) et n'est ni annulé ni « non présenté ».
-- • naya_commission_payments : règlements reçus par la plateforme (saisis par l'administrateur).
-- • platform_settings : instructions de paiement affichées aux partenaires (numéro Wave / Orange Money…).
-- • naya_commission_balance(org) : solde du partenaire (lisible par ses membres et par l'administrateur).
-- • admin_naya_partners() / admin_record_commission_payment() : tableau de bord administrateur.
-- Migration additive. Aucune donnée existante n'est modifiée.

create table if not exists public.naya_commission_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  method text not null default 'wave' check (method in ('cash','orange_money','mtn_money','moov_money','wave','card','bank_transfer')),
  reference text check (reference is null or length(reference) <= 80),
  note text check (note is null or length(note) <= 300),
  paid_at timestamptz not null default now(),
  recorded_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists naya_commission_payments_org on public.naya_commission_payments (organization_id, paid_at desc);
alter table public.naya_commission_payments enable row level security;
drop policy if exists ncp_select on public.naya_commission_payments;
create policy ncp_select on public.naya_commission_payments for select using (public.is_org_member(organization_id) or public.is_platform_admin());
grant select on public.naya_commission_payments to authenticated;

create table if not exists public.platform_settings (
  key text primary key check (length(key) <= 60),
  value text check (value is null or length(value) <= 1000),
  updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;
drop policy if exists ps_read on public.platform_settings;
drop policy if exists ps_write on public.platform_settings;
create policy ps_read on public.platform_settings for select using (auth.uid() is not null);
create policy ps_write on public.platform_settings for all using (public.is_platform_admin()) with check (public.is_platform_admin());
grant select, insert, update on public.platform_settings to authenticated;
insert into public.platform_settings (key, value) values ('naya_payment_instructions', null), ('naya_payment_delay_days', '7') on conflict (key) do nothing;

-- Solde d'un partenaire
create or replace function public.naya_commission_balance(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_earned numeric; v_paid numeric; v_overdue numeric; v_delay int; v_last timestamptz;
begin
  if not (public.is_org_member(p_org) or public.is_platform_admin()) then raise exception 'Accès refusé.'; end if;
  select coalesce(nullif(value, '')::int, 7) into v_delay from public.platform_settings where key = 'naya_payment_delay_days';
  v_delay := coalesce(v_delay, 7);
  select coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)), 0),
         coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)) filter (where r.check_in < current_date - v_delay), 0)
    into v_earned, v_overdue
    from public.reservations r
   where r.organization_id = p_org and r.source = 'naya' and r.status in ('confirmed', 'checked_in', 'checked_out') and r.check_in <= current_date;
  select coalesce(sum(amount), 0), max(paid_at) into v_paid, v_last from public.naya_commission_payments where organization_id = p_org;
  return jsonb_build_object('earned', v_earned, 'paid', v_paid, 'balance', greatest(v_earned - v_paid, 0),
    'overdue', greatest(v_overdue - v_paid, 0), 'credit', greatest(v_paid - v_earned, 0), 'last_payment', v_last, 'delay_days', v_delay,
    'instructions', (select value from public.platform_settings where key = 'naya_payment_instructions'),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('amount', amount, 'method', method, 'reference', reference, 'paid_at', paid_at) order by paid_at desc)
                          from (select * from public.naya_commission_payments where organization_id = p_org order by paid_at desc limit 20) p), '[]'::jsonb));
end $$;

-- Tableau de bord administrateur : tous les partenaires NAYA
create or replace function public.admin_naya_partners()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_delay int;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  select coalesce(nullif(value, '')::int, 7) into v_delay from public.platform_settings where key = 'naya_payment_delay_days';
  v_delay := coalesce(v_delay, 7);
  return coalesce((select jsonb_agg(x order by (x->>'balance')::numeric desc, x->>'name') from (
    select jsonb_build_object(
      'id', o.id, 'name', o.name, 'is_test', o.is_test,
      'phone', (select coalesce(e.public_whatsapp, e.public_phone, e.phone) from public.establishments e where e.organization_id = o.id and coalesce(e.public_whatsapp, e.public_phone, e.phone) is not null order by e.created_at limit 1),
      'email', (select u.email from auth.users u where u.id = o.created_by),
      'listed', exists (select 1 from public.marketplace_listings m where m.organization_id = o.id and m.listed),
      'commission_pct', (select max(m.commission_pct) from public.marketplace_listings m where m.organization_id = o.id),
      'bookings', (select count(*) from public.reservations r where r.organization_id = o.id and r.source = 'naya'),
      'bookings_done', (select count(*) from public.reservations r where r.organization_id = o.id and r.source = 'naya' and r.status in ('confirmed','checked_in','checked_out') and r.check_in <= current_date),
      'revenue', (select coalesce(sum(r.total_amount), 0) from public.reservations r where r.organization_id = o.id and r.source = 'naya' and r.status in ('confirmed','checked_in','checked_out') and r.check_in <= current_date),
      'earned', ea.earned, 'overdue_raw', ea.overdue, 'paid', pa.paid,
      'balance', greatest(ea.earned - pa.paid, 0), 'overdue', greatest(ea.overdue - pa.paid, 0),
      'last_payment', pa.last_paid) x
    from public.organizations o
    cross join lateral (select coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)), 0) earned,
                               coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)) filter (where r.check_in < current_date - v_delay), 0) overdue
                          from public.reservations r where r.organization_id = o.id and r.source = 'naya' and r.status in ('confirmed','checked_in','checked_out') and r.check_in <= current_date) ea
    cross join lateral (select coalesce(sum(p.amount), 0) paid, max(p.paid_at) last_paid from public.naya_commission_payments p where p.organization_id = o.id) pa
    where exists (select 1 from public.marketplace_listings m where m.organization_id = o.id)
       or exists (select 1 from public.reservations r where r.organization_id = o.id and r.source = 'naya')
  ) t), '[]'::jsonb);
end $$;

create or replace function public.admin_record_commission_payment(p_org uuid, p_amount numeric, p_method text default 'wave', p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''administrateur plateforme.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Montant invalide.'; end if;
  insert into public.naya_commission_payments (organization_id, amount, method, reference, note)
  values (p_org, p_amount, coalesce(p_method, 'wave'), nullif(trim(coalesce(p_reference, '')), ''), nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  insert into public.subscription_events (organization_id, event_type, details, actor_id)
  values (p_org, 'naya_commission_paid', jsonb_build_object('amount', p_amount, 'method', p_method, 'reference', p_reference), auth.uid());
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

revoke execute on function public.naya_commission_balance(uuid), public.admin_naya_partners(), public.admin_record_commission_payment(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.naya_commission_balance(uuid), public.admin_naya_partners(), public.admin_record_commission_payment(uuid, numeric, text, text, text) to authenticated;
