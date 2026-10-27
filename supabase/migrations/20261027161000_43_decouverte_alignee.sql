-- 43 · Découverte (gratuite) alignée sur Veille : mêmes fonctions de base (ménage réservé aux formules Nuit et plus), visibilité Nuittea.com incluse.
update public.plans set features = '["reception","reservations","clients","payments","cash","users","notifications","online_booking"]'::jsonb,
  description = 'Gratuit pour les très petites structures : jusqu’à 3 chambres, 1 utilisateur.'
 where slug = 'decouverte';
