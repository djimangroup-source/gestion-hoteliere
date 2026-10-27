-- 41 · Commission Nuittea ramenée à 8 % par défaut (réglable par hôtel dans Administration).
-- Les réservations déjà enregistrées gardent leur taux : seul le taux des fiches change.
alter table public.marketplace_listings alter column commission_pct set default 8;
update public.marketplace_listings set commission_pct = 8, updated_at = now() where commission_pct = 10;
