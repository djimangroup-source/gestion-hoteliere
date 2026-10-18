-- Horus Hotel — Migration 20 : cinq offres validées le 18/10/2026
-- Essentiel 5 500 · Pro 10 000 · Business 15 000 · Premium 35 000 · Enterprise sur devis (annuel = 10 mois).
-- Premium redevient publique ; NOEL LUXURY (Premium) paiera 35 000 F à son renouvellement.
update public.plans set monthly_price = 10000, yearly_price = 100000, max_users = 6, max_properties = 1, is_recommended = true, sort_order = 20, updated_at = now() where slug = 'pro';
update public.plans set monthly_price = 15000, yearly_price = 150000, max_users = 15, max_properties = 3, is_recommended = false, sort_order = 30,
  description = 'Pour les équipes plus nombreuses et jusqu’à 3 établissements.',
  features = '["reception","reservations","clients","billing","payments","cash","housekeeping","basic_reports","users","pdf_export","online_booking","expenses","owner_control","financial_reports","excel_export","notifications","multi_property"]'::jsonb, updated_at = now() where slug = 'business';
update public.plans set monthly_price = 35000, yearly_price = 350000, max_rooms = null, max_users = null, max_properties = 10, is_public = true, is_recommended = false, sort_order = 40,
  description = 'Utilisateurs illimités, jusqu’à 10 établissements, installation, formation et support prioritaire.',
  features = '["reception","reservations","clients","billing","payments","cash","housekeeping","basic_reports","users","pdf_export","online_booking","expenses","owner_control","financial_reports","excel_export","notifications","multi_property","priority_support","training"]'::jsonb, updated_at = now() where slug = 'premium';
update public.plans set max_rooms = null, max_users = null, max_properties = null, is_public = true, is_quote_based = true, sort_order = 50,
  description = 'Groupes hôteliers : établissements illimités et accompagnement sur mesure. Prix sur devis.',
  features = '["reception","reservations","clients","billing","payments","cash","housekeeping","basic_reports","users","pdf_export","online_booking","expenses","owner_control","financial_reports","excel_export","notifications","multi_property","priority_support","training"]'::jsonb, updated_at = now() where slug = 'enterprise';
