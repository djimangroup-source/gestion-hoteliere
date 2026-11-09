-- 62 · Paiement en ligne des réservations Nuittea.com (acompte ou totalité) par Genius Pay
-- Nouvelle table de suivi + validation réservée au serveur. Aucune donnée existante n'est modifiée.

create table if not exists public.booking_payments (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  kind text not null check (kind in ('deposit','full')),
  amount integer not null check (amount >= 200),
  status text not null default 'pending' check (status in ('pending','succeeded','failed')),
  provider text not null default 'geniuspay',
  reference text,
  environment text,
  cash_movement_id uuid,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists booking_payments_resa_idx on public.booking_payments (reservation_id);
create index if not exists booking_payments_ref_idx on public.booking_payments (reference) where reference is not null;
alter table public.booking_payments enable row level security;
create policy booking_payments_read on public.booking_payments for select to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager','receptionist','accountant']));
revoke all on public.booking_payments from anon;
grant select on public.booking_payments to authenticated;

-- Validation d'un paiement de réservation (appelée uniquement par le serveur après vérification auprès de Genius Pay)
create or replace function public.confirm_booking_payment(p_id uuid, p_reference text, p_method text default null, p_environment text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare bp public.booking_payments; r public.reservations; v_cm uuid;
begin
  if not public.is_service_context() then raise exception 'Opération réservée au serveur.'; end if;
  select * into bp from public.booking_payments where id = p_id for update;
  if bp.id is null then raise exception 'Paiement introuvable.'; end if;
  if bp.status = 'succeeded' then return jsonb_build_object('already_confirmed', true); end if;
  select * into r from public.reservations where id = bp.reservation_id for update;
  insert into public.cash_movements (organization_id, establishment_id, reservation_id, kind, method, amount, label, reference)
  values (bp.organization_id, bp.establishment_id, bp.reservation_id, 'payment', 'geniuspay', bp.amount,
          left(case bp.kind when 'deposit' then 'Acompte en ligne' else 'Paiement en ligne' end || ' · Nuittea.com' || coalesce(' · ' || nullif(p_method, ''), ''), 200), p_reference)
  returning id into v_cm;
  update public.booking_payments set status = 'succeeded', paid_at = now(), reference = coalesce(p_reference, reference), environment = coalesce(p_environment, environment), cash_movement_id = v_cm where id = bp.id;
  -- Une réservation payée en ligne est confirmée (la chambre était déjà bloquée)
  if r.status = 'pending' then
    perform set_config('horus.marketplace', 'on', true);
    update public.reservations set status = 'confirmed' where id = r.id;
    perform set_config('horus.marketplace', 'off', true);
  end if;
  perform public.write_audit(bp.organization_id, bp.establishment_id, 'reservation', r.id, 'paiement_en_ligne',
    'Paiement en ligne reçu : ' || bp.amount || ' F (' || case bp.kind when 'deposit' then 'acompte' else 'totalité' end || ')', jsonb_build_object('reference', p_reference));
  return jsonb_build_object('ok', true, 'cash_movement_id', v_cm);
end $$;

create or replace function public.fail_booking_payment(p_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not public.is_service_context() then raise exception 'Opération réservée au serveur.'; end if;
  update public.booking_payments set status = 'failed' where id = p_id and status = 'pending';
end $$;

revoke execute on function public.confirm_booking_payment(uuid, text, text, text), public.fail_booking_payment(uuid) from public, anon, authenticated;
grant execute on function public.confirm_booking_payment(uuid, text, text, text), public.fail_booking_payment(uuid) to service_role;
