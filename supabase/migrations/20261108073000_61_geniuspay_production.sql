-- 61 · Genius Pay en production : le paiement en ligne est proposé à tous les hôtels.
-- Garde-fou côté serveur conservé : si les clés installées sont des clés de test (sandbox), seuls les administrateurs de la plateforme peuvent payer.
update public.payment_providers set public_config = coalesce(public_config, '{}'::jsonb) || '{"environment":"live"}'::jsonb where code = 'geniuspay';
