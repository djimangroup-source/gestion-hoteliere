-- 46 · Photo de la pièce d'identité du client (recto / verso) — ajout uniquement, rien d'existant n'est modifié.
-- • Espace de stockage privé « id-docs » (jamais public). Chemin : <organisation>/<client>/<recto|verso>-<horodatage>.jpg
-- • Lecture : propriétaire, administrateur, gérant, réception et comptable de l'hôtel concerné, et seulement pendant 3 mois.
-- • Ajout / suppression : propriétaire, administrateur, gérant et réception.
-- • Au-delà de 3 mois, la photo devient illisible immédiatement ; l'application supprime ensuite le fichier.
-- • Chaque prise, consultation ou suppression est tracée (id_doc_events).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('id-docs', 'id-docs', false, 2097152, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do nothing;

alter table public.guests
  add column if not exists id_front_path text,
  add column if not exists id_back_path text,
  add column if not exists id_photo_at timestamptz;

-- Organisation et client tirés du chemin du fichier (null si le chemin est mal formé)
create or replace function public._iddoc_part(p_name text, p_i int) returns uuid
language plpgsql immutable set search_path = '' as $$
begin return ((storage.foldername(p_name))[p_i])::uuid; exception when others then return null; end $$;

create policy iddocs_read on storage.objects for select to authenticated
  using (bucket_id = 'id-docs' and created_at > now() - interval '3 months'
         and public.has_org_role(public._iddoc_part(name, 1), array['owner', 'admin', 'manager', 'receptionist', 'accountant']));
create policy iddocs_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'id-docs'
         and public.has_org_role(public._iddoc_part(name, 1), array['owner', 'admin', 'manager', 'receptionist'])
         and exists (select 1 from public.guests g where g.id = public._iddoc_part(name, 2) and g.organization_id = public._iddoc_part(name, 1)));
create policy iddocs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'id-docs' and public.has_org_role(public._iddoc_part(name, 1), array['owner', 'admin', 'manager', 'receptionist']));

-- Journal des accès
create table if not exists public.id_doc_events (
  id bigserial primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  guest_id uuid references public.guests(id) on delete set null,
  user_id uuid default auth.uid(),
  action text not null check (action in ('capture', 'view', 'delete', 'purge')),
  created_at timestamptz not null default now()
);
create index if not exists id_doc_events_org on public.id_doc_events (organization_id, created_at desc);
alter table public.id_doc_events enable row level security;
create policy id_doc_events_read on public.id_doc_events for select to authenticated
  using (public.has_org_role(organization_id, array['owner', 'admin']));

create or replace function public.id_doc_log(p_guest uuid, p_action text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.guests where id = p_guest;
  if v_org is null or not public.has_org_role(v_org, array['owner', 'admin', 'manager', 'receptionist', 'accountant']) then raise exception 'Accès refusé.'; end if;
  if p_action not in ('capture', 'view', 'delete', 'purge') then raise exception 'Action inconnue.'; end if;
  insert into public.id_doc_events (organization_id, guest_id, action) values (v_org, p_guest, p_action);
end $$;
revoke execute on function public.id_doc_log(uuid, text) from public, anon;
grant execute on function public.id_doc_log(uuid, text) to authenticated;

-- Photos arrivées à expiration (3 mois) pour l'organisation : l'application supprime les fichiers puis appelle id_docs_clear
create or replace function public.id_docs_expired(p_org uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when public.has_org_role(p_org, array['owner', 'admin', 'manager', 'receptionist']) then
    coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'paths', array_remove(array[g.id_front_path, g.id_back_path], null)))
      from public.guests g where g.organization_id = p_org and g.id_photo_at < now() - interval '3 months'
       and (g.id_front_path is not null or g.id_back_path is not null)), '[]'::jsonb) else '[]'::jsonb end;
$$;
create or replace function public.id_docs_clear(p_guest uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.guests where id = p_guest;
  if v_org is null or not public.has_org_role(v_org, array['owner', 'admin', 'manager', 'receptionist']) then raise exception 'Accès refusé.'; end if;
  update public.guests set id_front_path = null, id_back_path = null, id_photo_at = null where id = p_guest and id_photo_at < now() - interval '3 months';
  insert into public.id_doc_events (organization_id, guest_id, user_id, action) values (v_org, p_guest, auth.uid(), 'purge');
end $$;
revoke execute on function public.id_docs_expired(uuid), public.id_docs_clear(uuid), public._iddoc_part(text, int) from public, anon;
grant execute on function public.id_docs_expired(uuid), public.id_docs_clear(uuid), public._iddoc_part(text, int) to authenticated;
