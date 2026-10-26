-- Horus Hotel — Migration 31 : sécurité de la connexion du personnel.
-- • clé secrète serveur (jamais exposée) utilisée pour dériver les mots de passe du personnel ;
-- • compteur d'échecs par compte et par adresse IP (verrouillage temporaire).
-- Tables accessibles uniquement par la fonction serveur (RLS activée, aucune politique).
create table if not exists public.server_secrets (name text primary key, value text not null, created_at timestamptz not null default now());
alter table public.server_secrets enable row level security;
revoke all on public.server_secrets from anon, authenticated;
insert into public.server_secrets (name, value) values ('staff_pepper', encode(extensions.gen_random_bytes(32), 'hex')) on conflict (name) do nothing;

create table if not exists public.staff_login_attempts (
  key text primary key,
  failures int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.staff_login_attempts enable row level security;
revoke all on public.staff_login_attempts from anon, authenticated;
