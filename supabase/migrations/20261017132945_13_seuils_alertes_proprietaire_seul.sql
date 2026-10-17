-- Horus Hotel — Migration 13 : seuls le propriétaire (ou le serveur) modifie les seuils d'alerte ; chaque changement est journalisé.
-- Appliquée le 17/10/2026 (version 20261017132945).
create or replace function public.protect_alert_settings()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.alert_discount_pct, new.alert_expense_amount, new.alert_cash_gap_amount) is distinct from (old.alert_discount_pct, old.alert_expense_amount, old.alert_cash_gap_amount)
     and not public.is_service_context() and not public.has_org_role(old.id, array['owner']) then
    raise exception 'Seul le propriétaire peut modifier les seuils d''alerte.';
  end if;
  if (new.alert_discount_pct, new.alert_expense_amount, new.alert_cash_gap_amount) is distinct from (old.alert_discount_pct, old.alert_expense_amount, old.alert_cash_gap_amount) then
    insert into public.audit_log (organization_id, entity, entity_id, action, summary, details, actor_id, actor_role)
    values (old.id, 'reglages', old.id, 'seuils', format('Seuils d''alerte : remise %s %%, dépense %s F, écart de caisse %s F', new.alert_discount_pct, new.alert_expense_amount, new.alert_cash_gap_amount), '{}'::jsonb, auth.uid(), public.actor_role(old.id));
  end if;
  return new;
end $$;
revoke execute on function public.protect_alert_settings() from public, anon, authenticated;
create trigger trg_org_alert_settings before update on public.organizations for each row execute function public.protect_alert_settings();

/* ROLLBACK :
drop trigger if exists trg_org_alert_settings on public.organizations;
drop function if exists public.protect_alert_settings();
*/
