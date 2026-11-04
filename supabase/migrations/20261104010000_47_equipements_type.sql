-- 47 · Équipements et type d'établissement (filtres avancés de Nuittea.com) — ajout uniquement.
-- • establishments.amenities : liste fermée d'équipements cochés par l'hôtelier dans « Ma fiche Nuittea ».
-- • establishments.property_type : hôtel, résidence meublée, appartement, maison d'hôtes.
-- • market_search3 : recherche de market_search2 + type, équipements, note minimale et tri (nouvelle fonction,
--   market_search2 reste inchangée). market_location renvoie aussi type et équipements.

alter table public.establishments
  add column if not exists amenities text[] not null default '{}',
  add column if not exists property_type text;
do $$ begin
  alter table public.establishments add constraint establishments_property_type_chk
    check (property_type is null or property_type in ('hotel', 'residence', 'appartement', 'maison_hotes'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.establishments add constraint establishments_amenities_chk
    check (amenities <@ array['wifi', 'clim', 'eau_chaude', 'groupe_electrogene', 'parking', 'piscine', 'petit_dejeuner', 'restaurant', 'tv', 'cuisine', 'securite', 'navette']::text[]);
exception when duplicate_object then null; end $$;

create or replace function public.market_search3(p_q text default null, p_locality text default null,
  p_lat double precision default null, p_lng double precision default null, p_radius_km double precision default null,
  p_check_in date default null, p_check_out date default null, p_adults int default 1, p_max_price numeric default null,
  p_instant boolean default null, p_types text[] default null, p_amenities text[] default null, p_min_rating numeric default null,
  p_sort text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare base jsonb;
begin
  base := public.market_search2(p_q, p_locality, p_lat, p_lng, p_radius_km, p_check_in, p_check_out, p_adults, p_max_price, p_instant);
  return coalesce((select jsonb_agg(x order by
      (x->>'available')::boolean desc,
      case when p_sort = 'price' then (x->>'price_from')::numeric end asc nulls last,
      case when p_sort = 'rating' then (x->>'rating')::numeric end desc nulls last,
      case when p_sort = 'distance' then (x->>'distance_km')::numeric end asc nulls last,
      (x->>'distance_km')::numeric nulls last, (x->>'price_from')::numeric nulls last) from (
    select b || jsonb_build_object('property_type', e.property_type, 'amenities', to_jsonb(e.amenities)) x
      from jsonb_array_elements(base) b join public.establishments e on e.slug = b->>'slug'
     where (p_types is null or cardinality(p_types) = 0 or e.property_type = any (p_types))
       and (p_amenities is null or cardinality(p_amenities) = 0 or e.amenities @> p_amenities)
       and (p_min_rating is null or ((b->>'reviews')::int > 0 and (b->>'rating')::numeric >= p_min_rating))
  ) s), '[]'::jsonb);
end $$;
revoke execute on function public.market_search3(text, text, double precision, double precision, double precision, date, date, int, numeric, boolean, text[], text[], numeric, text) from public;
grant execute on function public.market_search3(text, text, double precision, double precision, double precision, date, date, int, numeric, boolean, text[], text[], numeric, text) to anon, authenticated;

create or replace function public.market_location(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('label', public._loc_label(e.locality_id), 'landmark', e.landmark, 'lat', e.latitude, 'lng', e.longitude,
    'address', coalesce(e.public_address, e.address), 'city', e.city,
    'locality_slug', (select l.slug from public.localities l where l.id = e.locality_id),
    'property_type', e.property_type, 'amenities', to_jsonb(e.amenities))
  from public.establishments e join public.marketplace_listings m on m.establishment_id = e.id
  where e.slug = p_slug and m.listed and e.is_active;
$$;
