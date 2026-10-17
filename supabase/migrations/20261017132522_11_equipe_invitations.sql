-- Horus Hotel — Migration 11 : invitations du personnel et protection des rôles
-- Appliquée le 17/10/2026 (version 20261017132522). Migration additive.
-- Tests : 10/10 réussis (invitation, mauvais compte refusé, invisibilité pour les tiers, acceptation,
-- non-réutilisation, réceptionniste sans droit d'inviter ni de se promouvoir, dernier propriétaire protégé, liste équipe).

-- ===== Invitations du personnel =====
create table public.organization_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role text not null check (role in ('admin','manager','receptionist','housekeeping','accountant')),
  establishment_id uuid references public.establishments(id) on delete set null,
  invited_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','accepted','revoked')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);
create unique index org_invitations_one_pending on public.organization_invitations (organization_id, email) where status = 'pending';
create index on public.organization_invitations (email) where status = 'pending';
alter table public.organization_invitations enable row level security;

create policy inv_org_select on public.organization_invitations for select to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin'])));
create policy inv_org_insert on public.organization_invitations for insert to authenticated
  with check ((select public.has_org_role(organization_id, array['owner','admin'])) and status = 'pending' and invited_by = (select auth.uid())
              and (role <> 'admin' or (select public.has_org_role(organization_id, array['owner']))));
create policy inv_org_update on public.organization_invitations for update to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin'])))
  with check ((select public.has_org_role(organization_id, array['owner','admin'])) and status in ('pending','revoked'));

-- Écritures bloquées si l'abonnement est inactif (même règle que le reste)
create trigger trg_inv_guard before insert or update on public.organization_invitations
  for each row execute function public.guard_org_writable();

-- E-mail du compte connecté (lu côté serveur, jamais fourni par le navigateur)
create or replace function public.current_user_email()
returns text language sql stable security definer set search_path = '' as $$
  select lower(email) from auth.users where id = auth.uid();
$$;
revoke execute on function public.current_user_email() from public, anon, authenticated;

-- Invitations reçues par l'utilisateur connecté
create or replace function public.my_invitations()
returns table (id uuid, organization_name text, role text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, o.name, i.role, i.created_at
  from public.organization_invitations i join public.organizations o on o.id = i.organization_id
  where i.status = 'pending' and i.email = public.current_user_email()
  order by i.created_at desc;
$$;

-- Acceptation : l'e-mail doit correspondre au compte ; la limite d'utilisateurs de la formule s'applique
create or replace function public.accept_invitation(p_invitation uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.organization_invitations; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Authentification requise.'; end if;
  select * into i from public.organization_invitations where id = p_invitation and status = 'pending' for update;
  if not found or i.email <> public.current_user_email() then raise exception 'Invitation introuvable ou déjà utilisée.'; end if;
  if exists (select 1 from public.organization_members where user_id = v_uid and organization_id <> i.organization_id and is_active) then
    raise exception 'Ce compte appartient déjà à un autre établissement. Utilisez une autre adresse e-mail.';
  end if;
  insert into public.organization_members (organization_id, user_id, establishment_id, role, is_active)
  values (i.organization_id, v_uid, i.establishment_id, i.role, true)
  on conflict (organization_id, user_id) do update set role = excluded.role, establishment_id = excluded.establishment_id, is_active = true;
  update public.organization_invitations set status = 'accepted', accepted_at = now() where id = i.id;
  return i.organization_id;
end $$;

-- Liste de l'équipe avec les e-mails (propriétaire / administrateur uniquement)
create or replace function public.org_team(p_org uuid)
returns table (member_id uuid, user_id uuid, email text, role text, is_active boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_org_role(p_org, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  return query select m.id, m.user_id, lower(u.email)::text, m.role, m.is_active, m.created_at
    from public.organization_members m join auth.users u on u.id = m.user_id
    where m.organization_id = p_org order by (m.role = 'owner') desc, m.created_at;
end $$;

-- Protection du propriétaire : seul le propriétaire modifie un compte propriétaire ou administrateur,
-- personne ne retire le dernier propriétaire actif, personne ne s'attribue le rôle propriétaire.
create or replace function public.protect_owner_membership()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_owners int;
begin
  if public.is_service_context() then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' then
    if (old.role in ('owner','admin') or new.role in ('owner','admin')) and not public.has_org_role(old.organization_id, array['owner']) then
      raise exception 'Seul le propriétaire peut modifier un compte propriétaire ou administrateur.';
    end if;
    if new.role = 'owner' and old.role <> 'owner' then raise exception 'Le rôle propriétaire ne peut pas être attribué ici.'; end if;
    if old.role = 'owner' and (new.role <> 'owner' or not new.is_active) then
      select count(*) into v_owners from public.organization_members where organization_id = old.organization_id and role = 'owner' and is_active and id <> old.id;
      if v_owners = 0 then raise exception 'L''établissement doit garder au moins un propriétaire actif.'; end if;
    end if;
    if new.user_id <> old.user_id or new.organization_id <> old.organization_id then raise exception 'Modification interdite.'; end if;
  elsif tg_op = 'DELETE' then
    if old.role = 'owner' then raise exception 'Un propriétaire ne peut pas être supprimé ; désactivez plutôt les autres comptes.'; end if;
    if old.role = 'admin' and not public.has_org_role(old.organization_id, array['owner']) then raise exception 'Seul le propriétaire peut retirer un administrateur.'; end if;
  end if;
  return coalesce(new, old);
end $$;
revoke execute on function public.protect_owner_membership() from public, anon, authenticated;
create trigger trg_members_protect before update or delete on public.organization_members
  for each row execute function public.protect_owner_membership();

revoke execute on function public.my_invitations(), public.accept_invitation(uuid), public.org_team(uuid) from public, anon;
grant execute on function public.my_invitations(), public.accept_invitation(uuid), public.org_team(uuid) to authenticated;

/* ROLLBACK :
drop trigger if exists trg_members_protect on public.organization_members;
drop function if exists public.protect_owner_membership();
drop function if exists public.org_team(uuid);
drop function if exists public.accept_invitation(uuid);
drop function if exists public.my_invitations();
drop function if exists public.current_user_email();
drop table if exists public.organization_invitations;
*/
