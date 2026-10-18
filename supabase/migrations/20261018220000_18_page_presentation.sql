-- Horus Hotel — Migration 18 : page de présentation enrichie (couverture, couleur, atouts, réseaux, plan).
-- Additive : nouvelles colonnes facultatives ; public_get_establishment renvoie en plus ces champs.
alter table public.establishments
  add column if not exists public_cover_url text check (public_cover_url is null or length(public_cover_url) <= 500),
  add column if not exists public_theme text not null default 'terracotta' check (public_theme in ('terracotta','ocean','foret','nuit','or')),
  add column if not exists public_highlights text[] not null default '{}' check (cardinality(public_highlights) <= 12),
  add column if not exists public_map_url text check (public_map_url is null or (length(public_map_url) <= 500 and public_map_url ~* '^https://')),
  add column if not exists public_facebook text check (public_facebook is null or (length(public_facebook) <= 300 and public_facebook ~* '^https://')),
  add column if not exists public_instagram text check (public_instagram is null or (length(public_instagram) <= 300 and public_instagram ~* '^https://'));

create or replace function public.public_get_establishment(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare e public.establishments;
begin
  e := public.resolve_public_establishment(p_slug);
  if e.id is null then return null; end if;
  return jsonb_build_object(
    'slug', e.slug, 'name', coalesce(e.public_name, e.name), 'tagline', e.public_tagline, 'description', e.public_description,
    'city', e.city, 'address', e.public_address, 'phone', e.public_phone, 'whatsapp', e.public_whatsapp, 'email', e.public_email,
    'logo', e.public_logo_url, 'photos', e.public_photos, 'conditions', e.public_conditions, 'info', e.public_info,
    'cover', e.public_cover_url, 'theme', e.public_theme, 'highlights', to_jsonb(e.public_highlights),
    'map_url', e.public_map_url, 'facebook', e.public_facebook, 'instagram', e.public_instagram,
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
end $function$;

/* ROLLBACK : restaurer public_get_establishment (migration 16) puis
alter table public.establishments drop column public_cover_url, drop column public_theme, drop column public_highlights,
  drop column public_map_url, drop column public_facebook, drop column public_instagram;
*/
