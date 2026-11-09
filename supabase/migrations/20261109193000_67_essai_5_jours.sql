-- 67 · Essai gratuit ramené à 5 jours (décision du 09/11/2026).
-- Le compte encore en formule Découverte (gratuite, retirée) a été passé en essai de 5 jours le 09/11/2026 (opération tracée dans le journal).
update public.plans set trial_days = 5, updated_at = now() where slug = 'essai';
