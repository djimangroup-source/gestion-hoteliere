-- 70 · Multicaisse : plusieurs caisses par établissement (Réception, Bar, Nuit…).
-- Ajouts, plus un remplacement de règle : « une caisse ouverte par établissement » devient « une session ouverte par caisse ».
-- Aucune donnée supprimée ; les sessions existantes sont rattachées à la caisse « Réception » créée pour chaque établissement.

create table if not exists public.cash_registers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null check (length(name) between 2 and 40),
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists cash_registers_est_name_uq on public.cash_registers (establishment_id, lower(name));
create index if not exists cash_registers_org_idx on public.cash_registers (organization_id);
alter table public.cash_registers enable row level security;
create policy creg_select on public.cash_registers for select using ((select public.is_org_member(organization_id)) or (select public.is_platform_admin()));
create policy creg_insert on public.cash_registers for insert with check ((select public.has_org_role(organization_id, array['owner','admin','manager'])));
create policy creg_update on public.cash_registers for update using ((select public.has_org_role(organization_id, array['owner','admin','manager']))) with check ((select public.has_org_role(organization_id, array['owner','admin','manager'])));

insert into public.cash_registers (organization_id, establishment_id, name, sort_order)
select e.organization_id, e.id, 'Réception', 0 from public.establishments e
where not exists (select 1 from public.cash_registers r where r.establishment_id = e.id);

alter table public.cash_sessions add column if not exists register_id uuid references public.cash_registers(id);
create index if not exists cash_sessions_register_idx on public.cash_sessions (register_id);
-- Rattachement des sessions existantes (les déclencheurs sont suspendus le temps de cette seule mise à jour : les sessions clôturées sont protégées contre toute modification)
alter table public.cash_sessions disable trigger user;
update public.cash_sessions s set register_id = r.id from public.cash_registers r
 where s.register_id is null and r.establishment_id = s.establishment_id and r.name = 'Réception';
alter table public.cash_sessions enable trigger user;

alter table public.organization_members add column if not exists cash_register_id uuid references public.cash_registers(id) on delete set null;

drop index if exists public.cash_one_open_per_est;
create unique index if not exists cash_one_open_per_register on public.cash_sessions (register_id) where status = 'open';

alter table public.cash_movements drop constraint cash_movements_kind_check;
alter table public.cash_movements add constraint cash_movements_kind_check check (kind = any (array['payment','income','expense','refund','deposit','transfer_in','transfer_out']));

create or replace function public.prepare_cash_session()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_exp numeric;
begin
  select organization_id into new.organization_id from public.establishments where id = new.establishment_id;
  if tg_op = 'INSERT' then
    new.opened_by := auth.uid(); new.status := 'open'; new.closed_at := null;
    if new.register_id is null then
      select id into new.register_id from public.cash_registers where establishment_id = new.establishment_id and is_active order by sort_order, created_at limit 1;
    end if;
    perform 1 from public.cash_registers where id = new.register_id and establishment_id = new.establishment_id and is_active;
    if not found then raise exception 'Caisse introuvable pour cet établissement.'; end if;
    if exists (select 1 from public.cash_sessions where register_id = new.register_id and status = 'open') then
      raise exception 'Cette caisse est déjà ouverte.';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.status = 'closed' then raise exception 'Une caisse clôturée ne peut plus être modifiée.'; end if;
  if tg_op = 'UPDATE' and new.register_id is distinct from old.register_id then raise exception 'La caisse d''une session ne peut pas être changée.'; end if;
  if tg_op = 'UPDATE' and new.status = 'closed' and old.status = 'open' then
    new.closed_by := auth.uid(); new.closed_at := now();
    select new.opening_balance + coalesce(sum(case when kind in ('payment','income','transfer_in') then amount else -amount end), 0) into v_exp
      from public.cash_movements where session_id = new.id and method = 'cash';
    if coalesce(new.counted_balance, 0) <> v_exp and length(trim(coalesce(new.gap_reason, ''))) < 3 then
      raise exception 'Indiquez le motif de l''écart de caisse (% F).', coalesce(new.counted_balance, 0) - v_exp;
    end if;
  end if;
  return new;
end $$;

create or replace function public.prepare_cash_movement()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_org uuid; v_sess uuid; v_reg uuid; v_n int;
begin
  select organization_id into v_org from public.establishments where id = new.establishment_id;
  if v_org is null then raise exception 'Établissement introuvable.'; end if;
  new.organization_id := v_org;
  new.created_by := coalesce(new.created_by, auth.uid());
  if new.reservation_id is not null then
    perform 1 from public.reservations where id = new.reservation_id and establishment_id = new.establishment_id;
    if not found then raise exception 'Réservation introuvable pour cet établissement.'; end if;
  end if;
  if new.method = 'cash' then
    -- 1) session indiquée par l'application, si elle est ouverte dans cet établissement
    if new.session_id is not null then
      select id into v_sess from public.cash_sessions where id = new.session_id and establishment_id = new.establishment_id and status = 'open';
    end if;
    -- 2) caisse ouverte par la personne
    if v_sess is null then
      select id into v_sess from public.cash_sessions where establishment_id = new.establishment_id and status = 'open' and opened_by = new.created_by order by opened_at desc limit 1;
    end if;
    -- 3) caisse attribuée à la personne
    if v_sess is null then
      select m.cash_register_id into v_reg from public.organization_members m where m.user_id = new.created_by and m.organization_id = v_org and m.is_active limit 1;
      if v_reg is not null then select id into v_sess from public.cash_sessions where register_id = v_reg and status = 'open'; end if;
    end if;
    -- 4) une seule caisse ouverte dans l'établissement
    if v_sess is null then
      select count(*), min(id::text)::uuid into v_n, v_sess from public.cash_sessions where establishment_id = new.establishment_id and status = 'open';
      if v_n > 1 then raise exception 'Plusieurs caisses sont ouvertes : choisissez votre caisse avant d''encaisser en espèces.'; end if;
    end if;
    if v_sess is null then raise exception 'Aucune caisse ouverte : ouvrez la caisse avant un mouvement en espèces.'; end if;
    new.session_id := v_sess;
  elsif new.kind in ('transfer_in','transfer_out') then
    raise exception 'Un transfert entre caisses se fait en espèces.';
  end if;
  return new;
end $$;

create or replace function public.cash_transfer(p_from_session uuid, p_to_session uuid, p_amount numeric, p_note text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare a public.cash_sessions; b public.cash_sessions; g uuid := gen_random_uuid(); na text; nb text;
begin
  select * into a from public.cash_sessions where id = p_from_session and status = 'open';
  select * into b from public.cash_sessions where id = p_to_session and status = 'open';
  if a.id is null or b.id is null then raise exception 'Les deux caisses doivent être ouvertes.'; end if;
  if a.id = b.id then raise exception 'Choisissez deux caisses différentes.'; end if;
  if a.establishment_id <> b.establishment_id then raise exception 'Les deux caisses doivent appartenir au même établissement.'; end if;
  if not public.has_org_role(a.organization_id, array['owner','admin','manager','receptionist','accountant']) then raise exception 'Accès refusé.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Indiquez un montant.'; end if;
  select name into na from public.cash_registers where id = a.register_id;
  select name into nb from public.cash_registers where id = b.register_id;
  insert into public.cash_movements (establishment_id, session_id, kind, method, amount, label, category, payment_group)
  values (a.establishment_id, a.id, 'transfer_out', 'cash', p_amount, left('Transfert vers ' || nb || coalesce(' · ' || nullif(trim(p_note), ''), ''), 200), 'Transfert', g),
         (b.establishment_id, b.id, 'transfer_in', 'cash', p_amount, left('Transfert depuis ' || na || coalesce(' · ' || nullif(trim(p_note), ''), ''), 200), 'Transfert', g);
end $$;
revoke all on function public.cash_transfer(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.cash_transfer(uuid, uuid, numeric, text) to authenticated;
