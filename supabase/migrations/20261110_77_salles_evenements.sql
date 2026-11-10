-- 77 · Salles et événements (conférence, fête, réunion…) + demandes de devis depuis Nuittea.com.
-- Ajouts uniquement. Fonction « venues » ajoutée aux formules Essai, Pro, Premium et Groupe.

update public.plans set features = features || '["venues"]'::jsonb where slug in ('essai', 'pro', 'premium-plus', 'groupe') and not features ? 'venues';

create table if not exists public.venues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 80),
  kind text not null default 'conference' check (kind in ('conference', 'fete', 'reunion', 'terrasse', 'jardin', 'autre')),
  description text check (description is null or length(description) <= 1500),
  photos jsonb not null default '[]' check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 10),
  amenities text[] not null default '{}',
  capacity jsonb not null default '{}',
  area_m2 int check (area_m2 is null or area_m2 between 5 and 20000),
  rate_hour numeric check (rate_hour is null or rate_hour >= 0),
  rate_half numeric check (rate_half is null or rate_half >= 0),
  rate_day numeric check (rate_day is null or rate_day >= 0),
  rate_evening numeric check (rate_evening is null or rate_evening >= 0),
  weekend_pct numeric not null default 0 check (weekend_pct between 0 and 200),
  setup_minutes int not null default 60 check (setup_minutes between 0 and 720),
  public_listed boolean not null default false,
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists venues_est_idx on public.venues (establishment_id);

create table if not exists public.venue_services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 80),
  unit text not null default 'personne' check (unit in ('personne', 'forfait', 'heure', 'unite')),
  price numeric not null default 0 check (price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.venue_events (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete restrict,
  title text not null check (length(trim(title)) between 2 and 120),
  kind text not null default 'seminaire' check (kind in ('seminaire', 'reunion', 'mariage', 'anniversaire', 'bapteme', 'funerailles', 'conference', 'formation', 'soiree', 'autre')),
  guest_id uuid references public.guests(id) on delete set null,
  client_name text not null check (length(trim(client_name)) between 2 and 120),
  client_phone text, client_email text,
  starts_at timestamptz not null, ends_at timestamptz not null check (ends_at > starts_at),
  setup_before int not null default 60, setup_after int not null default 60,
  attendees int check (attendees is null or attendees between 1 and 20000),
  layout text check (layout is null or layout in ('theatre', 'classe', 'banquet', 'cocktail', 'u')),
  status text not null default 'option' check (status in ('request', 'option', 'confirmed', 'in_progress', 'done', 'cancelled')),
  option_until date,
  rate_mode text not null default 'day' check (rate_mode in ('hour', 'half', 'day', 'evening', 'custom')),
  room_amount numeric not null default 0 check (room_amount >= 0),
  discount numeric not null default 0 check (discount >= 0),
  group_id uuid references public.reservation_groups(id) on delete set null,
  source text not null default 'direct' check (source in ('direct', 'telephone', 'whatsapp', 'nuittea')),
  notes text check (notes is null or length(notes) <= 2000),
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  block_start timestamptz, block_end timestamptz,
  constraint venue_events_no_overlap exclude using gist (venue_id with =, tstzrange(block_start, block_end, '[)') with &&)
    where (status in ('option', 'confirmed', 'in_progress'))
);
create index if not exists venue_events_est_idx on public.venue_events (establishment_id, starts_at);

create table if not exists public.venue_event_items (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.venue_events(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  service_id uuid references public.venue_services(id) on delete set null,
  label text not null check (length(trim(label)) between 1 and 120),
  qty numeric not null default 1 check (qty > 0),
  unit_price numeric not null default 0 check (unit_price >= 0)
);

alter table public.cash_movements add column if not exists venue_event_id uuid references public.venue_events(id) on delete set null;
create index if not exists cash_movements_event_idx on public.cash_movements (venue_event_id) where venue_event_id is not null;

-- Organisation renseignée automatiquement depuis l'établissement / l'événement
create or replace function public._venue_sync_org() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_table_name = 'venue_event_items' then
    select organization_id into new.organization_id from public.venue_events where id = new.event_id;
  else
    select organization_id into new.organization_id from public.establishments where id = new.establishment_id;
  end if;
  if tg_table_name = 'venue_events' then
    perform 1 from public.venues where id = new.venue_id and establishment_id = new.establishment_id;
    if not found then raise exception 'Salle introuvable pour cet établissement.'; end if;
    new.block_start := new.starts_at - make_interval(mins => new.setup_before);
    new.block_end := new.ends_at + make_interval(mins => new.setup_after);
    new.updated_at := now();
  end if;
  return new;
end $$;
create trigger trg_venues_org before insert or update on public.venues for each row execute function public._venue_sync_org();
create trigger trg_vservices_org before insert or update on public.venue_services for each row execute function public._venue_sync_org();
create trigger trg_vevents_org before insert or update on public.venue_events for each row execute function public._venue_sync_org();
create trigger trg_vitems_org before insert or update on public.venue_event_items for each row execute function public._venue_sync_org();

alter table public.venues enable row level security;
alter table public.venue_services enable row level security;
alter table public.venue_events enable row level security;
alter table public.venue_event_items enable row level security;

create policy ven_select on public.venues for select using ((select public.is_org_member(organization_id)) or (select public.staff_can('dashboard')));
create policy ven_write on public.venues for all using ((select public.has_org_role(organization_id, array['owner','admin','manager'])) and (select public.org_has_feature(organization_id, 'venues')))
  with check ((select public.has_org_role(organization_id, array['owner','admin','manager'])) and (select public.org_has_feature(organization_id, 'venues')));
create policy vsv_select on public.venue_services for select using ((select public.is_org_member(organization_id)));
create policy vsv_write on public.venue_services for all using ((select public.has_org_role(organization_id, array['owner','admin','manager'])) and (select public.org_has_feature(organization_id, 'venues')))
  with check ((select public.has_org_role(organization_id, array['owner','admin','manager'])) and (select public.org_has_feature(organization_id, 'venues')));
create policy vev_select on public.venue_events for select using ((select public.is_org_member(organization_id)));
create policy vev_write on public.venue_events for all using ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist'])) and (select public.org_has_feature(organization_id, 'venues')))
  with check ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist'])) and (select public.org_has_feature(organization_id, 'venues')));
create policy vit_select on public.venue_event_items for select using ((select public.is_org_member(organization_id)));
create policy vit_write on public.venue_event_items for all using ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist'])))
  with check ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist'])));

-- Soldes des événements
create or replace view public.venue_event_balances with (security_invoker = true) as
select e.*, v.name as venue_name,
  coalesce((select sum(i.qty * i.unit_price) from public.venue_event_items i where i.event_id = e.id), 0) as items_amount,
  greatest(e.room_amount + coalesce((select sum(i.qty * i.unit_price) from public.venue_event_items i where i.event_id = e.id), 0) - e.discount, 0) as total_amount,
  coalesce((select sum(case when m.kind = 'refund' then -m.amount else m.amount end) from public.cash_movements m where m.venue_event_id = e.id), 0) as paid
from public.venue_events e join public.venues v on v.id = e.venue_id;
grant select on public.venue_event_balances to authenticated;

-- ===== Nuittea.com : salles publiques et demandes de devis =====
create or replace function public.public_venues(p_city text default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if public._rate_hit('read:ip:' || public._client_ip(), 120, interval '1 minute') then raise exception 'Trop de requêtes : patientez une minute.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'hotel', x->>'name') from (
    select jsonb_build_object('id', v.id, 'name', v.name, 'kind', v.kind, 'description', v.description, 'photos', v.photos, 'amenities', to_jsonb(v.amenities),
      'capacity', v.capacity, 'area_m2', v.area_m2, 'rate_hour', v.rate_hour, 'rate_half', v.rate_half, 'rate_day', v.rate_day, 'rate_evening', v.rate_evening,
      'hotel', coalesce(e.public_name, e.name), 'slug', e.slug, 'city', e.city, 'cover', e.public_cover_url) x
    from public.venues v join public.establishments e on e.id = v.establishment_id join public.marketplace_listings m on m.establishment_id = e.id
    where v.public_listed and v.is_active and m.listed and public._review_ok(m.review_status) and e.is_active and e.nuittea_suspended_at is null and e.slug is not null
      and public.org_has_feature(e.organization_id, 'venues')
      and not exists (select 1 from public.organizations o where o.id = e.organization_id and o.is_test)
      and (p_city is null or p_city = '' or e.city ilike '%' || p_city || '%' or coalesce(e.public_name, e.name) ilike '%' || p_city || '%')) s), '[]');
end $$;

create or replace function public.public_venue_request(p_venue uuid, p_date date, p_start time, p_end time, p_attendees int, p_kind text, p_name text, p_phone text, p_email text default null, p_message text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v public.venues; v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); v_start timestamptz; v_end timestamptz; v_id uuid; v_num bigint; v_busy boolean;
begin
  if public._rate_hit('venue:ip:' || public._client_ip(), 5, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'Trop de demandes depuis cette connexion. Réessayez plus tard.'); end if;
  select x.* into v from public.venues x join public.establishments e on e.id = x.establishment_id join public.marketplace_listings m on m.establishment_id = e.id
   where x.id = p_venue and x.public_listed and x.is_active and m.listed and e.is_active and e.nuittea_suspended_at is null and public.org_has_feature(e.organization_id, 'venues');
  if v.id is null then return jsonb_build_object('ok', false, 'error', 'Salle indisponible.'); end if;
  if length(trim(coalesce(p_name, ''))) < 2 then return jsonb_build_object('ok', false, 'error', 'Indiquez votre nom.'); end if;
  if v_phone !~ '^\+?[0-9]{8,15}$' then return jsonb_build_object('ok', false, 'error', 'Numéro de téléphone invalide.'); end if;
  if p_date is null or p_date < current_date or p_date > current_date + 730 then return jsonb_build_object('ok', false, 'error', 'Date invalide.'); end if;
  if p_start is null or p_end is null then return jsonb_build_object('ok', false, 'error', 'Indiquez les heures.'); end if;
  v_start := (p_date + p_start) at time zone 'Africa/Abidjan';
  v_end := (case when p_end > p_start then p_date else p_date + 1 end + p_end) at time zone 'Africa/Abidjan';
  if length(coalesce(p_message, '')) > 1000 then return jsonb_build_object('ok', false, 'error', 'Message trop long.'); end if;
  v_busy := exists (select 1 from public.venue_events x where x.venue_id = v.id and x.status in ('option', 'confirmed', 'in_progress')
    and tstzrange(x.block_start, x.block_end) && tstzrange(v_start, v_end));
  insert into public.venue_events (establishment_id, venue_id, title, kind, client_name, client_phone, client_email, starts_at, ends_at, setup_before, setup_after,
    attendees, status, source, notes)
  values (v.establishment_id, v.id, left(initcap(coalesce(nullif(p_kind, ''), 'autre')) || ' · ' || trim(p_name), 120),
    case when p_kind in ('seminaire', 'reunion', 'mariage', 'anniversaire', 'bapteme', 'funerailles', 'conference', 'formation', 'soiree') then p_kind else 'autre' end,
    trim(p_name), v_phone, nullif(trim(coalesce(p_email, '')), ''), v_start, v_end, v.setup_minutes, v.setup_minutes,
    nullif(p_attendees, 0), 'request', 'nuittea', nullif(trim(coalesce(p_message, '')), '')) returning id, number into v_id, v_num;
  insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message)
  values (v.organization_id, v.establishment_id, 'info', 'venue_request', format('Nouvelle demande de devis Nuittea pour « %s » le %s (%s personnes) : %s, %s.', v.name, to_char(p_date, 'DD/MM/YYYY'), coalesce(p_attendees::text, '?'), trim(p_name), v_phone));
  return jsonb_build_object('ok', true, 'number', v_num, 'busy', v_busy,
    'hotel_phone', (select public_phone from public.establishments where id = v.establishment_id), 'hotel_whatsapp', (select public_whatsapp from public.establishments where id = v.establishment_id));
end $$;
grant execute on function public.public_venues(text), public.public_venue_request(uuid, date, time, time, int, text, text, text, text, text) to anon, authenticated;
