-- Horus Hotel — Migration 10 : pages publiques de réservation
-- Appliquée sur le projet Supabase « gestion-hoteliere » le 17/10/2026 (version 20261017130852).
-- Migration additive : aucune table ni colonne existante n'est supprimée ou modifiée.
-- Retour arrière : voir le bloc ROLLBACK en fin de fichier.

-- ===== Paramètres publics de l'établissement (ajouts uniquement) =====
alter table public.establishments
  add column slug text,
  add column public_enabled boolean not null default false,
  add column public_name text,
  add column public_tagline text,
  add column public_description text,
  add column public_address text,
  add column public_phone text,
  add column public_whatsapp text,
  add column public_email text,
  add column public_logo_url text,
  add column public_photos jsonb not null default '[]'::jsonb,
  add column public_conditions text,
  add column public_info text,
  add column checkin_time text not null default '14:00',
  add column checkout_time text not null default '12:00',
  add column public_max_nights int not null default 30 check (public_max_nights between 1 and 365),
  add column public_auto_confirm boolean not null default false,
  add constraint establishments_slug_format check (slug is null or slug ~ '^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$'),
  add constraint establishments_public_photos_array check (jsonb_typeof(public_photos) = 'array' and jsonb_array_length(public_photos) <= 12),
  add constraint establishments_times_format check (checkin_time ~ '^[0-2][0-9]:[0-5][0-9]$' and checkout_time ~ '^[0-2][0-9]:[0-5][0-9]$');
create unique index establishments_slug_unique on public.establishments (slug) where slug is not null;

-- Slugs réservés (pages techniques futures)
create or replace function public.check_reserved_slug()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.slug in ('www','app','admin','api','horus','horushotel','login','auth','dashboard','static','assets','mail','support','help') then
    raise exception 'Cet identifiant public est réservé. Choisissez-en un autre.';
  end if;
  if new.public_enabled and new.slug is null then
    raise exception 'Définissez un identifiant public avant de publier la page.';
  end if;
  return new;
end $$;
revoke execute on function public.check_reserved_slug() from public, anon, authenticated;
create trigger trg_est_slug before insert or update of slug, public_enabled on public.establishments
  for each row execute function public.check_reserved_slug();

-- Ancien slug -> nouveau : les liens partagés restent valides
create table public.establishment_slug_history (
  old_slug text primary key,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  changed_at timestamptz not null default now()
);
alter table public.establishment_slug_history enable row level security;
create or replace function public.record_slug_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.slug is not null and new.slug is distinct from old.slug then
    insert into public.establishment_slug_history (old_slug, establishment_id) values (old.slug, old.id)
      on conflict (old_slug) do update set establishment_id = excluded.establishment_id, changed_at = now();
  end if;
  if new.slug is not null then delete from public.establishment_slug_history where old_slug = new.slug and establishment_id <> new.id; end if;
  return new;
end $$;
revoke execute on function public.record_slug_change() from public, anon, authenticated;
create trigger trg_est_slug_hist after update of slug on public.establishments for each row execute function public.record_slug_change();

-- Seuls propriétaire/administrateur modifient la page publique (la politique est_write l'impose déjà)

-- ===== Journal des demandes publiques (anti-abus) =====
create table public.public_booking_attempts (
  id bigint generated always as identity primary key,
  establishment_id uuid references public.establishments(id) on delete cascade,
  phone text,
  ok boolean not null,
  reason text,
  created_at timestamptz not null default now()
);
create index on public.public_booking_attempts (phone, created_at);
create index on public.public_booking_attempts (establishment_id, created_at);
alter table public.public_booking_attempts enable row level security;
create policy pba_select on public.public_booking_attempts for select to authenticated
  using ((select public.has_org_role((select e.organization_id from public.establishments e where e.id = establishment_id), array['owner','admin','manager'])));

alter table public.reservations add column public_reference text;
create unique index reservations_public_reference on public.reservations (public_reference) where public_reference is not null;

-- ===== Résolution interne d'un slug (actif + abonnement valide) =====
create or replace function public.resolve_public_establishment(p_slug text)
returns public.establishments language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments; v text := lower(trim(coalesce(p_slug, '')));
begin
  select * into e from public.establishments where slug = v;
  if not found then
    select x.* into e from public.establishment_slug_history h join public.establishments x on x.id = h.establishment_id where h.old_slug = v;
  end if;
  if not found or not e.public_enabled or not e.is_active or not public.org_can_write(e.organization_id) then return null; end if;
  return e;
end $$;
revoke execute on function public.resolve_public_establishment(text) from public, anon, authenticated;

-- ===== API publique 1 : présentation (aucune donnée privée) =====
create or replace function public.public_get_establishment(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments;
begin
  e := public.resolve_public_establishment(p_slug);
  if e.id is null then return null; end if;
  return jsonb_build_object(
    'slug', e.slug, 'name', coalesce(e.public_name, e.name), 'tagline', e.public_tagline, 'description', e.public_description,
    'city', e.city, 'address', e.public_address, 'phone', e.public_phone, 'whatsapp', e.public_whatsapp, 'email', e.public_email,
    'logo', e.public_logo_url, 'photos', e.public_photos, 'conditions', e.public_conditions, 'info', e.public_info,
    'checkin_time', e.checkin_time, 'checkout_time', e.checkout_time, 'max_nights', e.public_max_nights, 'currency', e.currency,
    'auto_confirm', e.public_auto_confirm,
    'room_types', coalesce((
      select jsonb_agg(jsonb_build_object('type', t, 'from_rate', min_rate, 'capacity', cap, 'count', n) order by min_rate)
      from (select coalesce(nullif(trim(room_type), ''), 'Chambre') t, min(base_rate) min_rate, max(capacity) cap, count(*) n
            from public.rooms where establishment_id = e.id and is_active and housekeeping_status <> 'out_of_service' and base_rate is not null and base_rate > 0
            group by 1) x), '[]'::jsonb));
end $$;

-- ===== API publique 2 : disponibilité et prix (calcul serveur) =====
create or replace function public.public_quote(p_slug text, p_room_type text, p_check_in date, p_check_out date, p_adults int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments; v_room record; v_n int;
begin
  e := public.resolve_public_establishment(p_slug);
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'Page indisponible.'); end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then return jsonb_build_object('ok', false, 'error', 'La date de départ doit suivre la date d''arrivée.'); end if;
  if p_check_in < current_date then return jsonb_build_object('ok', false, 'error', 'La date d''arrivée est passée.'); end if;
  if p_check_in > current_date + 365 then return jsonb_build_object('ok', false, 'error', 'Réservation possible jusqu''à 12 mois à l''avance.'); end if;
  v_n := p_check_out - p_check_in;
  if v_n > e.public_max_nights then return jsonb_build_object('ok', false, 'error', format('Séjour limité à %s nuits en ligne.', e.public_max_nights)); end if;
  select r.id, r.base_rate into v_room from public.rooms r
   where r.establishment_id = e.id and r.is_active and r.housekeeping_status <> 'out_of_service' and r.base_rate > 0
     and coalesce(nullif(trim(r.room_type), ''), 'Chambre') = p_room_type
     and (r.capacity is null or r.capacity >= greatest(coalesce(p_adults, 1), 1))
     and not exists (select 1 from public.reservations x where x.room_id = r.id and x.status not in ('cancelled','no_show','checked_out')
                     and daterange(x.check_in, x.check_out, '[)') && daterange(p_check_in, p_check_out, '[)'))
   order by r.base_rate, r.number limit 1;
  if v_room.id is null then return jsonb_build_object('ok', false, 'error', 'Aucune chambre de ce type n''est disponible à ces dates.'); end if;
  return jsonb_build_object('ok', true, 'nights', v_n, 'rate', v_room.base_rate, 'total', v_n * v_room.base_rate);
end $$;

-- ===== API publique 3 : demande de réservation (transactionnelle) =====
create or replace function public.public_create_booking(p_slug text, p_room_type text, p_check_in date, p_check_out date, p_adults int,
  p_name text, p_phone text, p_email text default null, p_notes text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e public.establishments; q jsonb; v_room record; v_guest uuid; v_res uuid; v_ref text; v_phone text; v_status text; v_recent int;
begin
  e := public.resolve_public_establishment(p_slug);
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'Page indisponible.'); end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  if length(trim(coalesce(p_name, ''))) < 2 or length(p_name) > 120 then return jsonb_build_object('ok', false, 'error', 'Indiquez votre nom complet.'); end if;
  if v_phone !~ '^\+?[0-9]{8,15}$' then return jsonb_build_object('ok', false, 'error', 'Numéro de téléphone invalide.'); end if;
  if p_email is not null and p_email <> '' and (length(p_email) > 160 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then return jsonb_build_object('ok', false, 'error', 'Adresse e-mail invalide.'); end if;
  if length(coalesce(p_notes, '')) > 1000 then return jsonb_build_object('ok', false, 'error', 'Message trop long.'); end if;
  if coalesce(p_adults, 0) not between 1 and 20 then return jsonb_build_object('ok', false, 'error', 'Nombre de personnes invalide.'); end if;

  -- Anti-abus : 3 demandes par téléphone et par jour, 40 demandes par établissement et par heure
  select count(*) into v_recent from public.public_booking_attempts where phone = v_phone and ok and created_at > now() - interval '24 hours';
  if v_recent >= 3 then
    insert into public.public_booking_attempts (establishment_id, phone, ok, reason) values (e.id, v_phone, false, 'limite_telephone');
    return jsonb_build_object('ok', false, 'error', 'Trop de demandes depuis ce numéro aujourd''hui. Contactez directement l''établissement.');
  end if;
  select count(*) into v_recent from public.public_booking_attempts where establishment_id = e.id and created_at > now() - interval '1 hour';
  if v_recent >= 40 then return jsonb_build_object('ok', false, 'error', 'Service momentanément saturé. Réessayez plus tard.'); end if;

  -- Verrou par établissement : deux demandes simultanées ne peuvent pas obtenir la même chambre
  perform pg_advisory_xact_lock(hashtextextended('public_booking:' || e.id::text, 0));

  q := public.public_quote(p_slug, p_room_type, p_check_in, p_check_out, p_adults);
  if not (q->>'ok')::boolean then
    insert into public.public_booking_attempts (establishment_id, phone, ok, reason) values (e.id, v_phone, false, q->>'error');
    return q;
  end if;
  select r.id, r.base_rate into v_room from public.rooms r
   where r.establishment_id = e.id and r.is_active and r.housekeeping_status <> 'out_of_service' and r.base_rate > 0
     and coalesce(nullif(trim(r.room_type), ''), 'Chambre') = p_room_type
     and (r.capacity is null or r.capacity >= p_adults)
     and not exists (select 1 from public.reservations x where x.room_id = r.id and x.status not in ('cancelled','no_show','checked_out')
                     and daterange(x.check_in, x.check_out, '[)') && daterange(p_check_in, p_check_out, '[)'))
   order by r.base_rate, r.number limit 1;

  select id into v_guest from public.guests where organization_id = e.organization_id and regexp_replace(coalesce(phone, ''), '[^0-9+]', '', 'g') = v_phone limit 1;
  if v_guest is null then
    insert into public.guests (organization_id, full_name, phone, email, notes)
    values (e.organization_id, trim(p_name), v_phone, nullif(trim(coalesce(p_email, '')), ''), 'Créé depuis la page publique') returning id into v_guest;
  end if;

  v_ref := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  v_status := case when e.public_auto_confirm then 'confirmed' else 'pending' end;
  insert into public.reservations (establishment_id, room_id, guest_id, guest_name, guest_phone, check_in, check_out, adults, nightly_rate, discount, source, notes, status, public_reference)
  values (e.id, v_room.id, v_guest, trim(p_name), v_phone, p_check_in, p_check_out, p_adults, v_room.base_rate, 0, 'en_ligne',
          nullif(trim(concat_ws(' · ', 'Demande en ligne', nullif(trim(coalesce(p_email, '')), ''), nullif(trim(coalesce(p_notes, '')), ''))), ''), v_status, v_ref)
  returning id into v_res;

  insert into public.public_booking_attempts (establishment_id, phone, ok, reason) values (e.id, v_phone, true, null);
  return jsonb_build_object('ok', true, 'reference', v_ref, 'status', v_status, 'nights', q->'nights', 'total', q->'total',
                            'name', coalesce(e.public_name, e.name), 'phone', e.public_phone, 'whatsapp', e.public_whatsapp);
exception when exclusion_violation then
  return jsonb_build_object('ok', false, 'error', 'Cette chambre vient d''être réservée. Choisissez d''autres dates ou un autre type.');
end $$;

-- Disponibilité d'un slug (pour l'espace « Ma page publique »)
create or replace function public.slug_available(p_slug text, p_establishment uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select lower(p_slug) ~ '^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$'
     and lower(p_slug) not in ('www','app','admin','api','horus','horushotel','login','auth','dashboard','static','assets','mail','support','help')
     and not exists (select 1 from public.establishments where slug = lower(p_slug) and id <> p_establishment)
     and not exists (select 1 from public.establishment_slug_history where old_slug = lower(p_slug) and establishment_id <> p_establishment);
$$;

revoke execute on function public.public_get_establishment(text), public.public_quote(text, text, date, date, int),
  public.public_create_booking(text, text, date, date, int, text, text, text, text), public.slug_available(text, uuid) from public;
grant execute on function public.public_get_establishment(text), public.public_quote(text, text, date, date, int),
  public.public_create_booking(text, text, date, date, int, text, text, text, text) to anon, authenticated;
grant execute on function public.slug_available(text, uuid) to authenticated;

-- ===== Photos : stockage public en lecture, écriture réservée aux gestionnaires de l'organisation =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('public-media', 'public-media', true, 3145728, array['image/jpeg','image/png','image/webp']);

create policy "media_insert_org" on storage.objects for insert to authenticated
  with check (bucket_id = 'public-media' and (select public.has_org_role(((storage.foldername(name))[1])::uuid, array['owner','admin'])));
create policy "media_delete_org" on storage.objects for delete to authenticated
  using (bucket_id = 'public-media' and (select public.has_org_role(((storage.foldername(name))[1])::uuid, array['owner','admin'])));

/* ===== ROLLBACK (à exécuter manuellement si nécessaire — supprime les données publiques saisies) =====
drop policy if exists "media_insert_org" on storage.objects;
drop policy if exists "media_delete_org" on storage.objects;
-- vider puis supprimer le bucket 'public-media' depuis le tableau de bord Supabase (Storage)
drop function if exists public.slug_available(text, uuid);
drop function if exists public.public_create_booking(text, text, date, date, int, text, text, text, text);
drop function if exists public.public_quote(text, text, date, date, int);
drop function if exists public.public_get_establishment(text);
drop function if exists public.resolve_public_establishment(text);
drop index if exists public.reservations_public_reference;
alter table public.reservations drop column if exists public_reference;
drop table if exists public.public_booking_attempts;
drop trigger if exists trg_est_slug_hist on public.establishments;
drop function if exists public.record_slug_change();
drop table if exists public.establishment_slug_history;
drop trigger if exists trg_est_slug on public.establishments;
drop function if exists public.check_reserved_slug();
drop index if exists public.establishments_slug_unique;
alter table public.establishments
  drop constraint if exists establishments_slug_format, drop constraint if exists establishments_public_photos_array, drop constraint if exists establishments_times_format,
  drop column if exists slug, drop column if exists public_enabled, drop column if exists public_name, drop column if exists public_tagline,
  drop column if exists public_description, drop column if exists public_address, drop column if exists public_phone, drop column if exists public_whatsapp,
  drop column if exists public_email, drop column if exists public_logo_url, drop column if exists public_photos, drop column if exists public_conditions,
  drop column if exists public_info, drop column if exists checkin_time, drop column if exists checkout_time, drop column if exists public_max_nights,
  drop column if exists public_auto_confirm;
*/
