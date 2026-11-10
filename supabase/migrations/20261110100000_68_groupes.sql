-- 68 · Groupes : plusieurs chambres réunies dans un même dossier (séminaire, mariage, famille).
-- Ajout uniquement : une nouvelle table et une colonne facultative. Aucune donnée existante modifiée ni supprimée.
create table if not exists public.reservation_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null check (length(name) between 2 and 80),
  contact_name text check (contact_name is null or length(contact_name) <= 80),
  contact_phone text check (contact_phone is null or length(contact_phone) <= 30),
  billing text not null default 'shared' check (billing in ('shared','separate')),
  notes text check (notes is null or length(notes) <= 500),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists reservation_groups_org_idx on public.reservation_groups (organization_id);
create index if not exists reservation_groups_est_idx on public.reservation_groups (establishment_id);

alter table public.reservations add column if not exists group_id uuid references public.reservation_groups(id) on delete set null;
create index if not exists reservations_group_id_idx on public.reservations (group_id);

alter table public.reservation_groups enable row level security;
create policy grp_select on public.reservation_groups for select using ((select public.is_org_member(organization_id)) or (select public.is_platform_admin()));
create policy grp_insert on public.reservation_groups for insert with check ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist'])));
create policy grp_update on public.reservation_groups for update using ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist']))) with check ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist'])));
create policy grp_delete on public.reservation_groups for delete using ((select public.has_org_role(organization_id, array['owner','admin'])));
