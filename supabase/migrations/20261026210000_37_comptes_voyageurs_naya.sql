-- 37 · Comptes voyageurs NAYA
-- • naya_travelers : profil du voyageur (nom, téléphone), visible et modifiable par lui seul.
-- • reservations.naya_user_id : rattache une réservation NAYA au compte du voyageur qui l'a faite (si connecté).
-- • market_book : enregistre le compte du voyageur ; market_my_bookings / market_cancel_booking : ses réservations.
-- Migration additive : une colonne facultative, une table, des fonctions. Aucune donnée existante n'est modifiée.

create table if not exists public.naya_travelers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text check (full_name is null or length(full_name) <= 120),
  phone text check (phone is null or length(phone) <= 30),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.naya_travelers enable row level security;
drop policy if exists naya_travelers_self on public.naya_travelers;
create policy naya_travelers_self on public.naya_travelers for all using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.naya_travelers to authenticated;

alter table public.reservations add column if not exists naya_user_id uuid references auth.users(id) on delete set null;
create index if not exists reservations_naya_user on public.reservations (naya_user_id) where naya_user_id is not null;

-- Le rattachement au voyageur ne peut être posé ou modifié que par NAYA
create or replace function public.guard_marketplace_fields() returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('horus.marketplace', true), '') = 'on' or public.is_platform_admin() then return new; end if;
  if tg_op = 'INSERT' then
    if new.source = 'naya' or new.commission_pct is not null or new.naya_user_id is not null then raise exception 'Origine NAYA réservée aux réservations faites sur NAYA.'; end if;
  else
    if new.commission_pct is distinct from old.commission_pct then raise exception 'La commission d''une réservation NAYA ne peut pas être modifiée.'; end if;
    if (old.source = 'naya') <> (new.source = 'naya') then raise exception 'L''origine d''une réservation NAYA ne peut pas être modifiée.'; end if;
    if new.naya_user_id is distinct from old.naya_user_id then raise exception 'Le compte voyageur d''une réservation NAYA ne peut pas être modifié.'; end if;
  end if;
  return new;
end $$;

-- market_book : rattache la réservation au voyageur connecté (auth.uid(), nul pour un visiteur)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.market_book(text, text, date, date, integer, text, text, text, text)'::regprocedure);
  if position('naya_user_id' in d) = 0 then
    d := replace(d, 'status, public_reference, commission_pct)', 'status, public_reference, commission_pct, naya_user_id)');
    d := replace(d, 'v_status, v_ref, m.commission_pct)', 'v_status, v_ref, m.commission_pct, auth.uid())');
    if position('naya_user_id' in d) = 0 then raise exception 'market_book : modification impossible.'; end if;
    execute d;
  end if;
end $$;

-- Réservations du voyageur connecté
create or replace function public.market_my_bookings()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'reference', r.public_reference, 'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out,
      'nights', r.check_out - r.check_in, 'adults', r.adults, 'total', r.total_amount, 'room_type', rm.room_type,
      'hotel', coalesce(e.public_name, e.name), 'slug', e.slug, 'city', e.city, 'phone', e.public_phone, 'whatsapp', e.public_whatsapp,
      'cover', e.public_cover_url, 'created_at', r.created_at,
      'can_cancel', r.status in ('pending', 'confirmed') and r.check_in > current_date)
    order by r.check_in desc)
    from public.reservations r join public.establishments e on e.id = r.establishment_id left join public.rooms rm on rm.id = r.room_id
    where r.naya_user_id = auth.uid() and r.source = 'naya'), '[]'::jsonb);
end $$;

-- Annulation par le voyageur (avant le jour d'arrivée)
create or replace function public.market_cancel_booking(p_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'Connexion requise.'); end if;
  select * into r from public.reservations where public_reference = upper(trim(p_reference)) and naya_user_id = auth.uid() and source = 'naya' for update;
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'Réservation introuvable.'); end if;
  if r.status not in ('pending', 'confirmed') or r.check_in <= current_date then
    return jsonb_build_object('ok', false, 'error', 'Cette réservation ne peut plus être annulée en ligne. Contactez l''établissement.');
  end if;
  perform set_config('app.bypass_subscription', 'on', true);
  update public.reservations set status = 'cancelled', notes = concat_ws(' · ', notes, 'Annulée par le voyageur sur NAYA') where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.market_my_bookings(), public.market_cancel_booking(text) from public, anon;
grant execute on function public.market_my_bookings(), public.market_cancel_booking(text) to authenticated;
