-- Horus Hotel — Migration 22 : comptes du personnel avec code hôtel + identifiant + code à 4 chiffres.
-- Les comptes sont créés uniquement par la fonction serveur « staff-admin » (clé d'administration côté serveur).

alter table public.organizations add column if not exists staff_code text unique check (staff_code is null or staff_code ~ '^[a-z0-9]{3,20}$');
alter table public.organization_members
  add column if not exists username text check (username is null or username ~ '^[a-z0-9]{2,20}$'),
  add column if not exists display_name text check (display_name is null or length(display_name) <= 80),
  add column if not exists must_change_password boolean not null default false;
create unique index if not exists org_members_username on public.organization_members (organization_id, username) where username is not null;

-- Code hôtel par défaut pour les organisations existantes (lettres et chiffres du nom, rendu unique)
do $$ declare r record; base text; c text; i int;
begin
  for r in select id, name from public.organizations where staff_code is null loop
    base := left(regexp_replace(lower(translate(r.name, 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', 'aaaeeeeiioouuucaaaeeeeiioouuuc')), '[^a-z0-9]', '', 'g'), 16);
    if length(base) < 3 then base := 'hotel'; end if;
    c := base; i := 1;
    while exists (select 1 from public.organizations where staff_code = c) loop i := i + 1; c := left(base, 16) || i; end loop;
    update public.organizations set staff_code = c where id = r.id;
  end loop;
end $$;

-- Changer le code hôtel (propriétaire / administrateur), impossible une fois des comptes personnel créés
create or replace function public.set_staff_code(p_org uuid, p_code text)
returns text language plpgsql security definer set search_path = '' as $$
declare v text := lower(trim(coalesce(p_code, '')));
begin
  if not public.has_org_role(p_org, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  if v !~ '^[a-z0-9]{3,20}$' then raise exception 'Le code doit contenir 3 à 20 lettres minuscules ou chiffres, sans espace.'; end if;
  if exists (select 1 from public.organization_members where organization_id = p_org and username is not null)
     and v <> (select staff_code from public.organizations where id = p_org) then
    raise exception 'Le code ne peut plus être modifié : des comptes personnel l’utilisent déjà.';
  end if;
  if exists (select 1 from public.organizations where staff_code = v and id <> p_org) then raise exception 'Ce code est déjà pris par un autre établissement.'; end if;
  update public.organizations set staff_code = v where id = p_org;
  return v;
end $$;

-- L'employé a remplacé son code provisoire
create or replace function public.staff_password_changed()
returns void language sql security definer set search_path = '' as $$
  update public.organization_members set must_change_password = false where user_id = auth.uid();
$$;

-- Équipe : ajoute identifiant, nom affiché et état du code provisoire
create or replace function public.org_team_v2(p_org uuid)
returns table (member_id uuid, user_id uuid, email text, role text, is_active boolean, created_at timestamptz, username text, display_name text, must_change_password boolean, last_sign_in_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_org_role(p_org, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  return query select m.id, m.user_id, case when m.username is null then lower(u.email)::text else null end, m.role, m.is_active, m.created_at,
                      m.username, m.display_name, m.must_change_password, u.last_sign_in_at
    from public.organization_members m join auth.users u on u.id = m.user_id
    where m.organization_id = p_org order by (m.role = 'owner') desc, m.created_at;
end $$;

revoke execute on function public.set_staff_code(uuid, text), public.staff_password_changed(), public.org_team_v2(uuid) from public, anon;
grant execute on function public.set_staff_code(uuid, text), public.staff_password_changed(), public.org_team_v2(uuid) to authenticated;
