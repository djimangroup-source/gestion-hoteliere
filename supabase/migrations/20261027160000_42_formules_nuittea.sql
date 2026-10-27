-- 42 · Nouvelles formules Nuittea Manager (Veille, Nuit, Étoile, Constellation, Galaxie) + paiement sur plusieurs mois
-- • Migration additive : les anciennes formules (Essentiel, Pro, Business, Premium, Enterprise, Standard) ne sont pas
--   supprimées, elles sont seulement retirées de la vente (is_public = false). Les abonnés actuels les conservent.
-- • Découverte (gratuite) et l'essai de 7 jours sont conservés.
-- • start_subscription_checkout accepte un nombre de mois (1 à 11) en paiement mensuel ; confirm_subscription_payment
--   prolonge l'abonnement d'autant de mois (valeur lue dans payments.metadata->>'months').

update public.plans set is_public = false, is_recommended = false
 where slug in ('essentiel','pro','business','premium','enterprise','standard');

update public.plans set description = '7 jours pour découvrir l’application, sans engagement.' where is_trial;

insert into public.plans (name, slug, description, monthly_price, yearly_price, currency, max_rooms, max_users, max_properties,
                          features, is_trial, is_public, is_recommended, is_quote_based, sort_order, is_active)
values
 ('Veille', 'veille', 'Pour les petites résidences et maisons d’hôtes : réservations, planning et caisse.',
  5000, 55000, 'XOF', 8, 2, 1,
  '["reception","reservations","clients","payments","cash","users","notifications","online_booking"]'::jsonb,
  false, true, false, false, 10, true),
 ('Nuit', 'nuit', 'Pour la plupart des hôtels et résidences : ménage, factures, dépenses et contrôle de la caisse.',
  10000, 110000, 'XOF', 20, 6, 1,
  '["reception","reservations","clients","payments","cash","users","notifications","online_booking","housekeeping","billing","pdf_export","expenses","basic_reports"]'::jsonb,
  false, true, true, false, 20, true),
 ('Étoile', 'etoile', 'Pour les hôtels structurés : rapports financiers, contrôle propriétaire, tarifs automatiques, jusqu’à 3 établissements.',
  20000, 220000, 'XOF', 40, 15, 3,
  '["reception","reservations","clients","payments","cash","users","notifications","online_booking","housekeeping","billing","pdf_export","expenses","basic_reports","financial_reports","excel_export","owner_control","seasonal_rates","multi_property","priority_support"]'::jsonb,
  false, true, false, false, 30, true),
 ('Constellation', 'constellation', 'Pour les groupes : chambres et utilisateurs illimités, jusqu’à 10 établissements, installation et formation.',
  40000, 395000, 'XOF', null, null, 10,
  '["reception","reservations","clients","payments","cash","users","notifications","online_booking","housekeeping","billing","pdf_export","expenses","basic_reports","financial_reports","excel_export","owner_control","seasonal_rates","multi_property","priority_support","training"]'::jsonb,
  false, true, false, false, 40, true),
 ('Galaxie', 'galaxie', 'Chaînes et besoins sur mesure : établissements illimités, accompagnement dédié. Prix sur devis.',
  0, null, 'XOF', null, null, null,
  '["reception","reservations","clients","payments","cash","users","notifications","online_booking","housekeeping","billing","pdf_export","expenses","basic_reports","financial_reports","excel_export","owner_control","seasonal_rates","multi_property","priority_support","training","daily_summary","whatsapp_auto","extra_services"]'::jsonb,
  false, true, false, true, 50, true)
on conflict (slug) do nothing;

-- Paiement de plusieurs mois d'avance
create or replace function public.start_subscription_checkout(p_org uuid, p_plan_slug text, p_cycle text, p_method text, p_months int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_pay uuid; v_m int := coalesce(p_months, 1); v_price int;
begin
  if p_cycle = 'monthly' and (v_m < 1 or v_m > 11) then raise exception 'Durée invalide : de 1 à 11 mois, ou formule annuelle.'; end if;
  v_pay := public.start_subscription_checkout(p_org, p_plan_slug, p_cycle, p_method);
  if p_cycle = 'monthly' and v_m > 1 then
    select monthly_price into v_price from public.plans where slug = p_plan_slug;
    update public.payments set amount = v_price * v_m, metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('months', v_m)
     where id = v_pay;
  end if;
  return v_pay;
end $$;
revoke execute on function public.start_subscription_checkout(uuid, text, text, text, int) from public, anon;
grant execute on function public.start_subscription_checkout(uuid, text, text, text, int) to authenticated;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.confirm_subscription_payment(uuid, text, jsonb)'::regprocedure);
  if position('''months''' in d) = 0 then
    d := replace(d, $r$v_end := v_start + case pay.billing_cycle when 'monthly' then interval '1 month' else interval '1 year' end;$r$,
                    $r$v_end := v_start + case pay.billing_cycle when 'monthly' then make_interval(months => greatest(1, coalesce((pay.metadata->>'months')::int, 1))) else interval '1 year' end;$r$);
    if position('''months''' in d) = 0 then raise exception 'confirm_subscription_payment : repère introuvable.'; end if;
    execute d;
  end if;
end $$;

-- Les formules sur devis (Galaxie, Enterprise) ne peuvent jamais être réglées par le paiement en ligne standard.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.start_subscription_checkout(uuid, text, text, text)'::regprocedure);
  if position('if p.is_quote_based then' in d) = 0 then
    d := replace(d, $r$  v_amount := case p_cycle$r$, $r$  if p.is_quote_based then raise exception 'Cette formule est proposée sur devis : contactez-nous.'; end if;
  v_amount := case p_cycle$r$);
    if position('if p.is_quote_based then' in d) = 0 then raise exception 'start_subscription_checkout : repère introuvable.'; end if;
    execute d;
  end if;
end $$;
