-- 72 · Console d'administration Nuittea : équipe interne, rôles, accès par personne, journal, modération.
-- Uniquement des ajouts. Aucune donnée supprimée. Les fonctions publiques sont modifiées pour exclure
-- les chambres masquées et les établissements suspendus (aucun n'est masqué ou suspendu à l'application).

create table if not exists public.platform_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text, display_name text,
  role text not null check (role in ('direction','commercial','support','finance','lecture')),
  is_active boolean not null default true,
  overrides jsonb not null default '{"add":[],"remove":[]}'::jsonb,
  invited_by uuid, created_at timestamptz not null default now(), last_seen_at timestamptz
);
alter table public.platform_staff enable row level security;

create table if not exists public.platform_audit (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(), actor uuid default auth.uid(),
  action text not null, target_type text, target_id text, detail jsonb not null default '{}'::jsonb
);
create index if not exists platform_audit_at_idx on public.platform_audit (at desc);
alter table public.platform_audit enable row level security;

-- Les administrateurs existants deviennent « Direction »
insert into public.platform_staff (user_id, email, role)
select a.user_id, u.email, 'direction' from public.platform_admins a join auth.users u on u.id = a.user_id
on conflict (user_id) do nothing;

create or replace function public.platform_perms(p_uid uuid default auth.uid())
returns text[] language sql stable security definer set search_path to '' as $$
  with s as (select * from public.platform_staff where user_id = p_uid and is_active),
  base as (select case s.role
      when 'direction'  then array['dashboard','crm','clients','support','finance','moderation','moderation_delete','demo','impersonate','team','settings','journal']
      when 'commercial' then array['dashboard','crm','clients','demo']
      when 'support'    then array['dashboard','clients','support','moderation','demo']
      when 'finance'    then array['dashboard','clients','finance','journal']
      else array['dashboard','clients'] end p, s.overrides o from s)
  select coalesce((select array(select distinct x from (
      select unnest(p) x union select jsonb_array_elements_text(coalesce(o->'add','[]'))) z
      where x not in (select jsonb_array_elements_text(coalesce(o->'remove','[]'))) order by 1) from base), '{}');
$$;

create or replace function public.staff_can(p_perm text)
returns boolean language sql stable security definer set search_path to '' as $$
  select p_perm = any(public.platform_perms(auth.uid()));
$$;

create policy pstaff_select on public.platform_staff for select using ((select public.staff_can('dashboard')));
create policy paudit_select on public.platform_audit for select using ((select public.staff_can('journal')));

create or replace function public._staff_log(p_action text, p_type text, p_id text, p_detail jsonb default '{}')
returns void language sql security definer set search_path to '' as $$
  insert into public.platform_audit (action, target_type, target_id, detail) values (p_action, p_type, p_id, coalesce(p_detail, '{}'));
$$;
revoke all on function public._staff_log(text, text, text, jsonb) from public, anon, authenticated;

-- Équipe : ajouter / modifier une personne (Direction)
create or replace function public.admin_staff_upsert(p_email text, p_role text, p_add text[] default '{}', p_remove text[] default '{}', p_active boolean default true, p_name text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_uid uuid;
begin
  if not public.staff_can('team') then raise exception 'Accès refusé.'; end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then raise exception 'Aucun compte avec cette adresse : la personne doit d''abord créer son compte.'; end if;
  if v_uid = auth.uid() and (p_role <> 'direction' or not p_active) then raise exception 'Vous ne pouvez pas retirer votre propre accès Direction.'; end if;
  insert into public.platform_staff (user_id, email, display_name, role, is_active, overrides, invited_by)
  values (v_uid, lower(trim(p_email)), p_name, p_role, p_active, jsonb_build_object('add', to_jsonb(coalesce(p_add,'{}')), 'remove', to_jsonb(coalesce(p_remove,'{}'))), auth.uid())
  on conflict (user_id) do update set role = excluded.role, is_active = excluded.is_active, overrides = excluded.overrides,
    display_name = coalesce(excluded.display_name, public.platform_staff.display_name);
  perform public._staff_log('equipe_modifiee', 'staff', v_uid::text, jsonb_build_object('email', p_email, 'role', p_role, 'add', p_add, 'remove', p_remove, 'actif', p_active));
  return jsonb_build_object('ok', true, 'perms', public.platform_perms(v_uid));
end $$;

-- Modération
alter table public.rooms add column if not exists nuittea_hidden boolean not null default false;
alter table public.rooms add column if not exists nuittea_hidden_reason text;
alter table public.establishments add column if not exists nuittea_suspended_at timestamptz;
alter table public.establishments add column if not exists nuittea_suspended_reason text;
alter table public.establishments add column if not exists nuittea_suspended_by uuid;

create or replace function public.admin_room_hide(p_room uuid, p_hidden boolean, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('moderation') then raise exception 'Accès refusé.'; end if;
  if p_hidden and length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Indiquez un motif.'; end if;
  update public.rooms set nuittea_hidden = p_hidden, nuittea_hidden_reason = case when p_hidden then p_reason end where id = p_room;
  if not found then raise exception 'Chambre introuvable.'; end if;
  perform public._staff_log(case when p_hidden then 'chambre_masquee' else 'chambre_reaffichee' end, 'room', p_room::text, jsonb_build_object('motif', p_reason));
end $$;

create or replace function public.admin_est_suspend(p_est uuid, p_suspend boolean, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('moderation') then raise exception 'Accès refusé.'; end if;
  if p_suspend and length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Indiquez un motif.'; end if;
  update public.establishments set nuittea_suspended_at = case when p_suspend then now() end,
    nuittea_suspended_reason = case when p_suspend then p_reason end, nuittea_suspended_by = case when p_suspend then auth.uid() end where id = p_est;
  if not found then raise exception 'Établissement introuvable.'; end if;
  perform public._staff_log(case when p_suspend then 'etablissement_suspendu' else 'etablissement_retabli' end, 'establishment', p_est::text, jsonb_build_object('motif', p_reason));
end $$;

-- Retrait définitif de la fiche Nuittea (Direction) : dépublie, ne supprime aucune donnée de l'hôtel
create or replace function public.admin_listing_remove(p_est uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('moderation_delete') then raise exception 'Accès refusé.'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Indiquez un motif.'; end if;
  update public.marketplace_listings set listed = false, updated_at = now() where establishment_id = p_est;
  perform public._staff_log('publication_retiree', 'establishment', p_est::text, jsonb_build_object('motif', p_reason));
end $$;

revoke all on function public.admin_staff_upsert(text,text,text[],text[],boolean,text), public.admin_room_hide(uuid,boolean,text),
  public.admin_est_suspend(uuid,boolean,text), public.admin_listing_remove(uuid,text) from public, anon;
grant execute on function public.admin_staff_upsert(text,text,text[],text[],boolean,text), public.admin_room_hide(uuid,boolean,text),
  public.admin_est_suspend(uuid,boolean,text), public.admin_listing_remove(uuid,text), public.platform_perms(uuid), public.staff_can(text) to authenticated;

-- Filtres dans les fonctions publiques (réécriture ciblée des définitions existantes)
do $$
declare d text;
begin
  d := pg_get_functiondef('public._market_est'::regproc);
  execute replace(d, 'and x.is_active and', 'and x.is_active and x.nuittea_suspended_at is null and');
  d := pg_get_functiondef('public._market_room'::regproc);
  execute replace(d, 'r.establishment_id = e_id and r.is_active', 'r.establishment_id = e_id and r.is_active and not r.nuittea_hidden');
  d := pg_get_functiondef('public.market_search'::regproc);
  d := replace(d, 'where m.listed and e.is_active', 'where m.listed and e.is_active and e.nuittea_suspended_at is null');
  d := replace(d, 'r.establishment_id = e.id and r.is_active', 'r.establishment_id = e.id and r.is_active and not r.nuittea_hidden');
  execute d;
  d := pg_get_functiondef('public.market_establishment'::regproc);
  d := replace(d, 'r2.is_active', 'r2.is_active and not r2.nuittea_hidden');
  d := replace(d, 'r3.is_active', 'r3.is_active and not r3.nuittea_hidden');
  d := replace(d, 'where establishment_id = e.id and is_active and', 'where establishment_id = e.id and is_active and not nuittea_hidden and');
  execute d;
  d := pg_get_functiondef('public.market_location'::regproc);
  execute replace(d, 'm.listed and e.is_active', 'm.listed and e.is_active and e.nuittea_suspended_at is null');
  d := pg_get_functiondef('public.marketplace_set_listing'::regproc);
  execute replace(d, 'then raise exception ''Accès refusé.''; end if;',
    'then raise exception ''Accès refusé.''; end if;
  if p_listed and e.nuittea_suspended_at is not null then raise exception ''Établissement suspendu par Nuittea : contactez le support.''; end if;');
end $$;
