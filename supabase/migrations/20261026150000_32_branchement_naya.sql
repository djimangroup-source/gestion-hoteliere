-- Horus Hotel — Migration 32 : branchement avec la place de marché NAYA.
-- Les établissements choisissent d'apparaître sur NAYA ; les réservations venues de NAYA portent l'origine « naya »
-- et le taux de commission figé au moment de la réservation. Aucune donnée existante n'est modifiée.

-- 1. Nouvelle origine de réservation et commission figée
alter table public.reservations drop constraint reservations_source_check;
alter table public.reservations add constraint reservations_source_check
  check (source = any (array['direct','telephone','walk_in','whatsapp','agence','en_ligne','naya']));
alter table public.reservations add column if not exists commission_pct numeric(5,2)
  check (commission_pct is null or (commission_pct >= 0 and commission_pct <= 50));

-- 2. Participation des établissements à la place de marché
create table if not exists public.marketplace_listings (
  establishment_id uuid primary key references public.establishments(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  listed boolean not null default false,
  commission_pct numeric(5,2) not null default 10 check (commission_pct >= 0 and commission_pct <= 50),
  auto_confirm boolean not null default false,
  terms_accepted_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.marketplace_listings enable row level security;
create policy marketplace_listings_select on public.marketplace_listings for select using (public.is_org_member(organization_id) or public.is_platform_admin());
grant select on public.marketplace_listings to authenticated;
-- Écriture uniquement par les fonctions ci-dessous (aucun droit direct).

-- 3. Garde-fou : origine « naya » et commission ne se posent ou ne s'effacent que par les fonctions de la place de marché
create or replace function public.guard_marketplace_fields() returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('horus.marketplace', true), '') = 'on' or public.is_platform_admin() then return new; end if;
  if tg_op = 'INSERT' then
    if new.source = 'naya' or new.commission_pct is not null then raise exception 'Origine NAYA réservée aux réservations faites sur NAYA.'; end if;
  else
    if new.commission_pct is distinct from old.commission_pct then raise exception 'La commission d''une réservation NAYA ne peut pas être modifiée.'; end if;
    if (old.source = 'naya') <> (new.source = 'naya') then raise exception 'L''origine d''une réservation NAYA ne peut pas être modifiée.'; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_marketplace on public.reservations;
create trigger trg_guard_marketplace before insert or update on public.reservations for each row execute function public.guard_marketplace_fields();

-- 4. Côté hôtelier : rejoindre ou quitter NAYA (propriétaire ou administrateur)
create or replace function public.marketplace_set_listing(p_establishment uuid, p_listed boolean, p_auto_confirm boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.establishments; v_slug text; v_base text; i int := 0; m public.marketplace_listings;
begin
  select * into e from public.establishments where id = p_establishment;
  if e.id is null or not public.has_org_role(e.organization_id, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  if p_listed and e.slug is null then
    v_base := trim(both '-' from regexp_replace(lower(translate(coalesce(e.public_name, e.name), 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ''', 'aaaeeeeiioouuucAAAEEEEIIOOUUUC-')), '[^a-z0-9]+', '-', 'g'));
    if length(v_base) < 3 then v_base := 'hotel-' || v_base; end if;
    v_base := trim(both '-' from left(v_base, 34)); v_slug := v_base;
    while exists (select 1 from public.establishments where slug = v_slug) loop i := i + 1; v_slug := v_base || '-' || i; end loop;
    update public.establishments set slug = v_slug where id = e.id;
  end if;
  insert into public.marketplace_listings (establishment_id, organization_id, listed, auto_confirm, terms_accepted_at)
  values (e.id, e.organization_id, p_listed, coalesce(p_auto_confirm, false), case when p_listed then now() end)
  on conflict (establishment_id) do update set listed = excluded.listed,
    auto_confirm = coalesce(p_auto_confirm, public.marketplace_listings.auto_confirm),
    terms_accepted_at = case when p_listed then coalesce(public.marketplace_listings.terms_accepted_at, now()) else public.marketplace_listings.terms_accepted_at end,
    updated_at = now()
  returning * into m;
  insert into public.audit_log (organization_id, establishment_id, entity, entity_id, action, summary, actor_id)
  values (e.organization_id, e.id, 'naya', e.id, case when p_listed then 'publication' else 'retrait' end,
          case when p_listed then 'Établissement publié sur NAYA' else 'Établissement retiré de NAYA' end, auth.uid());
  return jsonb_build_object('ok', true, 'listed', m.listed, 'commission_pct', m.commission_pct, 'auto_confirm', m.auto_confirm, 'slug', (select slug from public.establishments where id = e.id));
end $$;
revoke execute on function public.marketplace_set_listing(uuid, boolean, boolean) from public, anon;
grant execute on function public.marketplace_set_listing(uuid, boolean, boolean) to authenticated;

-- Taux de commission : fixé par la plateforme uniquement
create or replace function public.marketplace_set_commission(p_establishment uuid, p_pct numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Accès refusé.'; end if;
  update public.marketplace_listings set commission_pct = p_pct, updated_at = now() where establishment_id = p_establishment;
end $$;
revoke execute on function public.marketplace_set_commission(uuid, numeric) from public, anon;
grant execute on function public.marketplace_set_commission(uuid, numeric) to authenticated;

-- 5. Côté voyageur (NAYA, rôle anon)
create or replace function public._market_est(p_slug text) returns public.establishments
language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments;
begin
  select x.* into e from public.establishments x join public.marketplace_listings m on m.establishment_id = x.id
   where x.slug = lower(trim(coalesce(p_slug, ''))) and m.listed and x.is_active and public.org_can_write(x.organization_id);
  return e;
end $$;
revoke execute on function public._market_est(text) from public, anon, authenticated;

create or replace function public._market_room(e_id uuid, p_type text, p_in date, p_out date, p_adults int) returns uuid
language sql stable security definer set search_path = '' as $$
  select r.id from public.rooms r
   where r.establishment_id = e_id and r.is_active and r.housekeeping_status <> 'out_of_service' and r.base_rate > 0
     and coalesce(nullif(trim(r.room_type), ''), 'Chambre') = p_type
     and (r.capacity is null or r.capacity >= greatest(coalesce(p_adults, 1), 1))
     and not exists (select 1 from public.reservations x where x.room_id = r.id and x.status not in ('cancelled','no_show','checked_out')
                     and daterange(x.check_in, x.check_out, '[)') && daterange(p_in, p_out, '[)'))
   order by r.base_rate, r.number limit 1;
$$;
revoke execute on function public._market_room(uuid, text, date, date, int) from public, anon, authenticated;

-- Recherche : établissements publiés, avec pour chaque type de chambre le prix total s'il est libre sur les dates
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
      and (p_city is null or p_city = '' or e.city ilike '%' || p_city || '%' or coalesce(e.public_name, e.name) ilike '%' || p_city || '%')
  ) s), '[]'::jsonb);
end $$;

-- Fiche : présentation + types de chambres, avec disponibilité et prix total pour les dates
create or replace function public.market_establishment(p_slug text, p_check_in date default null, p_check_out date default null, p_adults int default 1)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments; m public.marketplace_listings; v_dates boolean := p_check_in is not null and p_check_out is not null and p_check_out > p_check_in and p_check_in >= current_date and p_check_out - p_check_in <= 60;
begin
  e := public._market_est(p_slug); if e.id is null then return null; end if;
  select * into m from public.marketplace_listings where establishment_id = e.id;
  return jsonb_build_object('slug', e.slug, 'name', coalesce(e.public_name, e.name), 'tagline', e.public_tagline, 'description', e.public_description,
    'city', e.city, 'address', e.public_address, 'photos', coalesce(e.public_photos, '[]'::jsonb), 'cover', e.public_cover_url, 'logo', e.public_logo_url,
    'conditions', e.public_conditions, 'checkin_time', e.checkin_time, 'checkout_time', e.checkout_time, 'map_url', e.public_map_url,
    'highlights', to_jsonb(e.public_highlights), 'auto_confirm', m.auto_confirm,
    'rating', (select round(avg(v.rating), 1) from public.reviews v where v.establishment_id = e.id and v.status = 'submitted' and v.is_published),
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('guest', split_part(coalesce(v.guest_name, 'Client'), ' ', 1), 'rating', v.rating, 'comment', v.comment, 'date', v.submitted_at::date) order by v.submitted_at desc), '[]'::jsonb)
                from (select * from public.reviews v where v.establishment_id = e.id and v.status = 'submitted' and v.is_published order by submitted_at desc limit 10) v),
    'room_types', coalesce((select jsonb_agg(t order by (t->>'from_rate')::numeric) from (
      select jsonb_build_object('type', y.t, 'from_rate', y.min_rate, 'capacity', y.cap, 'count', y.n, 'description', y.descr, 'bed_type', y.bed, 'size_m2', y.sz,
        'photos', coalesce((select jsonb_agg(p) from (select distinct jsonb_array_elements(r2.photos) p from public.rooms r2 where r2.establishment_id = e.id and r2.is_active and coalesce(nullif(trim(r2.room_type), ''), 'Chambre') = y.t limit 8) z), '[]'::jsonb),
        'amenities', coalesce((select to_jsonb(array_agg(distinct a)) from public.rooms r3, unnest(r3.amenities) a where r3.establishment_id = e.id and r3.is_active and coalesce(nullif(trim(r3.room_type), ''), 'Chambre') = y.t), '[]'::jsonb),
        'quote', case when v_dates then (select case when rid is null then jsonb_build_object('available', false)
                   else (select jsonb_build_object('available', true, 'nights', p_check_out - p_check_in, 'rate', (q->>'rate')::numeric, 'total', (q->>'total')::numeric) from (select public._stay_price(rid, p_check_in, p_check_out) q) qq) end
                  from (select public._market_room(e.id, y.t, p_check_in, p_check_out, p_adults) rid) rr) end) t
      from (select coalesce(nullif(trim(room_type), ''), 'Chambre') t, min(base_rate) min_rate, max(capacity) cap, count(*) n, max(description) descr, max(bed_type) bed, max(size_m2) sz
            from public.rooms where establishment_id = e.id and is_active and housekeeping_status <> 'out_of_service' and base_rate > 0 group by 1) y) s), '[]'::jsonb));
end $$;

-- Réservation depuis NAYA : même contrôles que la page publique, origine « naya », commission figée
create or replace function public.market_book(p_slug text, p_room_type text, p_check_in date, p_check_out date, p_adults int, p_name text, p_phone text, p_email text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.establishments; m public.marketplace_listings; v_room uuid; v_guest uuid; v_res uuid; v_ref text; v_phone text; v_status text; v_recent int; q jsonb;
begin
  e := public._market_est(p_slug);
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'Établissement indisponible.'); end if;
  select * into m from public.marketplace_listings where establishment_id = e.id;
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  if length(trim(coalesce(p_name, ''))) < 2 or length(p_name) > 120 then return jsonb_build_object('ok', false, 'error', 'Indiquez votre nom complet.'); end if;
  if v_phone !~ '^\+?[0-9]{8,15}$' then return jsonb_build_object('ok', false, 'error', 'Numéro de téléphone invalide.'); end if;
  if p_email is not null and p_email <> '' and (length(p_email) > 160 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then return jsonb_build_object('ok', false, 'error', 'Adresse e-mail invalide.'); end if;
  if length(coalesce(p_notes, '')) > 1000 then return jsonb_build_object('ok', false, 'error', 'Message trop long.'); end if;
  if coalesce(p_adults, 0) not between 1 and 20 then return jsonb_build_object('ok', false, 'error', 'Nombre de personnes invalide.'); end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then return jsonb_build_object('ok', false, 'error', 'La date de départ doit suivre la date d''arrivée.'); end if;
  if p_check_in < current_date then return jsonb_build_object('ok', false, 'error', 'La date d''arrivée est passée.'); end if;
  if p_check_in > current_date + 365 or p_check_out - p_check_in > 60 then return jsonb_build_object('ok', false, 'error', 'Séjour hors des limites de réservation en ligne.'); end if;

  select count(*) into v_recent from public.public_booking_attempts where phone = v_phone and ok and created_at > now() - interval '24 hours';
  if v_recent >= 3 then
    insert into public.public_booking_attempts (establishment_id, phone, ok, reason) values (e.id, v_phone, false, 'limite_telephone');
    return jsonb_build_object('ok', false, 'error', 'Trop de demandes depuis ce numéro aujourd''hui.');
  end if;
  select count(*) into v_recent from public.public_booking_attempts where establishment_id = e.id and created_at > now() - interval '1 hour';
  if v_recent >= 40 then return jsonb_build_object('ok', false, 'error', 'Service momentanément saturé. Réessayez plus tard.'); end if;

  perform pg_advisory_xact_lock(hashtextextended('public_booking:' || e.id::text, 0));
  v_room := public._market_room(e.id, p_room_type, p_check_in, p_check_out, p_adults);
  if v_room is null then
    insert into public.public_booking_attempts (establishment_id, phone, ok, reason) values (e.id, v_phone, false, 'indisponible');
    return jsonb_build_object('ok', false, 'error', 'Ce type de chambre n''est plus disponible à ces dates.');
  end if;
  q := public._stay_price(v_room, p_check_in, p_check_out);

  select id into v_guest from public.guests where organization_id = e.organization_id and regexp_replace(coalesce(phone, ''), '[^0-9+]', '', 'g') = v_phone limit 1;
  if v_guest is null then
    insert into public.guests (organization_id, full_name, phone, email, notes)
    values (e.organization_id, trim(p_name), v_phone, nullif(trim(coalesce(p_email, '')), ''), 'Créé depuis NAYA') returning id into v_guest;
  end if;

  v_ref := 'NY' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 7));
  v_status := case when m.auto_confirm then 'confirmed' else 'pending' end;
  perform set_config('horus.marketplace', 'on', true);
  insert into public.reservations (establishment_id, room_id, guest_id, guest_name, guest_phone, check_in, check_out, adults, nightly_rate, discount, source, notes, status, public_reference, commission_pct)
  values (e.id, v_room, v_guest, trim(p_name), v_phone, p_check_in, p_check_out, p_adults, (q->>'rate')::numeric,
          (q->>'rate')::numeric * (p_check_out - p_check_in) - (q->>'total')::numeric, 'naya',
          nullif(trim(concat_ws(' · ', 'Réservation NAYA', nullif(trim(coalesce(p_email, '')), ''), nullif(trim(coalesce(p_notes, '')), ''))), ''), v_status, v_ref, m.commission_pct)
  returning id into v_res;
  perform set_config('horus.marketplace', 'off', true);

  insert into public.public_booking_attempts (establishment_id, phone, ok, reason) values (e.id, v_phone, true, 'naya');
  return jsonb_build_object('ok', true, 'reference', v_ref, 'status', v_status, 'nights', p_check_out - p_check_in, 'total', (q->>'total')::numeric,
                            'name', coalesce(e.public_name, e.name), 'phone', e.public_phone, 'whatsapp', e.public_whatsapp);
exception when exclusion_violation then
  return jsonb_build_object('ok', false, 'error', 'Cette chambre vient d''être réservée. Choisissez d''autres dates ou un autre type.');
end $$;

revoke execute on function public.market_search(text, date, date, int), public.market_establishment(text, date, date, int),
  public.market_book(text, text, date, date, int, text, text, text, text) from public;
grant execute on function public.market_search(text, date, date, int), public.market_establishment(text, date, date, int),
  public.market_book(text, text, date, date, int, text, text, text, text) to anon, authenticated;
