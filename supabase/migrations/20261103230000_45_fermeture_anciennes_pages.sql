-- 45 · Fermeture des anciennes fonctions des pages publiques d'hôtel (pages retirées : ?h= et ?annuaire redirigent vers Nuittea.com).
-- Réversible : les fonctions ne sont pas supprimées, seul le droit d'exécution est retiré aux visiteurs et aux comptes.
-- Les réservations passent désormais uniquement par Nuittea.com (market_book), qui applique la commission.
-- Les fonctions d'avis par lien (public_review_get / public_review_submit) restent ouvertes.
revoke execute on function public.public_create_booking(text, text, date, date, int, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.public_get_establishment(text) from public, anon, authenticated;
revoke execute on function public.public_directory(text, text, numeric) from public, anon, authenticated;
revoke execute on function public.public_quote(text, text, date, date, int) from public, anon, authenticated;
revoke execute on function public.public_reviews(text) from public, anon, authenticated;
-- Statut d'abonnement d'une autre organisation : plus consultable directement (utilisé seulement à l'intérieur d'autres fonctions)
revoke execute on function public.effective_subscription_status(uuid) from public, anon, authenticated;
-- Fonctions de déclencheur : jamais appelées directement
revoke execute on function public.guard_room_pass() from public, anon, authenticated;
revoke execute on function public.sync_pass_formula_org() from public, anon, authenticated;
