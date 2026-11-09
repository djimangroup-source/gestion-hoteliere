-- 64 · Corrections d'audit : check-in refusé dans une chambre encore occupée, index des clés étrangères,
-- règles d'accès évaluées une seule fois par requête (même sens, plus rapides). Aucune donnée modifiée ni supprimée.

create or replace function public.check_in_reservation(p_reservation uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare r public.reservations; v_hk text; o record;
begin
  select * into r from public.reservations where id = p_reservation for update;
  if not found or not public.has_org_role(r.organization_id, array['owner','admin','manager','receptionist']) then raise exception 'Accès refusé.'; end if;
  if r.status not in ('pending','confirmed') then raise exception 'Cette réservation ne peut pas être enregistrée (statut : %).', r.status; end if;
  if r.check_in > current_date then raise exception 'Arrivée prévue le % : check-in impossible avant cette date.', to_char(r.check_in,'DD/MM/YYYY'); end if;
  select housekeeping_status into v_hk from public.rooms where id = r.room_id;
  if v_hk = 'out_of_service' then raise exception 'La chambre est hors service.'; end if;
  -- Une chambre ne reçoit pas deux clients à la fois : le client précédent doit d'abord partir
  select x.guest_name, x.check_out into o from public.reservations x
   where x.room_id = r.room_id and x.id <> r.id and x.status = 'checked_in' limit 1;
  if found then raise exception 'Chambre encore occupée par % (départ prévu le %) : faites d''abord son check-out ou changez de chambre.', coalesce(o.guest_name, 'un client'), to_char(o.check_out,'DD/MM/YYYY'); end if;
  update public.reservations set status = 'checked_in', checked_in_at = now() where id = r.id;
end $$;

create index if not exists cash_movements_establishment_id_fk_idx on public.cash_movements (establishment_id);
create index if not exists payments_provider_fk_idx on public.payments (provider);
create index if not exists expense_budgets_organization_id_fk_idx on public.expense_budgets (organization_id);
create index if not exists extra_items_organization_id_fk_idx on public.extra_items (organization_id);
create index if not exists id_doc_events_guest_id_fk_idx on public.id_doc_events (guest_id);
create index if not exists expenses_decided_by_fk_idx on public.expenses (decided_by);
create index if not exists supplies_establishment_id_fk_idx on public.supplies (establishment_id);
create index if not exists expenses_organization_id_fk_idx on public.expenses (organization_id);
create index if not exists stock_movements_establishment_id_fk_idx on public.stock_movements (establishment_id);
create index if not exists room_passes_organization_id_fk_idx on public.room_passes (organization_id);
create index if not exists payments_created_by_fk_idx on public.payments (created_by);
create index if not exists extra_receptions_establishment_id_fk_idx on public.extra_receptions (establishment_id);
create index if not exists reservations_guest_id_fk_idx on public.reservations (guest_id);
create index if not exists organizations_created_by_fk_idx on public.organizations (created_by);
create index if not exists cash_movements_created_by_fk_idx on public.cash_movements (created_by);
create index if not exists localities_proposed_by_fk_idx on public.localities (proposed_by);
create index if not exists organization_invitations_establishment_id_fk_idx on public.organization_invitations (establishment_id);
create index if not exists booking_payments_establishment_id_fk_idx on public.booking_payments (establishment_id);
create index if not exists extra_counts_establishment_id_fk_idx on public.extra_counts (establishment_id);
create index if not exists reservations_created_by_fk_idx on public.reservations (created_by);
create index if not exists extra_recipes_ingredient_id_fk_idx on public.extra_recipes (ingredient_id);
create index if not exists supplies_organization_id_fk_idx on public.supplies (organization_id);
create index if not exists stock_movements_sale_id_fk_idx on public.stock_movements (sale_id);
create index if not exists establishment_slug_history_establishment_id_fk_idx on public.establishment_slug_history (establishment_id);
create index if not exists rate_rules_organization_id_fk_idx on public.rate_rules (organization_id);
create index if not exists extra_count_lines_item_id_fk_idx on public.extra_count_lines (item_id);
create index if not exists extra_sales_item_id_fk_idx on public.extra_sales (item_id);
create index if not exists cash_sessions_opened_by_fk_idx on public.cash_sessions (opened_by);
create index if not exists subscriptions_plan_id_fk_idx on public.subscriptions (plan_id);
create index if not exists reviews_organization_id_fk_idx on public.reviews (organization_id);
create index if not exists reservations_establishment_id_fk_idx on public.reservations (establishment_id);
create index if not exists cash_sessions_closed_by_fk_idx on public.cash_sessions (closed_by);
create index if not exists supply_movements_establishment_id_fk_idx on public.supply_movements (establishment_id);
create index if not exists expenses_created_by_fk_idx on public.expenses (created_by);
create index if not exists guest_invoices_issued_by_fk_idx on public.guest_invoices (issued_by);
create index if not exists stock_movements_organization_id_fk_idx on public.stock_movements (organization_id);
create index if not exists cash_movements_session_id_fk_idx on public.cash_movements (session_id);
create index if not exists pos_sales_organization_id_fk_idx on public.pos_sales (organization_id);
create index if not exists naya_commission_payments_recorded_by_fk_idx on public.naya_commission_payments (recorded_by);
create index if not exists products_organization_id_fk_idx on public.products (organization_id);
create index if not exists room_passes_formula_id_fk_idx on public.room_passes (formula_id);
create index if not exists organization_invitations_invited_by_fk_idx on public.organization_invitations (invited_by);
create index if not exists guest_invoices_reservation_id_fk_idx on public.guest_invoices (reservation_id);
create index if not exists expenses_cash_movement_id_fk_idx on public.expenses (cash_movement_id);
create index if not exists attendance_establishment_id_fk_idx on public.attendance (establishment_id);
create index if not exists extra_receptions_organization_id_fk_idx on public.extra_receptions (organization_id);
create index if not exists organization_members_establishment_id_fk_idx on public.organization_members (establishment_id);
create index if not exists supply_movements_organization_id_fk_idx on public.supply_movements (organization_id);
create index if not exists payments_subscription_id_fk_idx on public.payments (subscription_id);
create index if not exists supply_movements_room_id_fk_idx on public.supply_movements (room_id);
create index if not exists pos_sale_items_product_id_fk_idx on public.pos_sale_items (product_id);
create index if not exists recurring_charges_organization_id_fk_idx on public.recurring_charges (organization_id);
create index if not exists extra_sales_organization_id_fk_idx on public.extra_sales (organization_id);
create index if not exists marketplace_listings_organization_id_fk_idx on public.marketplace_listings (organization_id);
create index if not exists recurring_charges_establishment_id_fk_idx on public.recurring_charges (establishment_id);
create index if not exists room_passes_created_by_fk_idx on public.room_passes (created_by);
create index if not exists extra_stock_moves_establishment_id_fk_idx on public.extra_stock_moves (establishment_id);
create index if not exists attendance_user_id_fk_idx on public.attendance (user_id);
create index if not exists guest_invoices_establishment_id_fk_idx on public.guest_invoices (establishment_id);
create index if not exists extra_stock_moves_organization_id_fk_idx on public.extra_stock_moves (organization_id);
create index if not exists payments_plan_id_fk_idx on public.payments (plan_id);
create index if not exists extra_counts_organization_id_fk_idx on public.extra_counts (organization_id);
create index if not exists booking_payments_organization_id_fk_idx on public.booking_payments (organization_id);
create index if not exists pass_formulas_organization_id_fk_idx on public.pass_formulas (organization_id);
create index if not exists subscription_events_subscription_id_fk_idx on public.subscription_events (subscription_id);

alter policy ps_read on public.platform_settings using ((select auth.uid()) is not null);
alter policy naya_travelers_self on public.naya_travelers using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy legal_select_own on public.legal_acceptances using ((user_id = (select auth.uid())) or public.is_platform_admin());
alter policy legal_insert_own on public.legal_acceptances with check (user_id = (select auth.uid()));
alter policy pos_sales_select on public.pos_sales using (public.has_org_role(organization_id, array['owner','admin','manager','accountant']) or (created_by = (select auth.uid())));
alter policy pos_items_select on public.pos_sale_items using (exists (select 1 from public.pos_sales s where s.id = pos_sale_items.sale_id and (public.has_org_role(s.organization_id, array['owner','admin','manager','accountant']) or s.created_by = (select auth.uid()))));
alter policy attendance_select on public.attendance using ((user_id = (select auth.uid())) or public.has_org_role(organization_id, array['owner','admin','manager','accountant']));
