-- 59 · Page Sécurité du propriétaire : connexions, comptes bloqués, déblocage, déconnexion de tous les appareils
-- Fonctions de lecture et d'action ciblées. Aucune table ni donnée existante modifiée.

create or replace function public.security_overview(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare v_code text;
begin
  if not public.has_org_role(p_org, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  select staff_code into v_code from public.organizations where id = p_org;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'member_id', m.id, 'name', coalesce(m.display_name, m.username, lower(u.email)), 'username', m.username, 'role', m.role, 'is_active', m.is_active,
      'must_change', m.must_change_password, 'last_sign_in', u.last_sign_in_at, 'created_at', m.created_at,
      'sessions', (select count(*) from auth.sessions s where s.user_id = m.user_id and (s.not_after is null or s.not_after > now())),
      'last_seen', (select max(coalesce(s.refreshed_at, s.updated_at, s.created_at)) from auth.sessions s where s.user_id = m.user_id),
      'user_agent', (select s.user_agent from auth.sessions s where s.user_id = m.user_id order by coalesce(s.refreshed_at, s.updated_at, s.created_at) desc nulls last limit 1),
      'failures', a.failures, 'locked_until', case when a.locked_until > now() then a.locked_until end)
      order by (m.role = 'owner') desc, m.created_at)
    from public.organization_members m join auth.users u on u.id = m.user_id
    left join public.staff_login_attempts a on m.username is not null and a.key = 'acc:' || lower(coalesce(v_code, '')) || ':' || lower(m.username)
    where m.organization_id = p_org), '[]'::jsonb);
end $$;

create or replace function public.security_unlock(p_member uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare m public.organization_members; v_code text;
begin
  select * into m from public.organization_members where id = p_member;
  if m.id is null or not public.has_org_role(m.organization_id, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  if m.username is null then raise exception 'Ce compte se connecte par e-mail : il n''a pas de blocage à lever ici.'; end if;
  select staff_code into v_code from public.organizations where id = m.organization_id;
  delete from public.staff_login_attempts where key = 'acc:' || lower(v_code) || ':' || lower(m.username);
  perform public.write_audit(m.organization_id, null, 'equipe', m.id, 'deblocage', 'Compte de ' || coalesce(m.display_name, m.username) || ' débloqué', '{}'::jsonb);
end $$;

-- Déconnexion de tous les appareils : les sessions sont supprimées (l'accès en cours expire au plus tard dans l'heure)
create or replace function public.security_signout_all(p_member uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare m public.organization_members; v_n int;
begin
  select * into m from public.organization_members where id = p_member;
  if m.id is null or not public.has_org_role(m.organization_id, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  if m.role = 'owner' and m.user_id <> auth.uid() then raise exception 'Seul le propriétaire peut déconnecter ses propres appareils.'; end if;
  delete from auth.sessions where user_id = m.user_id;
  get diagnostics v_n = row_count;
  perform public.write_audit(m.organization_id, null, 'equipe', m.id, 'deconnexion', 'Tous les appareils de ' || coalesce(m.display_name, m.username, 'un membre') || ' déconnectés', jsonb_build_object('sessions', v_n));
  return v_n;
end $$;

revoke execute on function public.security_overview(uuid), public.security_unlock(uuid), public.security_signout_all(uuid) from public, anon;
grant execute on function public.security_overview(uuid), public.security_unlock(uuid), public.security_signout_all(uuid) to authenticated;
