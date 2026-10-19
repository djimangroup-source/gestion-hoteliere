-- Horus Hotel — Migration 27 : acceptation des CGU / CGV / politique de confidentialité (preuve horodatée par utilisateur et par version).
create table if not exists public.legal_acceptances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  version text not null check (length(version) between 1 and 20),
  documents text[] not null default array['cgu','cgv','confidentialite'],
  user_agent text check (user_agent is null or length(user_agent) <= 300),
  accepted_at timestamptz not null default now(),
  unique (user_id, version)
);
alter table public.legal_acceptances enable row level security;
create policy legal_select_own on public.legal_acceptances for select using (user_id = auth.uid() or public.is_platform_admin());
create policy legal_insert_own on public.legal_acceptances for insert with check (user_id = auth.uid());
grant select, insert on public.legal_acceptances to authenticated;
