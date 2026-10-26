-- 36 · Passes (séjours de quelques heures), gérés à la réception uniquement.
-- • pass_formulas : tarifs fixés par l'hôtel (libellé, durée, prix, type de chambre facultatif).
-- • room_passes : chaque passe (chambre, début, fin prévue, prix, client facultatif).
-- Règles : deux passes ne se chevauchent pas sur une chambre ; une chambre réservée pour la nuit
-- (arrivée ce jour-là, séjour en cours ou client présent le jour de son départ) ne peut pas recevoir de passe.
-- Migration additive : aucune table existante n'est modifiée.

create extension if not exists btree_gist;

create table if not exists public.pass_formulas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  label text not null check (length(trim(label)) between 1 and 60),
  hours numeric(4,1) not null check (hours > 0 and hours <= 12),
  price numeric(12,2) not null check (price >= 0),
  room_type text check (room_type is null or length(room_type) <= 60),
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists pass_formulas_est on public.pass_formulas (establishment_id);

create table if not exists public.room_passes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  establishment_id uuid not null references public.establishments(id) on delete restrict,
  room_id uuid not null references public.rooms(id) on delete restrict,
  formula_id uuid references public.pass_formulas(id) on delete set null,
  label text not null check (length(label) <= 80),
  hours numeric(4,1) not null check (hours > 0 and hours <= 12),
  price numeric(12,2) not null check (price >= 0),
  start_at timestamptz not null default now(),
  end_at timestamptz not null,
  ended_at timestamptz,
  status text not null default 'active' check (status in ('active', 'done', 'cancelled')),
  guest_name text check (guest_name is null or length(guest_name) <= 120),
  guest_phone text check (guest_phone is null or length(guest_phone) <= 30),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint room_passes_time check (end_at > start_at),
  constraint room_passes_no_overlap exclude using gist (room_id with =, tstzrange(start_at, end_at, '[)') with &&) where (status <> 'cancelled')
);
create index if not exists room_passes_est_start on public.room_passes (establishment_id, start_at desc);

-- Cohérence et règle « chambre réservée pour la nuit »
create or replace function public.guard_room_pass() returns trigger language plpgsql security definer set search_path = '' as $$
declare rm public.rooms; d date;
begin
  select * into rm from public.rooms where id = new.room_id;
  if rm.id is null or not rm.is_active then raise exception 'Chambre introuvable ou hors service.'; end if;
  new.organization_id := rm.organization_id; new.establishment_id := rm.establishment_id;
  perform public.assert_org_writable(new.organization_id);
  if tg_op = 'INSERT' or new.start_at is distinct from old.start_at or new.end_at is distinct from old.end_at or new.room_id is distinct from old.room_id then
    if new.status = 'active' then
      if rm.housekeeping_status = 'out_of_service' then raise exception 'Cette chambre est hors service.'; end if;
      d := (new.start_at at time zone 'Africa/Abidjan')::date;
      if exists (select 1 from public.reservations r where r.room_id = new.room_id
                   and r.status in ('pending', 'confirmed', 'checked_in')
                   and ((r.check_in <= d and r.check_out > d) or (r.status = 'checked_in' and r.check_out = d))) then
        raise exception 'Cette chambre est réservée pour la nuit : pas de passe possible aujourd''hui.';
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_room_pass on public.room_passes;
create trigger trg_guard_room_pass before insert or update on public.room_passes for each row execute function public.guard_room_pass();

create or replace function public.sync_pass_formula_org() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  select organization_id into new.organization_id from public.establishments where id = new.establishment_id;
  if new.organization_id is null then raise exception 'Établissement introuvable.'; end if;
  return new;
end $$;
drop trigger if exists trg_sync_pass_formula_org on public.pass_formulas;
create trigger trg_sync_pass_formula_org before insert or update on public.pass_formulas for each row execute function public.sync_pass_formula_org();

alter table public.pass_formulas enable row level security;
alter table public.room_passes enable row level security;
drop policy if exists pass_formulas_select on public.pass_formulas;
drop policy if exists pass_formulas_write on public.pass_formulas;
drop policy if exists room_passes_select on public.room_passes;
drop policy if exists room_passes_insert on public.room_passes;
drop policy if exists room_passes_update on public.room_passes;
create policy pass_formulas_select on public.pass_formulas for select using (public.is_org_member(organization_id));
create policy pass_formulas_write on public.pass_formulas for all using (public.has_org_role(organization_id, array['owner','admin','manager']))
  with check (public.has_org_role(organization_id, array['owner','admin','manager']));
create policy room_passes_select on public.room_passes for select using (public.is_org_member(organization_id));
create policy room_passes_insert on public.room_passes for insert with check (public.has_org_role(organization_id, array['owner','admin','manager','receptionist']));
create policy room_passes_update on public.room_passes for update using (public.has_org_role(organization_id, array['owner','admin','manager','receptionist']))
  with check (public.has_org_role(organization_id, array['owner','admin','manager','receptionist']));
grant select, insert, update on public.room_passes to authenticated;
grant select, insert, update, delete on public.pass_formulas to authenticated;
