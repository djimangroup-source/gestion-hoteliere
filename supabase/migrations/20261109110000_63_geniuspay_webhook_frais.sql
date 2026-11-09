-- 63 · Genius Pay : secret webhook rangé côté serveur, frais payés par le client et frais réels enregistrés
-- Ajoute une table protégée et des colonnes. Aucune donnée existante n'est modifiée ni supprimée.

-- Réglages Genius Pay lus uniquement par le serveur (aucune règle d'accès : invisible pour l'application et le site)
create table if not exists public.geniuspay_settings (
  key text primary key,
  webhook_id text,
  webhook_secret text,
  webhook_url text,
  environment text,
  created_at timestamptz not null default now()
);
alter table public.geniuspay_settings enable row level security;
revoke all on public.geniuspay_settings from public, anon, authenticated;
grant all on public.geniuspay_settings to service_role;

-- Paiements de réservation : frais à la charge du client, montant réellement demandé, frais réels de Genius Pay
alter table public.booking_payments add column if not exists client_fee integer not null default 0;
alter table public.booking_payments add column if not exists charged integer;
alter table public.booking_payments add column if not exists gp_fees numeric;
alter table public.booking_payments add column if not exists gp_net numeric;
