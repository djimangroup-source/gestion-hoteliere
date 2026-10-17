-- Horus Hotel — suppression des organisations de test créées pendant le développement.
-- À exécuter UNE FOIS dans le SQL Editor Supabase (projet gestion-hoteliere), après relecture.
-- Ne touche qu'aux organisations nommées ci-dessous et aux comptes e-mail de test (@exemple.ci).
begin;
select set_config('app.bypass_subscription', 'on', true);
create temp table t_o on commit drop as
  select id from public.organizations where name in ('Hôtel Test A','Résidence Test B','Org Pub 1','Org Pub 2','Org Tmp');
create temp table t_e on commit drop as select id from public.establishments where organization_id in (select id from t_o);
alter table public.cash_movements disable trigger trg_cash_immutable;
alter table public.guest_invoices disable trigger trg_inv_immutable;
delete from public.public_booking_attempts where establishment_id in (select id from t_e);
delete from public.establishment_slug_history where establishment_id in (select id from t_e);
delete from public.guest_invoices where organization_id in (select id from t_o);
delete from public.cash_movements where organization_id in (select id from t_o);
delete from public.cash_sessions where organization_id in (select id from t_o);
delete from public.org_counters where organization_id in (select id from t_o);
delete from public.subscription_events where organization_id in (select id from t_o);
delete from public.subscription_invoices where organization_id in (select id from t_o);
delete from public.payments where organization_id in (select id from t_o);
delete from public.reservations where organization_id in (select id from t_o);
delete from public.guests where organization_id in (select id from t_o);
delete from public.rooms where organization_id in (select id from t_o);
delete from public.organization_members where organization_id in (select id from t_o);
delete from public.establishments where id in (select id from t_e);
delete from public.subscriptions where organization_id in (select id from t_o);
delete from public.organizations where id in (select id from t_o);
alter table public.cash_movements enable trigger trg_cash_immutable;
alter table public.guest_invoices enable trigger trg_inv_immutable;
delete from auth.users where email like 'test\_%@exemple.ci' or email like 'tmp\_%@exemple.ci';
commit;
select name from public.organizations order by created_at;
