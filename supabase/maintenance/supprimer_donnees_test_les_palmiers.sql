-- Supprime les données de test ajoutées le 18/10/2026 dans « les palmiers » (préfixe [TEST], chambres T101–T202).
-- À exécuter dans Supabase > SQL Editor. Vos chambres 1 et 2 et votre réservation réelle ne sont pas touchées.
begin;
delete from public.cash_movements where organization_id = 'c1b4a6e4-bb9a-4139-9375-9f0bdcb80efe' and label like '[TEST]%';
delete from public.reservations  where organization_id = 'c1b4a6e4-bb9a-4139-9375-9f0bdcb80efe' and guest_name like '[TEST]%';
delete from public.guests        where organization_id = 'c1b4a6e4-bb9a-4139-9375-9f0bdcb80efe' and full_name like '[TEST]%';
delete from public.rooms         where organization_id = 'c1b4a6e4-bb9a-4139-9375-9f0bdcb80efe' and number in ('T101','T102','T103','T104','T201','T202');
commit;
