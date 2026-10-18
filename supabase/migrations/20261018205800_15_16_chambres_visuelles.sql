-- Horus Hotel — Migrations 15 et 16 (18/10/2026) : fiches visuelles des chambres.
-- La migration 15 contenait une version de public_get_establishment invalide (sous-requête corrélée non groupée) ;
-- la migration 16 l'a remplacée quelques minutes plus tard. Ce fichier reproduit l'état final.
-- Tests (annulés) : création de 10 chambres en lot, limite de 8 photos, page publique avec photos/équipements/description.

alter table public.rooms
  add column photos jsonb not null default '[]'::jsonb,
  add column description text,
  add column amenities text[] not null default '{}',
  add column bed_type text,
  add column floor text,
  add column size_m2 int check (size_m2 is null or size_m2 between 1 and 1000),
  add constraint rooms_photos_array check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 8),
  add constraint rooms_description_len check (description is null or length(description) <= 1000),
  add constraint rooms_amenities_len check (cardinality(amenities) <= 30);

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
      select jsonb_agg(jsonb_build_object('type', y.t, 'from_rate', y.min_rate, 'capacity', y.cap, 'count', y.n,
        'photos', coalesce((select jsonb_agg(p) from (select distinct jsonb_array_elements(r2.photos) p from public.rooms r2
                   where r2.establishment_id = e.id and r2.is_active and coalesce(nullif(trim(r2.room_type), ''), 'Chambre') = y.t limit 8) x), '[]'::jsonb),
        'amenities', coalesce((select to_jsonb(array_agg(distinct a)) from public.rooms r3, unnest(r3.amenities) a
                   where r3.establishment_id = e.id and r3.is_active and coalesce(nullif(trim(r3.room_type), ''), 'Chambre') = y.t), '[]'::jsonb),
        'description', y.descr, 'bed_type', y.bed, 'size_m2', y.sz) order by y.min_rate)
      from (
        select coalesce(nullif(trim(room_type), ''), 'Chambre') t, min(base_rate) min_rate, max(capacity) cap, count(*) n,
               max(description) descr, max(bed_type) bed, max(size_m2) sz
        from public.rooms
        where establishment_id = e.id and is_active and housekeeping_status <> 'out_of_service' and base_rate is not null and base_rate > 0
        group by 1) y), '[]'::jsonb));
end $$;

-- Photos de chambres : le gérant peut aussi les envoyer (dossier <org>/<etab>/rooms/...)
create policy "media_insert_rooms_manager" on storage.objects for insert to authenticated
  with check (bucket_id = 'public-media' and (storage.foldername(name))[3] = 'rooms'
              and (select public.has_org_role(((storage.foldername(name))[1])::uuid, array['manager'])));
