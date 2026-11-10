-- 76 · Reversement aux hôtels des paiements en ligne encaissés par Nuittea.
-- Règles : fonds disponibles au check-in, reversement à la demande (propriétaire ou administrateur),
-- Mobile Money uniquement, frais de retrait 1 %, commission Nuittea due déduite automatiquement.
-- Ajouts uniquement.

create table if not exists public.hotel_payouts (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  requested_by uuid default auth.uid(),
  gross int not null check (gross > 0),
  fee int not null check (fee >= 0),
  commission int not null default 0 check (commission >= 0),
  net int not null check (net >= 0),
  method text not null check (method in ('wave', 'orange_money', 'mtn_money', 'moov_money')),
  account text not null check (length(account) between 8 and 20),
  account_name text not null check (length(trim(account_name)) between 2 and 120),
  status text not null default 'demandee' check (status in ('demandee', 'en_cours', 'payee', 'refusee')),
  reference text, reason text,
  created_at timestamptz not null default now(), processed_at timestamptz, processed_by uuid
);
create index if not exists hotel_payouts_org_idx on public.hotel_payouts (organization_id, created_at desc);
create unique index if not exists hotel_payouts_one_open on public.hotel_payouts (organization_id) where status in ('demandee', 'en_cours');
alter table public.hotel_payouts enable row level security;
create policy hp_select on public.hotel_payouts for select using ((select public.has_org_role(organization_id, array['owner','admin','accountant'])) or (select public.staff_can('finance')));

insert into public.platform_settings (key, value) values ('payout_fee_pct', '1') on conflict (key) do nothing;

-- Soldes d'un hôtel (montants hors frais client)
create or replace function public._payout_amounts(p_org uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  with p as (
    select b.amount, r.status from public.booking_payments b join public.reservations r on r.id = b.reservation_id
    where b.organization_id = p_org and b.status = 'succeeded' and b.environment is distinct from 'sandbox'),
  o as (select coalesce(sum(gross) filter (where status in ('demandee', 'en_cours', 'payee')), 0) engaged,
               coalesce(sum(gross) filter (where status = 'payee'), 0) paid,
               coalesce(sum(gross) filter (where status in ('demandee', 'en_cours')), 0) open
        from public.hotel_payouts where organization_id = p_org)
  select jsonb_build_object(
    'pending', (select coalesce(sum(amount), 0) from p where status in ('pending', 'confirmed')),
    'released', (select coalesce(sum(amount), 0) from p where status in ('checked_in', 'checked_out')),
    'available', greatest((select coalesce(sum(amount), 0) from p where status in ('checked_in', 'checked_out')) - o.engaged, 0),
    'paid', o.paid, 'open', o.open,
    'fee_pct', coalesce(nullif(public._setting('payout_fee_pct'), '')::numeric, 1))
  from o;
$$;
revoke all on function public._payout_amounts(uuid) from public, anon, authenticated;

create or replace function public._commission_due(p_org uuid)
returns int language sql stable security definer set search_path to '' as $$
  select greatest(
    (select coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)), 0) from public.reservations r
      where r.organization_id = p_org and r.source = 'naya' and r.status in ('confirmed', 'checked_in', 'checked_out') and r.check_in <= current_date)
    - (select coalesce(sum(amount), 0) from public.naya_commission_payments where organization_id = p_org)
    - (select coalesce(sum(commission), 0) from public.hotel_payouts where organization_id = p_org and status in ('demandee', 'en_cours')), 0)::int;
$$;
revoke all on function public._commission_due(uuid) from public, anon, authenticated;

create or replace function public.payout_overview(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not (public.has_org_role(p_org, array['owner','admin','accountant']) or public.staff_can('finance')) then raise exception 'Accès refusé.'; end if;
  return public._payout_amounts(p_org) || jsonb_build_object(
    'commission_due', public._commission_due(p_org),
    'can_request', public.has_org_role(p_org, array['owner','admin']),
    'payments', coalesce((select jsonb_agg(z) from (select jsonb_build_object('guest', r.guest_name, 'in', r.check_in, 'out', r.check_out, 'rstatus', r.status,
        'amount', b.amount, 'client_fee', b.client_fee, 'kind', b.kind, 'at', b.paid_at) z
        from public.booking_payments b join public.reservations r on r.id = b.reservation_id
        where b.organization_id = p_org and b.status = 'succeeded' and b.environment is distinct from 'sandbox' order by b.paid_at desc limit 60) q), '[]'),
    'payouts', coalesce((select jsonb_agg(to_jsonb(h) - 'requested_by' - 'processed_by' order by h.created_at desc) from public.hotel_payouts h where h.organization_id = p_org), '[]'));
end $$;

create or replace function public.payout_request(p_org uuid, p_amount int, p_method text, p_account text, p_name text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare a jsonb; v_fee int; v_com int; v_net int; v_acc text := regexp_replace(coalesce(p_account, ''), '[^0-9+]', '', 'g'); v_id uuid; v_num bigint;
begin
  if not public.has_org_role(p_org, array['owner','admin']) then raise exception 'Seuls le propriétaire et l''administrateur peuvent demander un reversement.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payout:' || p_org::text, 0));
  if exists (select 1 from public.hotel_payouts where organization_id = p_org and status in ('demandee', 'en_cours')) then raise exception 'Une demande de reversement est déjà en cours.'; end if;
  a := public._payout_amounts(p_org);
  if coalesce(p_amount, 0) < 1000 then raise exception 'Montant minimum : 1 000 F.'; end if;
  if p_amount > (a->>'available')::int then raise exception 'Montant supérieur au solde disponible (% F).', (a->>'available'); end if;
  if p_method not in ('wave', 'orange_money', 'mtn_money', 'moov_money') then raise exception 'Choisissez un moyen Mobile Money.'; end if;
  if v_acc !~ '^\+?[0-9]{8,15}$' then raise exception 'Numéro de réception invalide.'; end if;
  v_fee := ceil(p_amount * (a->>'fee_pct')::numeric / 100)::int;
  v_com := least(public._commission_due(p_org), p_amount - v_fee);
  v_net := p_amount - v_fee - v_com;
  insert into public.hotel_payouts (organization_id, gross, fee, commission, net, method, account, account_name)
  values (p_org, p_amount, v_fee, v_com, v_net, p_method, v_acc, trim(p_name)) returning id, number into v_id, v_num;
  perform public._alert('finance', 'Demande de reversement n° ' || v_num || ' : ' || coalesce((select name from public.organizations where id = p_org), ''),
    'Montant : ' || p_amount || ' F · net à verser : ' || v_net || ' F (' || p_method || ' ' || v_acc || ', ' || trim(p_name) || ').');
  return jsonb_build_object('id', v_id, 'number', v_num, 'gross', p_amount, 'fee', v_fee, 'commission', v_com, 'net', v_net);
end $$;

create or replace function public.admin_payouts()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object(
    'held', (select coalesce(sum(b.amount), 0) from public.booking_payments b where b.status = 'succeeded' and b.environment is distinct from 'sandbox')
            - (select coalesce(sum(gross), 0) from public.hotel_payouts where status = 'payee'),
    'list', coalesce((select jsonb_agg(z) from (select to_jsonb(h) || jsonb_build_object('org', o.name, 'available', (public._payout_amounts(h.organization_id)->>'available')::int) z
       from public.hotel_payouts h join public.organizations o on o.id = h.organization_id
       order by (h.status in ('payee', 'refusee')), h.created_at desc limit 200) q), '[]'),
    'balances', coalesce((select jsonb_agg(z) from (select jsonb_build_object('org_id', o.id, 'org', o.name) || public._payout_amounts(o.id) z
       from public.organizations o where exists (select 1 from public.booking_payments b where b.organization_id = o.id and b.status = 'succeeded' and b.environment is distinct from 'sandbox')) q), '[]'));
end $$;

create or replace function public.admin_payout_update(p_id uuid, p_status text, p_reference text default null, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare h public.hotel_payouts;
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  select * into h from public.hotel_payouts where id = p_id for update;
  if h.id is null then raise exception 'Demande introuvable.'; end if;
  if h.status in ('payee', 'refusee') then raise exception 'Cette demande est déjà clôturée.'; end if;
  if p_status not in ('en_cours', 'payee', 'refusee') then raise exception 'Statut invalide.'; end if;
  if p_status = 'payee' and length(trim(coalesce(p_reference, ''))) < 3 then raise exception 'Indiquez la référence du transfert.'; end if;
  if p_status = 'refusee' and length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Indiquez le motif du refus.'; end if;
  update public.hotel_payouts set status = p_status, reference = coalesce(nullif(trim(p_reference), ''), reference), reason = p_reason,
    processed_at = case when p_status in ('payee', 'refusee') then now() else processed_at end, processed_by = auth.uid() where id = p_id;
  if p_status = 'payee' and h.commission > 0 then
    insert into public.naya_commission_payments (organization_id, amount, method, reference, note, paid_at, recorded_by)
    values (h.organization_id, h.commission, h.method, 'REV-' || h.number, 'Déduite du reversement n° ' || h.number, now(), auth.uid());
  end if;
  perform public._staff_log('reversement_' || p_status, 'organization', h.organization_id::text,
    jsonb_build_object('numero', h.number, 'montant', h.gross, 'net', h.net, 'reference', p_reference, 'motif', p_reason));
  perform public._notify_org(h.organization_id, case p_status
    when 'payee' then format('Reversement n° %s effectué : %s F envoyés sur %s (réf. %s).', h.number, h.net, h.account, p_reference)
    when 'refusee' then format('Reversement n° %s refusé : %s', h.number, p_reason)
    else format('Reversement n° %s en cours de traitement.', h.number) end, case when p_status = 'refusee' then 'warning' else 'info' end);
end $$;

revoke all on function public.payout_overview(uuid), public.payout_request(uuid, int, text, text, text), public.admin_payouts(), public.admin_payout_update(uuid, text, text, text) from public, anon;
grant execute on function public.payout_overview(uuid), public.payout_request(uuid, int, text, text, text), public.admin_payouts(), public.admin_payout_update(uuid, text, text, text) to authenticated;
