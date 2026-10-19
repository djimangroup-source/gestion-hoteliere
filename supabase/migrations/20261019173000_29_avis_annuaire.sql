-- Horus Hotel — Migration 29 : avis clients et annuaire public.
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  reservation_id uuid unique references public.reservations(id) on delete set null,
  guest_name text check (guest_name is null or length(guest_name) <= 120),
  token uuid not null unique default gen_random_uuid(),
  rating int check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 1000),
  status text not null default 'pending' check (status in ('pending','submitted')),
  is_published boolean not null default true,
  reply text check (reply is null or length(reply) <= 1000),
  created_at timestamptz not null default now(),
  submitted_at timestamptz
);
create index if not exists reviews_est on public.reviews (establishment_id, submitted_at desc);
alter table public.reviews enable row level security;
create policy reviews_select on public.reviews for select using (public.is_org_member(organization_id));
create policy reviews_update on public.reviews for update using (public.has_org_role(organization_id, array['owner','admin','manager'])) with check (public.has_org_role(organization_id, array['owner','admin','manager']));
grant select, update on public.reviews to authenticated;

-- Demande d'avis pour un séjour (crée le lien unique)
create or replace function public.request_review(p_reservation uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v uuid;
begin
  select * into r from public.reservations where id = p_reservation;
  if r.id is null or not public.has_org_role(r.organization_id, array['owner','admin','manager','receptionist']) then raise exception 'Accès refusé.'; end if;
  select token into v from public.reviews where reservation_id = r.id;
  if v is not null then return v; end if;
  insert into public.reviews (organization_id, establishment_id, reservation_id, guest_name) values (r.organization_id, r.establishment_id, r.id, r.guest_name) returning token into v;
  return v;
end $$;
revoke execute on function public.request_review(uuid) from public, anon;
grant execute on function public.request_review(uuid) to authenticated;

-- Page d'avis publique (lien envoyé au client)
create or replace function public.public_review_get(p_token uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when v.id is null then jsonb_build_object('ok', false) else jsonb_build_object('ok', true, 'status', v.status, 'rating', v.rating,
    'guest', split_part(coalesce(v.guest_name, ''), ' ', 1), 'name', coalesce(e.public_name, e.name), 'logo', e.public_logo_url, 'slug', case when e.public_enabled then e.slug end) end
  from (select 1) d left join public.reviews v on v.token = p_token left join public.establishments e on e.id = v.establishment_id;
$$;
create or replace function public.public_review_submit(p_token uuid, p_rating int, p_comment text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v public.reviews;
begin
  select * into v from public.reviews where token = p_token for update;
  if v.id is null then return jsonb_build_object('ok', false, 'error', 'Lien invalide.'); end if;
  if v.status = 'submitted' then return jsonb_build_object('ok', false, 'error', 'Merci, votre avis a déjà été enregistré.'); end if;
  if p_rating is null or p_rating not between 1 and 5 then return jsonb_build_object('ok', false, 'error', 'Choisissez une note de 1 à 5.'); end if;
  if v.created_at < now() - interval '90 days' then return jsonb_build_object('ok', false, 'error', 'Ce lien a expiré.'); end if;
  update public.reviews set rating = p_rating, comment = nullif(left(trim(coalesce(p_comment, '')), 1000), ''), status = 'submitted', submitted_at = now() where id = v.id;
  if p_rating <= 2 then
    insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message, entity, entity_id)
    values (v.organization_id, v.establishment_id, 'warning', 'review', 'Avis négatif (' || p_rating || '/5) de ' || coalesce(v.guest_name, 'un client') || coalesce(' : ' || left(nullif(trim(coalesce(p_comment, '')), ''), 200), ''), 'review', v.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;
-- Avis publiés d'un établissement (page de présentation)
create or replace function public.public_reviews(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments;
begin
  select * into e from public.establishments where slug = p_slug and public_enabled and is_active;
  if e.id is null then return jsonb_build_object('count', 0); end if;
  return jsonb_build_object(
    'count', (select count(*) from public.reviews where establishment_id = e.id and status = 'submitted' and is_published),
    'avg', (select round(avg(rating), 1) from public.reviews where establishment_id = e.id and status = 'submitted' and is_published),
    'items', (select coalesce(jsonb_agg(x), '[]') from (select split_part(coalesce(guest_name, 'Client'), ' ', 1) guest, rating, comment, reply, submitted_at::date d
              from public.reviews where establishment_id = e.id and status = 'submitted' and is_published order by submitted_at desc limit 12) x));
end $$;
revoke execute on function public.public_review_get(uuid), public.public_review_submit(uuid, int, text), public.public_reviews(text) from public;
grant execute on function public.public_review_get(uuid), public.public_review_submit(uuid, int, text), public.public_reviews(text) to anon, authenticated;

-- Annuaire public : établissements avec une page publiée
alter table public.establishments add column if not exists directory_listed boolean not null default true;
create or replace function public.public_directory(p_city text default null, p_q text default null, p_max_price numeric default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by x.rating desc nulls last, x.name), '[]') from (
    select e.slug, coalesce(e.public_name, e.name) as name, e.city, e.public_tagline as tagline, e.public_cover_url as cover, e.public_logo_url as logo, e.public_theme as theme,
      (select min(r.base_rate) from public.rooms r where r.establishment_id = e.id and r.is_active and r.base_rate > 0) as price_from,
      (select round(avg(v.rating), 1) from public.reviews v where v.establishment_id = e.id and v.status = 'submitted' and v.is_published) as rating,
      (select count(*) from public.reviews v where v.establishment_id = e.id and v.status = 'submitted' and v.is_published) as reviews
    from public.establishments e
    where e.public_enabled and e.is_active and e.directory_listed and e.slug is not null
      and public.org_has_feature(e.organization_id, 'online_booking')
      and (p_city is null or p_city = '' or lower(e.city) = lower(p_city))
      and (p_q is null or p_q = '' or coalesce(e.public_name, e.name) ilike '%' || p_q || '%' or e.city ilike '%' || p_q || '%')
  ) x where p_max_price is null or x.price_from is null or x.price_from <= p_max_price;
$$;
revoke execute on function public.public_directory(text, text, numeric) from public;
grant execute on function public.public_directory(text, text, numeric) to anon, authenticated;
