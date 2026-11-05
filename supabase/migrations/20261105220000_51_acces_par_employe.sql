-- 51 · Accès ajustables par employé + historique d'activité
-- Ajoute une colonne (aucune donnée modifiée). Par défaut, chacun garde exactement les droits de son poste.

alter table public.organization_members add column if not exists access_overrides jsonb not null default '{}'::jsonb;

-- Droit effectif d'un membre pour une action sensible ('discount' : accorder une remise, 'cancel_payment' : annuler un encaissement)
create or replace function public.member_can(p_org uuid, p_action text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select case
      when m.role in ('owner','admin') then true
      when (m.access_overrides -> 'actions') ? p_action then coalesce((m.access_overrides -> 'actions' ->> p_action)::boolean, false)
      when p_action = 'discount' then m.role in ('manager','receptionist')
      when p_action = 'cancel_payment' then m.role = 'manager'
      else false end
    from public.organization_members m
    where m.organization_id = p_org and m.user_id = auth.uid() and m.is_active
    limit 1), false);
$$;
revoke execute on function public.member_can(uuid, text) from public, anon;
grant execute on function public.member_can(uuid, text) to authenticated;

-- Remise : refusée si le membre n'a pas le droit (les réservations en ligne et les traitements serveur ne sont pas concernés)
create or replace function public.guard_discount()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or public.is_service_context() or coalesce(current_setting('horus.marketplace', true), '') = 'on' or public.is_platform_admin() then return new; end if;
  if coalesce(new.discount, 0) > 0 and (tg_op = 'INSERT' or new.discount is distinct from old.discount) then
    if not public.member_can(new.organization_id, 'discount') then
      raise exception 'Vous n''avez pas l''autorisation d''accorder une remise. Demandez au gérant.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_discount on public.reservations;
create trigger trg_guard_discount before insert or update of discount on public.reservations
  for each row execute function public.guard_discount();

-- Annulation d'un encaissement (écriture de contrepassation « ANN: ») : réservée aux membres autorisés
create or replace function public.guard_cash_cancel()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or public.is_service_context() then return new; end if;
  if coalesce(new.reference, '') like 'ANN:%' and not public.member_can(new.organization_id, 'cancel_payment') then
    raise exception 'Vous n''avez pas l''autorisation d''annuler un encaissement. Demandez au gérant.';
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_cash_cancel on public.cash_movements;
create trigger trg_guard_cash_cancel before insert on public.cash_movements
  for each row execute function public.guard_cash_cancel();

-- Réglage des accès d'un employé (propriétaire ou administrateur ; jamais sur un propriétaire)
create or replace function public.set_member_access(p_member uuid, p_overrides jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare m public.organization_members; v_pages jsonb; v_actions jsonb; k text;
  allowed_pages text[] := array['dashboard','reservations','planning','naya','passes','clients','chambres','inventaire','pointage','caisse','depenses','factures','rapports','controle','mapage'];
begin
  select * into m from public.organization_members where id = p_member;
  if m.id is null or not public.has_org_role(m.organization_id, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  if m.role = 'owner' then raise exception 'Les accès du propriétaire ne se règlent pas.'; end if;
  if m.role = 'admin' and not public.has_org_role(m.organization_id, array['owner']) then raise exception 'Seul le propriétaire règle les accès d''un administrateur.'; end if;
  v_pages := coalesce(p_overrides -> 'pages', '{}'::jsonb);
  v_actions := coalesce(p_overrides -> 'actions', '{}'::jsonb);
  for k in select jsonb_array_elements_text(coalesce(v_pages -> 'add', '[]'::jsonb) || coalesce(v_pages -> 'remove', '[]'::jsonb)) loop
    if not (k = any(allowed_pages)) then raise exception 'Page inconnue : %', k; end if;
  end loop;
  for k in select jsonb_object_keys(v_actions) loop
    if k not in ('discount','cancel_payment') then raise exception 'Action inconnue : %', k; end if;
  end loop;
  update public.organization_members
     set access_overrides = jsonb_build_object('pages', jsonb_build_object('add', coalesce(v_pages -> 'add', '[]'::jsonb), 'remove', coalesce(v_pages -> 'remove', '[]'::jsonb)), 'actions', v_actions)
   where id = p_member;
  perform public.write_audit(m.organization_id, null, 'equipe', m.id, 'acces', 'Accès d''un employé modifiés', jsonb_build_object('acces', p_overrides));
end $$;
revoke execute on function public.set_member_access(uuid, jsonb) from public, anon;
grant execute on function public.set_member_access(uuid, jsonb) to authenticated;

-- Historique d'un employé (50 dernières actions) : propriétaire, administrateur, gérant
create or replace function public.member_activity(p_member uuid, p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare m public.organization_members;
begin
  select * into m from public.organization_members where id = p_member;
  if m.id is null or not public.has_org_role(m.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'entity', a.entity, 'action', a.action, 'summary', a.summary) order by a.created_at desc)
    from (select * from public.audit_log a where a.organization_id = m.organization_id and a.actor_id = m.user_id order by a.created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) a), '[]'::jsonb);
end $$;
revoke execute on function public.member_activity(uuid, int) from public, anon;
grant execute on function public.member_activity(uuid, int) to authenticated;
