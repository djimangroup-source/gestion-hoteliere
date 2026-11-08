-- 60 · Paiement en ligne par l'agrégateur Genius Pay (abonnements ; réservations dans une étape suivante)
-- Ajoute un moyen de paiement « geniuspay » et élargit les listes autorisées. Aucune donnée existante n'est modifiée.

-- Moyen de paiement « Genius Pay » (Wave, Orange Money, MTN, carte via la page de paiement de l'agrégateur)
alter table public.payments drop constraint if exists payments_payment_method_check;
alter table public.payments add constraint payments_payment_method_check
  check (payment_method = any (array['orange_money','mtn_money','moov_money','wave','card','bank_transfer','cash','geniuspay']));
alter table public.cash_movements drop constraint if exists cash_movements_method_check;
alter table public.cash_movements add constraint cash_movements_method_check
  check (method = any (array['cash','orange_money','mtn_money','moov_money','wave','card','bank_transfer','geniuspay']));

insert into public.payment_providers (code, name, kind, is_active, supports_subscription, public_config, sort_order)
values ('geniuspay', 'Paiement en ligne (Wave, Orange Money, MTN, carte)', 'aggregator', true, true, '{"environment":"sandbox"}'::jsonb, 0)
on conflict (code) do nothing;

-- Suivi côté serveur : référence Genius Pay et lien de paiement d'un paiement d'abonnement (lecture par l'organisation via les règles existantes)
create index if not exists payments_txref_idx on public.payments (transaction_reference) where transaction_reference is not null;
