-- 44 · Lieux (villes, communes, quartiers) et localisation précise des établissements
-- Migration additive : nouvelle table public.localities, nouvelles colonnes sur public.establishments,
-- nouvelles fonctions. Aucune donnée existante n'est supprimée ni modifiée (sauf rattachement de la ville
-- actuelle des établissements au lieu correspondant).

-- ---------------------------------------------------------------- Outils
create or replace function public._norm(p text) returns text language sql immutable set search_path = '' as $$
  select trim(regexp_replace(lower(translate(coalesce(p, ''),
    'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÇçÑñŸÿ''’-',
    'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNnYy   ')), '[^a-z0-9]+', ' ', 'g'));
$$;

create or replace function public._km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable set search_path = '' as $$
  select case when lat1 is null or lat2 is null or lng1 is null or lng2 is null then null else
    6371 * 2 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))) end;
$$;

-- ---------------------------------------------------------------- Table des lieux
create table if not exists public.localities (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('ville', 'commune', 'quartier')),
  name text not null check (length(trim(name)) between 2 and 80),
  slug text not null unique,
  parent_id uuid references public.localities(id) on delete restrict,
  aliases text[] not null default '{}',
  lat double precision check (lat is null or lat between 4.0 and 11.0),
  lng double precision check (lng is null or lng between -9.0 and -2.0),
  status text not null default 'valide' check (status in ('valide', 'propose', 'rejete')),
  proposed_by uuid references public.organizations(id) on delete set null,
  search_text text not null default '',
  created_at timestamptz not null default now(),
  constraint localities_parent_ok check ((kind = 'ville') = (parent_id is null))
);
create index if not exists localities_parent on public.localities (parent_id);
create index if not exists localities_status on public.localities (status);

create or replace function public._locality_refresh() returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.localities; gp public.localities;
begin
  select * into p from public.localities where id = new.parent_id;
  if p.id is not null then select * into gp from public.localities where id = p.parent_id; end if;
  if new.kind = 'commune' and (p.id is null or p.kind <> 'ville') then raise exception 'Une commune doit appartenir à une ville.'; end if;
  if new.kind = 'quartier' and (p.id is null or p.kind not in ('ville', 'commune')) then raise exception 'Un quartier doit appartenir à une commune ou à une ville.'; end if;
  new.search_text := public._norm(concat_ws(' ', new.name, array_to_string(new.aliases, ' '), p.name, gp.name));
  return new;
end $$;
drop trigger if exists localities_refresh on public.localities;
create trigger localities_refresh before insert or update on public.localities for each row execute function public._locality_refresh();

alter table public.localities enable row level security;
drop policy if exists localities_read on public.localities;
create policy localities_read on public.localities for select using (
  status = 'valide' or public.is_platform_admin() or (proposed_by is not null and public.is_org_member(proposed_by)));
revoke insert, update, delete on public.localities from anon, authenticated;
grant select on public.localities to anon, authenticated;

-- Libellé complet « Riviera 2, Cocody, Abidjan » et chaîne des ancêtres
create or replace function public._loc_label(p_id uuid) returns text language sql stable set search_path = '' as $$
  select concat_ws(', ', l.name, p.name, gp.name) from public.localities l
    left join public.localities p on p.id = l.parent_id left join public.localities gp on gp.id = p.parent_id where l.id = p_id;
$$;
create or replace function public._loc_chain(p_id uuid) returns uuid[] language sql stable set search_path = '' as $$
  select array_remove(array[l.id, p.id, gp.id], null) from public.localities l
    left join public.localities p on p.id = l.parent_id left join public.localities gp on gp.id = p.parent_id where l.id = p_id;
$$;

-- ---------------------------------------------------------------- Établissements
alter table public.establishments add column if not exists locality_id uuid references public.localities(id) on delete set null;
alter table public.establishments add column if not exists latitude double precision;
alter table public.establishments add column if not exists longitude double precision;
alter table public.establishments add column if not exists landmark text;
do $$ begin
  alter table public.establishments add constraint establishments_geo_ci check (
    (latitude is null or latitude between 4.0 and 11.0) and (longitude is null or longitude between -9.0 and -2.0));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.establishments add constraint establishments_landmark_len check (landmark is null or length(landmark) <= 200);
exception when duplicate_object then null; end $$;
create index if not exists establishments_locality on public.establishments (locality_id);

-- ---------------------------------------------------------------- Données de départ (coordonnées approximatives, ajustables dans l'administration)
do $$
declare v uuid; c uuid;
begin
  -- Villes
  insert into public.localities (kind, name, slug, aliases, lat, lng) values
    ('ville','Abidjan','abidjan','{"Abj","Babi"}',5.3600,-4.0083),
    ('ville','Grand-Bassam','grand-bassam','{"Bassam"}',5.2118,-3.7388),
    ('ville','Assinie','assinie','{"Assinie-Mafia","Assouindé"}',5.1500,-3.2800),
    ('ville','Yamoussoukro','yamoussoukro','{"Yakro"}',6.8276,-5.2893),
    ('ville','Bouaké','bouake','{}',7.6906,-5.0391),
    ('ville','San-Pédro','san-pedro','{"San Pedro"}',4.7485,-6.6363),
    ('ville','Korhogo','korhogo','{}',9.4580,-5.6296),
    ('ville','Daloa','daloa','{}',6.8774,-6.4502),
    ('ville','Man','man','{}',7.4125,-7.5538),
    ('ville','Sassandra','sassandra','{}',4.9500,-6.0833),
    ('ville','Jacqueville','jacqueville','{}',5.2050,-4.4150),
    ('ville','Grand-Lahou','grand-lahou','{}',5.1400,-5.0200),
    ('ville','Aboisso','aboisso','{}',5.4670,-3.2070),
    ('ville','Dabou','dabou','{}',5.3250,-4.3770),
    ('ville','Gagnoa','gagnoa','{}',6.1310,-5.9510),
    ('ville','Abengourou','abengourou','{}',6.7300,-3.4960),
    ('ville','Odienné','odienne','{}',9.5050,-7.5640)
  on conflict (slug) do nothing;

  -- Communes d'Abidjan
  select id into v from public.localities where slug = 'abidjan';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('commune','Cocody','abidjan-cocody',v,'{}',5.3600,-3.9900),
    ('commune','Plateau','abidjan-plateau',v,'{"Le Plateau"}',5.3197,-4.0170),
    ('commune','Marcory','abidjan-marcory',v,'{}',5.3000,-3.9830),
    ('commune','Yopougon','abidjan-yopougon',v,'{"Yop","Yopougon"}',5.3450,-4.0750),
    ('commune','Koumassi','abidjan-koumassi',v,'{}',5.2950,-3.9500),
    ('commune','Treichville','abidjan-treichville',v,'{"Treich"}',5.2920,-4.0090),
    ('commune','Port-Bouët','abidjan-port-bouet',v,'{"Port Bouet"}',5.2550,-3.9260),
    ('commune','Abobo','abidjan-abobo',v,'{}',5.4180,-4.0200),
    ('commune','Adjamé','abidjan-adjame',v,'{}',5.3600,-4.0230),
    ('commune','Attécoubé','abidjan-attecoube',v,'{}',5.3350,-4.0400),
    ('commune','Bingerville','abidjan-bingerville',v,'{}',5.3550,-3.8850),
    ('commune','Songon','abidjan-songon',v,'{}',5.3100,-4.2600),
    ('commune','Anyama','abidjan-anyama',v,'{}',5.4950,-4.0520)
  on conflict (slug) do nothing;

  -- Quartiers principaux
  select id into c from public.localities where slug = 'abidjan-cocody';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Riviera 2','abidjan-cocody-riviera-2',c,'{"Riviera II","Riv 2"}',5.3610,-3.9600),
    ('quartier','Riviera 3','abidjan-cocody-riviera-3',c,'{"Riviera III","Riv 3"}',5.3690,-3.9520),
    ('quartier','Riviera Palmeraie','abidjan-cocody-riviera-palmeraie',c,'{"Palmeraie"}',5.3720,-3.9440),
    ('quartier','Riviera Golf','abidjan-cocody-riviera-golf',c,'{"Golf"}',5.3350,-3.9650),
    ('quartier','Riviera Faya','abidjan-cocody-riviera-faya',c,'{"Faya"}',5.3760,-3.9150),
    ('quartier','Riviera Bonoumin','abidjan-cocody-riviera-bonoumin',c,'{"Bonoumin"}',5.3620,-3.9480),
    ('quartier','Angré','abidjan-cocody-angre',c,'{"Angre"}',5.3930,-3.9900),
    ('quartier','Deux-Plateaux','abidjan-cocody-deux-plateaux',c,'{"2 Plateaux","II Plateaux","Vallon"}',5.3750,-3.9980),
    ('quartier','Cocody Centre','abidjan-cocody-centre',c,'{"Cocody Danga","Danga"}',5.3330,-4.0000),
    ('quartier','Ambassades','abidjan-cocody-ambassades',c,'{}',5.3420,-4.0030),
    ('quartier','Blockhauss','abidjan-cocody-blockhauss',c,'{"Blockhaus"}',5.3270,-3.9950),
    ('quartier','Mermoz','abidjan-cocody-mermoz',c,'{}',5.3480,-3.9990),
    ('quartier','Saint-Jean','abidjan-cocody-saint-jean',c,'{"St Jean"}',5.3420,-4.0080)
  on conflict (slug) do nothing;
  select id into c from public.localities where slug = 'abidjan-marcory';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Zone 4','abidjan-marcory-zone-4',c,'{"Zone 4C","Zone4"}',5.2850,-3.9900),
    ('quartier','Biétry','abidjan-marcory-bietry',c,'{"Bietry"}',5.2740,-3.9790),
    ('quartier','Anoumabo','abidjan-marcory-anoumabo',c,'{}',5.2950,-3.9750),
    ('quartier','Marcory Résidentiel','abidjan-marcory-residentiel',c,'{"Residentiel"}',5.3040,-3.9900)
  on conflict (slug) do nothing;
  select id into c from public.localities where slug = 'abidjan-plateau';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Plateau Centre','abidjan-plateau-centre',c,'{"Centre des affaires"}',5.3200,-4.0170)
  on conflict (slug) do nothing;
  select id into c from public.localities where slug = 'abidjan-yopougon';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Niangon','abidjan-yopougon-niangon',c,'{}',5.3300,-4.0950),
    ('quartier','Selmer','abidjan-yopougon-selmer',c,'{}',5.3480,-4.0700),
    ('quartier','Sideci','abidjan-yopougon-sideci',c,'{}',5.3360,-4.0680),
    ('quartier','Ananeraie','abidjan-yopougon-ananeraie',c,'{}',5.3550,-4.0870)
  on conflict (slug) do nothing;
  select id into c from public.localities where slug = 'abidjan-port-bouet';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Vridi','abidjan-port-bouet-vridi',c,'{}',5.2600,-4.0000),
    ('quartier','Gonzagueville','abidjan-port-bouet-gonzagueville',c,'{"Gonzague"}',5.2550,-3.8800),
    ('quartier','Aéroport','abidjan-port-bouet-aeroport',c,'{"Aeroport","FHB"}',5.2550,-3.9300)
  on conflict (slug) do nothing;
  select id into c from public.localities where slug = 'abidjan-koumassi';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Remblais','abidjan-koumassi-remblais',c,'{}',5.2900,-3.9600)
  on conflict (slug) do nothing;
  select id into c from public.localities where slug = 'abidjan-treichville';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Treichville Centre','abidjan-treichville-centre',c,'{"Arras"}',5.2920,-4.0090)
  on conflict (slug) do nothing;
  select id into v from public.localities where slug = 'grand-bassam';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Quartier France','grand-bassam-quartier-france',v,'{"Ancien Bassam"}',5.1980,-3.7380),
    ('quartier','Moossou','grand-bassam-moossou',v,'{}',5.2290,-3.7520)
  on conflict (slug) do nothing;
  select id into v from public.localities where slug = 'assinie';
  insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng) values
    ('quartier','Assinie-Mafia','assinie-mafia',v,'{"Mafia"}',5.1340,-3.2830)
  on conflict (slug) do nothing;
end $$;

-- Rattachement des établissements existants à leur ville (sans écraser un choix déjà fait)
update public.establishments e set locality_id = l.id
  from public.localities l
 where e.locality_id is null and l.kind = 'ville' and l.status = 'valide'
   and (public._norm(e.city) = public._norm(l.name) or public._norm(e.city) = any (select public._norm(a) from unnest(l.aliases) a));

-- ---------------------------------------------------------------- Recherche (publique)
-- Suggestions : lieux + établissements publiés, tolérant accents, tirets et variantes d'écriture.
create or replace function public.locality_search(p_q text, p_limit int default 8)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare q text := public._norm(p_q); n int := least(greatest(coalesce(p_limit, 8), 1), 20);
begin
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('type', 'lieu', 'id', l.id, 'kind', l.kind, 'name', l.name, 'slug', l.slug,
             'label', public._loc_label(l.id), 'lat', l.lat, 'lng', l.lng,
             'hotels', (select count(*) from public.establishments e join public.marketplace_listings m on m.establishment_id = e.id
                         where m.listed and e.is_active and l.id = any (public._loc_chain(e.locality_id)))) x,
           (case when l.search_text like q || '%' or public._norm(l.name) like q || '%' then 0 else 1 end) r1,
           (case l.kind when 'ville' then 0 when 'commune' then 1 else 2 end) r2
      from public.localities l
     where l.status = 'valide' and (select bool_and(l.search_text like '%' || t || '%') from unnest(string_to_array(q, ' ')) t)
    union all
    select jsonb_build_object('type', 'hotel', 'slug', e.slug, 'name', coalesce(e.public_name, e.name),
             'label', coalesce(public._loc_label(e.locality_id), e.city)) x, 0, 3
      from public.establishments e join public.marketplace_listings m on m.establishment_id = e.id
     where m.listed and e.is_active and e.slug is not null
       and not exists (select 1 from public.organizations ot where ot.id = e.organization_id and ot.is_test)
       and public._norm(coalesce(e.public_name, e.name)) like '%' || q || '%'
    order by 2, 3 limit n) s), '[]'::jsonb);
end $$;

-- Lieu par identifiant d'URL (pages « Hôtels à Cocody »)
create or replace function public.locality_by_slug(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', l.id, 'kind', l.kind, 'name', l.name, 'slug', l.slug, 'label', public._loc_label(l.id), 'lat', l.lat, 'lng', l.lng,
    'parent', (select jsonb_build_object('name', p.name, 'slug', p.slug) from public.localities p where p.id = l.parent_id),
    'children', coalesce((select jsonb_agg(jsonb_build_object('name', c.name, 'slug', c.slug) order by c.name) from public.localities c where c.parent_id = l.id and c.status = 'valide'), '[]'::jsonb))
  from public.localities l where l.slug = p_slug and l.status = 'valide';
$$;

-- Lieu le plus proche d'un point GPS (préremplissage côté hôtelier)
create or replace function public.locality_nearest(p_lat double precision, p_lng double precision)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare q record; c record; v record;
begin
  if p_lat is null or p_lng is null then return null; end if;
  select l.id, l.name, public._km(p_lat, p_lng, l.lat, l.lng) d into q from public.localities l
   where l.status = 'valide' and l.kind = 'quartier' and l.lat is not null order by 3 limit 1;
  select l.id, l.name, public._km(p_lat, p_lng, l.lat, l.lng) d into c from public.localities l
   where l.status = 'valide' and l.kind = 'commune' and l.lat is not null order by 3 limit 1;
  select l.id, l.name, public._km(p_lat, p_lng, l.lat, l.lng) d into v from public.localities l
   where l.status = 'valide' and l.kind = 'ville' and l.lat is not null order by 3 limit 1;
  if q.id is not null and q.d <= 2.5 then
    return jsonb_build_object('id', q.id, 'label', public._loc_label(q.id), 'kind', 'quartier', 'distance_km', round(q.d::numeric, 2));
  elsif c.id is not null and c.d <= 8 then
    return jsonb_build_object('id', c.id, 'label', public._loc_label(c.id), 'kind', 'commune', 'distance_km', round(c.d::numeric, 2));
  elsif v.id is not null and v.d <= 40 then
    return jsonb_build_object('id', v.id, 'label', public._loc_label(v.id), 'kind', 'ville', 'distance_km', round(v.d::numeric, 2));
  end if;
  return null;
end $$;

-- Proposer un quartier (hôtelier) : visible par son organisation et l'administration, en attente de validation
create or replace function public.locality_propose(p_parent uuid, p_name text, p_lat double precision default null, p_lng double precision default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_par public.localities; v_id uuid; v_slug text;
begin
  select organization_id into v_org from public.organization_members
   where user_id = auth.uid() and is_active and role in ('owner','admin','manager') limit 1;
  if v_org is null and not public.is_platform_admin() then raise exception 'Accès refusé.'; end if;
  if public._rate_hit('loc:propose:' || coalesce(v_org::text, 'admin'), 10, interval '24 hours') then raise exception 'Trop de propositions aujourd''hui.'; end if;
  select * into v_par from public.localities where id = p_parent and status = 'valide';
  if v_par.id is null or v_par.kind = 'quartier' then raise exception 'Choisissez d''abord la commune ou la ville.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Nom de quartier trop court.'; end if;
  select id into v_id from public.localities where parent_id = p_parent and public._norm(name) = public._norm(p_name) limit 1;
  if v_id is not null then return v_id; end if;
  v_slug := v_par.slug || '-' || regexp_replace(public._norm(p_name), ' ', '-', 'g') || '-' || substr(md5(random()::text), 1, 4);
  insert into public.localities (kind, name, slug, parent_id, lat, lng, status, proposed_by)
  values ('quartier', initcap(trim(p_name)), v_slug, p_parent, p_lat, p_lng, case when public.is_platform_admin() then 'valide' else 'propose' end, v_org)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- Administration des lieux
create or replace function public.admin_locality_save(p_id uuid, p_kind text, p_name text, p_parent uuid, p_aliases text[],
  p_lat double precision, p_lng double precision, p_status text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_par public.localities;
begin
  if not public.is_platform_admin() then raise exception 'Accès refusé.'; end if;
  select * into v_par from public.localities where id = p_parent;
  if p_id is null then
    insert into public.localities (kind, name, slug, parent_id, aliases, lat, lng, status)
    values (p_kind, trim(p_name), coalesce(v_par.slug || '-', '') || regexp_replace(public._norm(p_name), ' ', '-', 'g'), p_parent,
            coalesce(p_aliases, '{}'), p_lat, p_lng, coalesce(p_status, 'valide'))
    returning id into v_id;
  else
    update public.localities set kind = coalesce(p_kind, kind), name = coalesce(nullif(trim(p_name), ''), name), parent_id = p_parent,
           aliases = coalesce(p_aliases, aliases), lat = p_lat, lng = p_lng, status = coalesce(p_status, status)
     where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.admin_locality_merge(p_from uuid, p_into uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_platform_admin() then raise exception 'Accès refusé.'; end if;
  if p_from = p_into then raise exception 'Choisissez deux lieux différents.'; end if;
  update public.establishments set locality_id = p_into where locality_id = p_from; get diagnostics n = row_count;
  update public.localities set parent_id = p_into where parent_id = p_from;
  update public.localities set aliases = array(select distinct unnest(aliases || (select array_append(f.aliases, f.name) from public.localities f where f.id = p_from)))
   where id = p_into;
  delete from public.localities where id = p_from;
  return jsonb_build_object('ok', true, 'establishments', n);
end $$;

create or replace function public.admin_localities()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when public.is_platform_admin() then coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'name', l.name, 'slug', l.slug,
    'parent_id', l.parent_id, 'label', public._loc_label(l.id), 'aliases', l.aliases, 'lat', l.lat, 'lng', l.lng, 'status', l.status,
    'proposed_by', (select o.name from public.organizations o where o.id = l.proposed_by),
    'hotels', (select count(*) from public.establishments e where l.id = any (public._loc_chain(e.locality_id))))
    order by case l.status when 'propose' then 0 else 1 end, public._loc_label(l.id)) from public.localities l), '[]'::jsonb) end;
$$;

-- ---------------------------------------------------------------- Recherche d'hôtels enrichie (Nuittea.com)
create or replace function public.market_search2(p_q text default null, p_locality text default null,
  p_lat double precision default null, p_lng double precision default null, p_radius_km double precision default null,
  p_check_in date default null, p_check_out date default null, p_adults int default 1,
  p_max_price numeric default null, p_instant boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_loc public.localities; v_q text := public._norm(p_q); v_lat double precision := p_lat; v_lng double precision := p_lng;
  v_radius double precision := p_radius_km; base jsonb;
begin
  if public._rate_hit('read:ip:' || public._client_ip(), 120, interval '1 minute') then raise exception 'Trop de requêtes : patientez une minute.'; end if;
  if p_locality is not null and p_locality <> '' then
    select * into v_loc from public.localities where (slug = p_locality or id::text = p_locality) and status = 'valide';
  end if;
  -- Quartier : on inclut aussi les hôtels proches (2 km) même rattachés à un quartier voisin
  if v_loc.id is not null and v_loc.kind = 'quartier' and v_lat is null then v_lat := v_loc.lat; v_lng := v_loc.lng; v_radius := coalesce(v_radius, 2); end if;
  base := public.market_search(null, p_check_in, p_check_out, p_adults);
  return coalesce((select jsonb_agg(x order by (x->>'available')::boolean desc, (x->>'distance_km')::numeric nulls last, (x->>'price_from')::numeric nulls last) from (
    select b || jsonb_build_object(
        'locality', public._loc_label(e.locality_id),
        'quartier', (select l.name from public.localities l where l.id = e.locality_id and l.kind = 'quartier'),
        'commune', (select coalesce(p.name, l.name) from public.localities l left join public.localities p on p.id = l.parent_id and p.kind = 'commune'
                     where l.id = e.locality_id and (l.kind = 'commune' or p.id is not null)),
        'landmark', e.landmark, 'lat', e.latitude, 'lng', e.longitude,
        'distance_km', case when v_lat is not null and e.latitude is not null then round(public._km(v_lat, v_lng, e.latitude, e.longitude)::numeric, 1) end) x
      from jsonb_array_elements(base) b join public.establishments e on e.slug = b->>'slug'
     where (v_loc.id is null or v_loc.id = any (public._loc_chain(e.locality_id))
            or (v_loc.kind = 'quartier' and e.latitude is not null and public._km(v_lat, v_lng, e.latitude, e.longitude) <= v_radius)
            or (e.locality_id is null and public._norm(e.city) = public._norm(v_loc.name)))
       and (v_q = '' or v_q is null or public._norm(concat_ws(' ', b->>'name', e.city, public._loc_label(e.locality_id), e.landmark)) like '%' || v_q || '%')
       and (p_max_price is null or (b->>'price_from')::numeric <= p_max_price)
       and (not coalesce(p_instant, false) or (b->>'auto_confirm')::boolean)
       and (v_radius is null or v_lat is null or v_loc.id is not null or (e.latitude is not null and public._km(v_lat, v_lng, e.latitude, e.longitude) <= v_radius))
  ) s), '[]'::jsonb);
end $$;

-- Localisation publique d'un établissement (fiche Nuittea.com)
create or replace function public.market_location(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('label', public._loc_label(e.locality_id), 'landmark', e.landmark, 'lat', e.latitude, 'lng', e.longitude,
    'address', coalesce(e.public_address, e.address), 'city', e.city,
    'locality_slug', (select l.slug from public.localities l where l.id = e.locality_id))
  from public.establishments e join public.marketplace_listings m on m.establishment_id = e.id
  where e.slug = p_slug and m.listed and e.is_active;
$$;

-- Droits
revoke execute on function public._norm(text), public._km(double precision, double precision, double precision, double precision),
  public._loc_label(uuid), public._loc_chain(uuid), public._locality_refresh() from public, anon;
grant execute on function public._norm(text), public._km(double precision, double precision, double precision, double precision),
  public._loc_label(uuid), public._loc_chain(uuid) to authenticated;
revoke execute on function public.locality_search(text, int), public.locality_by_slug(text), public.market_search2(text, text, double precision, double precision, double precision, date, date, int, numeric, boolean),
  public.market_location(text), public.locality_nearest(double precision, double precision), public.locality_propose(uuid, text, double precision, double precision),
  public.admin_locality_save(uuid, text, text, uuid, text[], double precision, double precision, text), public.admin_locality_merge(uuid, uuid), public.admin_localities() from public;
grant execute on function public.locality_search(text, int), public.locality_by_slug(text),
  public.market_search2(text, text, double precision, double precision, double precision, date, date, int, numeric, boolean), public.market_location(text) to anon, authenticated;
grant execute on function public.locality_nearest(double precision, double precision), public.locality_propose(uuid, text, double precision, double precision),
  public.admin_locality_save(uuid, text, text, uuid, text[], double precision, double precision, text), public.admin_locality_merge(uuid, uuid), public.admin_localities() to authenticated;
