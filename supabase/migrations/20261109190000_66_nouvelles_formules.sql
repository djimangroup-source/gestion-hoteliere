-- 66 · Nouvelles formules : Essentiel 2 500 F, Confort 5 000 F, Pro 10 000 F, Premium 25 000 F, Groupe sur devis.
-- Prix annuel = 12 mois (pas de remise). Les anciennes formules sont masquées, jamais supprimées :
-- les comptes qui les utilisent les gardent, à leur prix, jusqu'à leur échéance.

-- Essentiel (slug réutilisé : aucun abonné)
update public.plans set name = 'Essentiel', monthly_price = 2500, yearly_price = 30000, max_rooms = 5, max_users = 1, max_properties = 1,
  features = jsonb_build_array('reception','reservations','clients','payments','cash','housekeeping','users','notifications','pdf_export'),
  is_public = true, is_active = true, is_recommended = false, is_trial = false, is_quote_based = false, sort_order = 10, updated_at = now()
where slug = 'essentiel';

-- Confort (nouvelle)
insert into public.plans (name, slug, currency, monthly_price, yearly_price, max_rooms, max_users, max_properties, features, is_public, is_active, is_recommended, is_trial, is_quote_based, sort_order)
values ('Confort', 'confort', 'XOF', 5000, 60000, 15, 3, 1,
  jsonb_build_array('reception','reservations','clients','payments','cash','housekeeping','users','notifications','pdf_export','billing','expenses','basic_reports'),
  true, true, false, false, false, 20)
on conflict (slug) do nothing;

-- Pro (slug réutilisé : aucun abonné)
update public.plans set name = 'Pro', monthly_price = 10000, yearly_price = 120000, max_rooms = 30, max_users = 6, max_properties = 1,
  features = jsonb_build_array('reception','reservations','clients','payments','cash','housekeeping','users','notifications','pdf_export','billing','expenses','basic_reports',
    'online_booking','owner_control','financial_reports','excel_export','daily_summary','restaurant'),
  is_public = true, is_active = true, is_recommended = true, is_trial = false, is_quote_based = false, sort_order = 30, updated_at = now()
where slug = 'pro';

-- Premium 25 000 F (nouvel identifiant : l'ancienne Premium à 35 000 F a un abonné qui garde son prix)
insert into public.plans (name, slug, currency, monthly_price, yearly_price, max_rooms, max_users, max_properties, features, is_public, is_active, is_recommended, is_trial, is_quote_based, sort_order)
values ('Premium', 'premium-plus', 'XOF', 25000, 300000, null, null, 10,
  jsonb_build_array('reception','reservations','clients','payments','cash','housekeeping','users','notifications','pdf_export','billing','expenses','basic_reports',
    'online_booking','owner_control','financial_reports','excel_export','daily_summary','restaurant','multi_property','seasonal_rates','extra_services','whatsapp_auto','priority_support'),
  true, true, false, false, false, 40)
on conflict (slug) do nothing;

-- Groupe (sur devis)
insert into public.plans (name, slug, currency, monthly_price, yearly_price, max_rooms, max_users, max_properties, features, is_public, is_active, is_recommended, is_trial, is_quote_based, sort_order)
values ('Groupe', 'groupe', 'XOF', 0, null, null, null, null,
  jsonb_build_array('reception','reservations','clients','payments','cash','housekeeping','users','notifications','pdf_export','billing','expenses','basic_reports',
    'online_booking','owner_control','financial_reports','excel_export','daily_summary','restaurant','multi_property','seasonal_rates','extra_services','whatsapp_auto','priority_support','training'),
  true, true, false, false, true, 50)
on conflict (slug) do nothing;

-- Anciennes formules : retirées de la page des formules (les abonnés les conservent)
update public.plans set is_public = false, is_recommended = false, updated_at = now()
where slug in ('decouverte','veille','nuit','etoile','constellation','galaxie','standard','business','enterprise','premium');
