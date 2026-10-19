-- Horus Hotel — Migration 30 : inventaire hébergement (linge, produits d'accueil, entretien) et pointage du personnel.
create table if not exists public.supplies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  category text not null default 'Linge' check (length(category) <= 40),
  unit text not null default 'pièce' check (length(unit) <= 20),
  qty numeric not null default 0,
  alert_qty numeric not null default 0 check (alert_qty >= 0),
  unit_cost numeric not null default 0 check (unit_cost >= 0),
  per_room numeric check (per_room is null or per_room >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.supply_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  supply_id uuid not null references public.supplies(id) on delete cascade,
  kind text not null check (kind in ('in','out','loss','adjust')),
  qty numeric not null,
  balance_after numeric,
  room_id uuid references public.rooms(id) on delete set null,
  note text check (note is null or length(note) <= 200),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists supply_mv_item on public.supply_movements (supply_id, created_at desc);
alter table public.supplies enable row level security;
alter table public.supply_movements enable row level security;
create policy supplies_select on public.supplies for select using (public.is_org_member(organization_id));
create policy supplies_insert on public.supplies for insert with check (public.has_org_role(organization_id, array['owner','admin','manager']));
create policy supplies_update on public.supplies for update using (public.has_org_role(organization_id, array['owner','admin','manager'])) with check (public.has_org_role(organization_id, array['owner','admin','manager']));
create policy supply_mv_select on public.supply_movements for select using (public.is_org_member(organization_id));
grant select, insert, update on public.supplies to authenticated;
grant select on public.supply_movements to authenticated;
create trigger trg_00_supplies_org before insert or update on public.supplies for each row execute function public.sync_org_from_establishment();
create trigger trg_supplies_writable before insert or update on public.supplies for each row execute function public.guard_org_writable();

create or replace function public.supply_move(p_item uuid, p_kind text, p_qty numeric, p_note text default null, p_room uuid default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare s public.supplies; v_new numeric; v_delta numeric;
begin
  select * into s from public.supplies where id = p_item for update;
  if s.id is null then raise exception 'Article introuvable.'; end if;
  if not public.has_org_role(s.organization_id, array['owner','admin','manager','receptionist','housekeeping']) then raise exception 'Accès refusé.'; end if;
  if p_kind = 'adjust' and not public.has_org_role(s.organization_id, array['owner','admin','manager']) then raise exception 'Seul un gérant peut corriger l’inventaire.'; end if;
  perform public.assert_org_writable(s.organization_id);
  if p_kind not in ('in','out','loss','adjust') then raise exception 'Mouvement invalide.'; end if;
  if p_qty is null or p_qty < 0 or (p_kind <> 'adjust' and p_qty = 0) then raise exception 'Quantité invalide.'; end if;
  if p_kind = 'loss' and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'Indiquez la raison (usé, taché, perdu…).'; end if;
  v_new := case p_kind when 'in' then s.qty + p_qty when 'adjust' then p_qty else s.qty - p_qty end;
  if v_new < 0 then raise exception 'Stock insuffisant : il reste % %.', s.qty, s.unit; end if;
  v_delta := v_new - s.qty;
  update public.supplies set qty = v_new where id = s.id;
  insert into public.supply_movements (organization_id, establishment_id, supply_id, kind, qty, balance_after, room_id, note)
  values (s.organization_id, s.establishment_id, s.id, p_kind, v_delta, v_new, p_room, nullif(trim(coalesce(p_note, '')), ''));
  return v_new;
end $$;
revoke execute on function public.supply_move(uuid, text, numeric, text, uuid) from public, anon;
grant execute on function public.supply_move(uuid, text, numeric, text, uuid) to authenticated;

-- Pointage
create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid references public.establishments(id) on delete set null,
  user_id uuid not null references auth.users(id) on delete cascade,
  clock_in timestamptz not null default now(),
  clock_out timestamptz check (clock_out is null or clock_out >= clock_in),
  note text check (note is null or length(note) <= 200),
  edited_by uuid
);
create index if not exists attendance_org on public.attendance (organization_id, clock_in desc);
create unique index if not exists attendance_one_open on public.attendance (organization_id, user_id) where clock_out is null;
alter table public.attendance enable row level security;
create policy attendance_select on public.attendance for select using (user_id = auth.uid() or public.has_org_role(organization_id, array['owner','admin','manager','accountant']));
grant select on public.attendance to authenticated;

create or replace function public.clock(p_org uuid, p_est uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v public.attendance;
begin
  if not public.is_org_member(p_org) then raise exception 'Accès refusé.'; end if;
  select * into v from public.attendance where organization_id = p_org and user_id = auth.uid() and clock_out is null;
  if p_action = 'in' then
    if v.id is not null then return jsonb_build_object('ok', true, 'state', 'in', 'since', v.clock_in); end if;
    insert into public.attendance (organization_id, establishment_id, user_id) values (p_org, p_est, auth.uid()) returning * into v;
    return jsonb_build_object('ok', true, 'state', 'in', 'since', v.clock_in);
  elsif p_action = 'out' then
    if v.id is null then raise exception 'Vous n’avez pas pointé votre arrivée.'; end if;
    update public.attendance set clock_out = now() where id = v.id returning * into v;
    return jsonb_build_object('ok', true, 'state', 'out', 'minutes', round(extract(epoch from (v.clock_out - v.clock_in)) / 60));
  else
    return jsonb_build_object('ok', true, 'state', case when v.id is null then 'out' else 'in' end, 'since', v.clock_in);
  end if;
end $$;
-- Correction par le gérant (oubli de pointage)
create or replace function public.attendance_fix(p_id uuid, p_in timestamptz, p_out timestamptz, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.attendance;
begin
  select * into v from public.attendance where id = p_id;
  if v.id is null or not public.has_org_role(v.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if p_out is not null and p_out < p_in then raise exception 'L’heure de départ doit suivre l’arrivée.'; end if;
  update public.attendance set clock_in = p_in, clock_out = p_out, note = nullif(trim(coalesce(p_note, '')), ''), edited_by = auth.uid() where id = p_id;
  insert into public.audit_log (organization_id, establishment_id, entity, entity_id, action, summary, details, actor_id)
  values (v.organization_id, v.establishment_id, 'pointage', v.id, 'correction', 'Pointage corrigé', jsonb_build_object('avant', jsonb_build_object('in', v.clock_in, 'out', v.clock_out), 'apres', jsonb_build_object('in', p_in, 'out', p_out), 'note', p_note), auth.uid());
end $$;
revoke execute on function public.clock(uuid, uuid, text), public.attendance_fix(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.clock(uuid, uuid, text), public.attendance_fix(uuid, timestamptz, timestamptz, text) to authenticated;
