-- Horus Hotel — Migration 24 : reçu personnalisé par établissement (tickets restaurant/bar, reçus de caisse).
alter table public.establishments
  add column if not exists receipt_settings jsonb not null default '{}'::jsonb
  check (jsonb_typeof(receipt_settings) = 'object' and length(receipt_settings::text) <= 4000);
comment on column public.establishments.receipt_settings is
  'Personnalisation du reçu : show_logo, header, address, phone, tax_id, footer, show_server, show_qr, font (mono/sans).';
