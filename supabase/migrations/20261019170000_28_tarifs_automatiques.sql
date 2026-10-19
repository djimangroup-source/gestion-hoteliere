-- Horus Hotel — Migration 28 : tarifs automatiques (week-end, saisons, jours de fête).
-- Règle = jours de semaine et/ou période, type de chambre facultatif, ajustement (% , montant, prix fixe), priorité.
create table if not exists public.rate_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  weekdays int[] check (weekdays is null or weekdays <@ array[1,2,3,4,5,6,7]),
  date_from date, date_to date check (date_to is null or date_from is null or date_to >= date_from),
  room_type text check (room_type is null or length(room_type) <= 60),
  adjust text not null check (adjust in ('percent','amount','fixed')),
  value numeric not null check (value > -100000000 and value < 100000000),
  priority int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists rate_rules_est on public.rate_rules (establishment_id) where is_active;
alter table public.rate_rules enable row level security;
create policy rate_rules_select on public.rate_rules for select using (public.is_org_member(organization_id));
create policy rate_rules_write on public.rate_rules for all using (public.has_org_role(organization_id, array['owner','admin','manager'])) with check (public.has_org_role(organization_id, array['owner','admin','manager']));
grant select, insert, update, delete on public.rate_rules to authenticated;
create trigger trg_00_rate_rules_org before insert or update on public.rate_rules for each row execute function public.sync_org_from_establishment();
create trigger trg_rate_rules_writable before insert or update on public.rate_rules for each row execute function public.guard_org_writable();

-- Calcul interne (sans contrôle d'accès) : prix nuit par nuit
create or replace function public._stay_price(p_room uuid, p_in date, p_out date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.rooms; d date; v_base numeric; v_price numeric; ru public.rate_rules; v_total numeric := 0; v_n int := 0; v_detail jsonb := '[]'; v_on boolean;
begin
  select * into r from public.rooms where id = p_room;
  if r.id is null or p_out <= p_in then return null; end if;
  v_base := coalesce(r.base_rate, 0);
  v_on := public.org_has_feature(r.organization_id, 'seasonal_rates');
  d := p_in;
  while d < p_out loop
    v_price := v_base; ru := null;
    if v_on then
      select * into ru from public.rate_rules x
       where x.establishment_id = r.establishment_id and x.is_active
         and (x.room_type is null or x.room_type = coalesce(nullif(trim(r.room_type), ''), 'Chambre'))
         and (x.weekdays is null or cardinality(x.weekdays) = 0 or extract(isodow from d)::int = any(x.weekdays))
         and (x.date_from is null or d >= x.date_from) and (x.date_to is null or d <= x.date_to)
       order by x.priority desc, (x.date_from is not null) desc, x.created_at desc limit 1;
      if ru.id is not null then
        v_price := case ru.adjust when 'percent' then round(v_base * (1 + ru.value / 100.0))
                                  when 'amount' then v_base + ru.value else ru.value end;
        v_price := greatest(v_price, 0);
      end if;
    end if;
    v_total := v_total + v_price; v_n := v_n + 1;
    v_detail := v_detail || jsonb_build_object('d', d, 'price', v_price, 'rule', ru.name);
    d := d + 1;
  end loop;
  return jsonb_build_object('nights', v_n, 'base', v_base, 'total', v_total, 'rate', ceil(v_total / v_n), 'rounding', ceil(v_total / v_n) * v_n - v_total,
                            'adjusted', exists (select 1 from jsonb_array_elements(v_detail) e where e->>'rule' is not null), 'detail', v_detail);
end $$;
revoke execute on function public._stay_price(uuid, date, date) from public, anon, authenticated;

create or replace function public.stay_price(p_room uuid, p_in date, p_out date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.rooms where id = p_room;
  if v_org is null or not public.is_org_member(v_org) then raise exception 'Accès refusé.'; end if;
  if p_out - p_in > 366 then raise exception 'Séjour trop long.'; end if;
  return public._stay_price(p_room, p_in, p_out);
end $$;
revoke execute on function public.stay_price(uuid, date, date) from public, anon;
grant execute on function public.stay_price(uuid, date, date) to authenticated;

-- Réservation en ligne : devis et création au prix calculé
create or replace function public.public_quote(p_slug text, p_room_type text, p_check_in date, p_check_out date, p_adults integer)
 returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare e public.establishments; v_room record; v_n int; p jsonb;
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
  p := public._stay_price(v_room.id, p_check_in, p_check_out);
  return jsonb_build_object('ok', true, 'nights', v_n, 'rate', (p->>'rate')::numeric, 'total', (p->>'total')::numeric, 'adjusted', p->'adjusted');
end $function$;

-- public_create_booking : prix moyen arrondi + remise d'arrondi pour un total exact
do $$ declare d text;
begin
  d := pg_get_functiondef('public.public_create_booking'::regproc);
  if position('v_room.base_rate, 0, ''en_ligne''' in d) > 0 then
    d := replace(d, 'v_room.base_rate, 0, ''en_ligne''', '(q->>''rate'')::numeric, (q->>''rate'')::numeric * (p_check_out - p_check_in) - (q->>''total'')::numeric, ''en_ligne''');
    execute d;
  end if;
end $$;
