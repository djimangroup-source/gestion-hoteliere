-- Horus Hotel — Migration 21 (validée le 19/10/2026) :
-- • formule « Découverte » gratuite à vie : 3 chambres, 1 utilisateur, sans factures ;
-- • fin d'essai (ou abonnement expiré) => passage automatique en Découverte, sans perte de données ;
-- • nouvelle répartition des fonctions : Essentiel < Pro < Business (contrôle propriétaire) < Premium.

alter table public.subscriptions drop constraint subscriptions_billing_cycle_check;
alter table public.subscriptions add constraint subscriptions_billing_cycle_check check (billing_cycle in ('trial','monthly','yearly','free'));

insert into public.plans (name, slug, description, monthly_price, yearly_price, currency, max_rooms, max_users, max_properties, features, is_trial, is_public, is_recommended, is_quote_based, sort_order, is_active)
values ('Découverte', 'decouverte', 'Gratuit à vie pour les petites structures : jusqu’à 3 chambres, 1 utilisateur.', 0, 0, 'XOF', 3, 1, 1,
  '["reception","reservations","clients","payments","cash","housekeeping","users","notifications"]'::jsonb, false, true, false, false, 5, true)
on conflict (slug) do nothing;

update public.plans set features = '["reception","reservations","clients","payments","cash","housekeeping","users","notifications","billing","basic_reports","pdf_export"]'::jsonb, updated_at = now() where slug = 'essentiel';
update public.plans set max_users = 5, max_properties = 1,
  features = '["reception","reservations","clients","payments","cash","housekeeping","users","notifications","billing","basic_reports","pdf_export","online_booking","expenses","financial_reports"]'::jsonb, updated_at = now() where slug = 'pro';
update public.plans set
  features = '["reception","reservations","clients","payments","cash","housekeeping","users","notifications","billing","basic_reports","pdf_export","online_booking","expenses","financial_reports","owner_control","excel_export","multi_property","daily_summary"]'::jsonb, updated_at = now() where slug = 'business';
update public.plans set
  features = '["reception","reservations","clients","payments","cash","housekeeping","users","notifications","billing","basic_reports","pdf_export","online_booking","expenses","financial_reports","owner_control","excel_export","multi_property","daily_summary","whatsapp_auto","seasonal_rates","extra_services","priority_support","training"]'::jsonb, updated_at = now() where slug in ('premium','enterprise');
update public.plans set
  features = '["reception","reservations","clients","payments","cash","housekeeping","users","notifications","billing","basic_reports","pdf_export","online_booking","expenses","financial_reports","owner_control","excel_export","multi_property","daily_summary"]'::jsonb, updated_at = now() where slug = 'essai';
-- anciennes formules non vendues (Standard) : garder tout
update public.plans set features = features || '["notifications","billing","owner_control","excel_export","multi_property","daily_summary"]'::jsonb where slug = 'standard';

-- Statut : la formule gratuite est toujours active
create or replace function public.effective_subscription_status(p_org uuid)
returns text language sql stable security definer set search_path = '' as $function$
  select case
    when s.id is null then 'expired'
    when s.status = 'suspended' then 'suspended'
    when s.billing_cycle = 'free' then 'active'
    when s.status = 'expired' then 'expired'
    when s.status = 'trial' then case when now() > s.trial_end_at then 'expired' else 'trial' end
    when s.status = 'cancelled' then case when s.current_period_end is not null and now() <= s.current_period_end then 'cancelled' else 'expired' end
    when s.status in ('active','past_due') then case
        when now() <= s.current_period_end then 'active'
        when now() <= s.current_period_end + interval '3 days' then 'past_due'
        else 'expired' end
    else s.status end
  from (select 1) d left join public.subscriptions s on s.organization_id = p_org;
$function$;

-- Passage automatique en Découverte à l'expiration (tâche planifiée existante)
create or replace function public.refresh_subscription_statuses()
returns integer language plpgsql security definer set search_path = '' as $function$
declare n int; v_free uuid;
begin
  select id into v_free from public.plans where slug = 'decouverte' and is_active;
  if v_free is not null then
    with dn as (
      update public.subscriptions s set plan_id = v_free, billing_cycle = 'free', status = 'active',
             current_period_start = now(), current_period_end = null, next_billing_at = null, updated_at = now()
       where s.billing_cycle <> 'free' and s.status <> 'suspended' and public.effective_subscription_status(s.organization_id) = 'expired'
       returning s.organization_id, s.id)
    insert into public.subscription_events (organization_id, subscription_id, event_type, details)
    select organization_id, id, 'downgraded_to_free', jsonb_build_object('plan', 'decouverte') from dn;
  end if;
  with upd as (
    update public.subscriptions s set status = e.st
      from (select id, public.effective_subscription_status(organization_id) st from public.subscriptions) e
     where e.id = s.id and s.status <> e.st and not (s.status = 'cancelled' and e.st = 'cancelled')
       and not (s.status in ('active','past_due') and e.st = 'active' and s.status = 'active')
     returning s.organization_id, s.id, e.st)
  insert into public.subscription_events (organization_id, subscription_id, event_type, details)
  select organization_id, id, 'status_changed', jsonb_build_object('status', st) from upd;
  get diagnostics n = row_count;
  return n;
end $function$;

-- Chambres au-delà de la limite (ex. 4e chambre en Découverte) : visibles mais non réservables
create or replace function public.enforce_room_quota_on_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_max int; v_rank int;
begin
  if public.is_service_context() then return new; end if;
  if tg_op = 'UPDATE' and new.room_id = old.room_id and new.check_in = old.check_in and new.check_out = old.check_out then return new; end if;
  select p.max_rooms into v_max from public.subscriptions s join public.plans p on p.id = s.plan_id where s.organization_id = new.organization_id;
  if v_max is null then return new; end if;
  select r.rk into v_rank from (select id, row_number() over (order by created_at, id) rk from public.rooms where organization_id = new.organization_id and is_active) r where r.id = new.room_id;
  if v_rank is null or v_rank > v_max then
    raise exception 'Votre formule permet de réserver % chambre(s). Passez à la formule Essentiel pour utiliser toutes vos chambres.', v_max using hint = 'PLAN_LIMIT_ROOMS';
  end if;
  return new;
end $$;
revoke execute on function public.enforce_room_quota_on_booking() from public, anon, authenticated;
create trigger trg_zz_room_quota before insert or update on public.reservations for each row execute function public.enforce_room_quota_on_booking();

-- Factures : formules Essentiel et plus
create or replace function public.require_feature()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_label text := coalesce(tg_argv[1], 'Cette fonction'); v_plan text := coalesce(tg_argv[2], 'Pro');
begin
  if public.is_service_context() then return coalesce(new, old); end if;
  select organization_id into v_org from public.establishments where id = coalesce(new.establishment_id, old.establishment_id);
  if not public.org_has_feature(v_org, tg_argv[0]) then
    raise exception '% n’est pas disponible dans votre formule. Passez à la formule % pour en profiter.', v_label, v_plan using errcode = 'P0001', hint = 'PLAN_FEATURE_' || upper(tg_argv[0]);
  end if;
  return coalesce(new, old);
end $$;
create trigger trg_000_invoice_feature before insert on public.guest_invoices for each row execute function public.require_feature('billing', 'La facturation', 'Essentiel');
