-- 71 · Formules : on ne garde que Essai gratuit, Essentiel, Confort, Pro, Premium (premium-plus) et Groupe.
-- 0) Un paiement peut ne plus être rattaché à une formule (formule supprimée) : son nom reste noté dans metadata
alter table public.payments alter column plan_id drop not null;
-- 1) Bascule des abonnés des anciennes formules (dates de fin inchangées)
update public.subscriptions s set plan_id = (select id from public.plans where slug = 'pro')
  where plan_id in (select id from public.plans where slug in ('business','standard'));
update public.subscriptions s set plan_id = (select id from public.plans where slug = 'premium-plus')
  where plan_id in (select id from public.plans where slug in ('premium','constellation'));
update public.subscriptions s set plan_id = (select id from public.plans where slug = 'groupe')
  where plan_id in (select id from public.plans where slug = 'enterprise');
-- 2) Historique des paiements conservé : le nom de l'ancienne formule est noté dans le paiement
update public.payments x set metadata = coalesce(x.metadata, '{}'::jsonb) || jsonb_build_object('ancienne_formule', p.name, 'ancienne_formule_slug', p.slug), plan_id = null
  from public.plans p where p.id = x.plan_id and p.slug not in ('essai','essentiel','confort','pro','premium-plus','groupe');
-- 3) Suppression des anciennes formules
delete from public.plans where slug not in ('essai','essentiel','confort','pro','premium-plus','groupe');
