-- Horus Hotel — Migration 12 : journal d'audit infalsifiable, alertes au propriétaire, rapport quotidien.
-- Appliquée le 17/10/2026 (version 20261017132935). Migration additive.
-- Tests (annulés après exécution) : propriétaire non alerté de ses propres actions ; réceptionniste sans accès au journal,
-- aux alertes ni aux seuils ; alertes remise, prix bas, dépense, annulation payée, écart de caisse, prix de chambre ;
-- journal non effaçable ; rapport du jour ; marquage lu.

-- ===== Seuils d'alerte réglables par le propriétaire =====
alter table public.organizations
  add column alert_discount_pct int not null default 10 check (alert_discount_pct between 0 and 100),
  add column alert_expense_amount numeric(12,2) not null default 20000 check (alert_expense_amount >= 0),
  add column alert_cash_gap_amount numeric(12,2) not null default 1000 check (alert_cash_gap_amount >= 0);

-- ===== Journal d'audit (infalsifiable : ni modification ni suppression) =====
create table public.audit_log (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid,
  entity text not null,
  entity_id uuid,
  action text not null,
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  actor_id uuid,
  actor_role text,
  created_at timestamptz not null default now()
);
create index on public.audit_log (organization_id, created_at desc);
create index on public.audit_log (entity, entity_id);
alter table public.audit_log enable row level security;
create policy audit_select on public.audit_log for select to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin'])) or (select public.is_platform_admin()));
create trigger trg_audit_immutable before update or delete on public.audit_log for each row execute function public.forbid_change();

-- ===== Alertes au propriétaire =====
create table public.owner_alerts (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid,
  severity text not null check (severity in ('info','warning','critical')),
  kind text not null,
  message text not null,
  entity text, entity_id uuid,
  actor_id uuid, actor_role text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  read_by uuid
);
create index on public.owner_alerts (organization_id, created_at desc);
create index on public.owner_alerts (organization_id) where read_at is null;
alter table public.owner_alerts enable row level security;
create policy alerts_select on public.owner_alerts for select to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin'])));
-- Lecture marquée uniquement via une fonction (le message lui-même reste intact)
create or replace function public.mark_alerts_read(p_org uuid, p_ids bigint[] default null)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.has_org_role(p_org, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  update public.owner_alerts set read_at = now(), read_by = auth.uid()
   where organization_id = p_org and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count; return n;
end $$;

-- ===== Fonctions internes d'écriture =====
create or replace function public.actor_role(p_org uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select role from public.organization_members where organization_id = p_org and user_id = auth.uid() limit 1),
                  case when auth.uid() is null then 'systeme' else 'inconnu' end);
$$;
create or replace function public.write_audit(p_org uuid, p_est uuid, p_entity text, p_id uuid, p_action text, p_summary text, p_details jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (organization_id, establishment_id, entity, entity_id, action, summary, details, actor_id, actor_role)
  values (p_org, p_est, p_entity, p_id, p_action, p_summary, coalesce(p_details, '{}'::jsonb), auth.uid(), public.actor_role(p_org));
$$;
create or replace function public.raise_owner_alert(p_org uuid, p_est uuid, p_sev text, p_kind text, p_msg text, p_entity text, p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_role text := public.actor_role(p_org);
begin
  -- le propriétaire n'est pas alerté de ses propres actions
  if v_role = 'owner' then return; end if;
  insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message, entity, entity_id, actor_id, actor_role)
  values (p_org, p_est, p_sev, p_kind, p_msg, p_entity, p_id, auth.uid(), v_role);
end $$;
revoke execute on function public.actor_role(uuid), public.write_audit(uuid, uuid, text, uuid, text, text, jsonb),
  public.raise_owner_alert(uuid, uuid, text, text, text, text, uuid) from public, anon, authenticated;

-- ===== Réservations =====
create or replace function public.audit_reservations()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r public.reservations := coalesce(new, old); v_room text; v_paid numeric; v_base numeric; v_pct int; d jsonb := '{}'::jsonb; v_label text;
begin
  select number, base_rate into v_room, v_base from public.rooms where id = r.room_id;
  v_label := format('%s (ch. %s, %s → %s)', r.guest_name, v_room, to_char(r.check_in, 'DD/MM'), to_char(r.check_out, 'DD/MM'));
  select alert_discount_pct into v_pct from public.organizations where id = r.organization_id;
  if tg_op = 'INSERT' then
    perform public.write_audit(r.organization_id, r.establishment_id, 'reservation', r.id, 'creation',
      format('Réservation créée : %s, %s F', v_label, r.total_amount), jsonb_build_object('source', r.source, 'statut', r.status, 'total', r.total_amount, 'remise', r.discount, 'prix_nuit', r.nightly_rate));
  elsif tg_op = 'UPDATE' then
    if new.status is distinct from old.status then d := d || jsonb_build_object('statut', jsonb_build_array(old.status, new.status)); end if;
    if new.check_in is distinct from old.check_in or new.check_out is distinct from old.check_out then d := d || jsonb_build_object('dates', jsonb_build_array(old.check_in || ' → ' || old.check_out, new.check_in || ' → ' || new.check_out)); end if;
    if new.room_id is distinct from old.room_id then d := d || jsonb_build_object('chambre', jsonb_build_array(old.room_id, new.room_id)); end if;
    if new.nightly_rate is distinct from old.nightly_rate then d := d || jsonb_build_object('prix_nuit', jsonb_build_array(old.nightly_rate, new.nightly_rate)); end if;
    if new.discount is distinct from old.discount then d := d || jsonb_build_object('remise', jsonb_build_array(old.discount, new.discount)); end if;
    if new.total_amount is distinct from old.total_amount then d := d || jsonb_build_object('total', jsonb_build_array(old.total_amount, new.total_amount)); end if;
    if d = '{}'::jsonb then return new; end if;
    perform public.write_audit(r.organization_id, r.establishment_id, 'reservation', r.id, 'modification', 'Réservation modifiée : ' || v_label, d);
  else
    perform public.write_audit(r.organization_id, r.establishment_id, 'reservation', r.id, 'suppression', 'Réservation supprimée : ' || v_label, to_jsonb(old));
    perform public.raise_owner_alert(r.organization_id, r.establishment_id, 'critical', 'reservation_deleted', 'Réservation supprimée : ' || v_label, 'reservation', r.id);
    return old;
  end if;

  -- Alertes
  select coalesce(sum(case when kind = 'payment' then amount when kind = 'refund' then -amount else 0 end), 0) into v_paid from public.cash_movements where reservation_id = r.id;
  if tg_op = 'UPDATE' and new.status = 'cancelled' and old.status <> 'cancelled' and v_paid > 0 then
    perform public.raise_owner_alert(r.organization_id, r.establishment_id, 'critical', 'cancel_paid', format('Réservation annulée alors que %s F ont été encaissés : %s', v_paid, v_label), 'reservation', r.id);
  end if;
  if tg_op = 'UPDATE' and new.status = 'checked_out' and old.status <> 'checked_out' and new.total_amount - v_paid > 0 then
    perform public.raise_owner_alert(r.organization_id, r.establishment_id, 'warning', 'checkout_unpaid', format('Départ avec solde impayé de %s F : %s', new.total_amount - v_paid, v_label), 'reservation', r.id);
  end if;
  if (tg_op = 'INSERT' or new.discount is distinct from old.discount or new.nightly_rate is distinct from old.nightly_rate) then
    if new.discount > 0 and (new.check_out - new.check_in) * new.nightly_rate > 0
       and new.discount * 100 > v_pct * (new.check_out - new.check_in) * new.nightly_rate then
      perform public.raise_owner_alert(r.organization_id, r.establishment_id, 'warning', 'big_discount', format('Remise de %s F (%s %%) accordée : %s', new.discount, round(new.discount * 100 / ((new.check_out - new.check_in) * new.nightly_rate)), v_label), 'reservation', r.id);
    end if;
    if v_base is not null and v_base > 0 and new.nightly_rate < v_base * (100 - v_pct) / 100.0 then
      perform public.raise_owner_alert(r.organization_id, r.establishment_id, 'warning', 'low_rate', format('Prix de %s F/nuit au lieu de %s F : %s', new.nightly_rate, v_base, v_label), 'reservation', r.id);
    end if;
  end if;
  if tg_op = 'UPDATE' and (new.check_in <> old.check_in or new.check_out <> old.check_out) and old.status = 'checked_in' then
    perform public.raise_owner_alert(r.organization_id, r.establishment_id, 'info', 'stay_changed', 'Séjour en cours modifié : ' || v_label, 'reservation', r.id);
  end if;
  return new;
end $$;
revoke execute on function public.audit_reservations() from public, anon, authenticated;
create trigger trg_zz_audit_resa after insert or update or delete on public.reservations for each row execute function public.audit_reservations();

-- ===== Caisse =====
create or replace function public.audit_cash_movements()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_thr numeric;
begin
  select alert_expense_amount into v_thr from public.organizations where id = new.organization_id;
  perform public.write_audit(new.organization_id, new.establishment_id, 'caisse', new.id, new.kind,
    format('%s : %s F (%s) — %s', case new.kind when 'payment' then 'Encaissement' when 'income' then 'Entrée' when 'expense' then 'Dépense' else 'Remboursement' end, new.amount, new.method, new.label),
    jsonb_build_object('reservation', new.reservation_id, 'reference', new.reference));
  if new.kind = 'refund' then
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'refund', format('Remboursement de %s F : %s', new.amount, new.label), 'caisse', new.id);
  elsif new.kind = 'expense' and new.amount >= v_thr then
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'big_expense', format('Dépense de %s F : %s', new.amount, new.label), 'caisse', new.id);
  end if;
  return new;
end $$;
revoke execute on function public.audit_cash_movements() from public, anon, authenticated;
create trigger trg_zz_audit_cash after insert on public.cash_movements for each row execute function public.audit_cash_movements();

create or replace function public.audit_cash_sessions()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_exp numeric; v_gap numeric; v_thr numeric;
begin
  if tg_op = 'INSERT' then
    perform public.write_audit(new.organization_id, new.establishment_id, 'caisse', new.id, 'ouverture', format('Caisse ouverte avec un fond de %s F', new.opening_balance), '{}'::jsonb);
    return new;
  end if;
  if new.status = 'closed' and old.status = 'open' then
    select new.opening_balance + coalesce(sum(case when kind in ('payment','income') then amount else -amount end), 0) into v_exp
      from public.cash_movements where session_id = new.id and method = 'cash';
    v_gap := coalesce(new.counted_balance, 0) - v_exp;
    select alert_cash_gap_amount into v_thr from public.organizations where id = new.organization_id;
    perform public.write_audit(new.organization_id, new.establishment_id, 'caisse', new.id, 'cloture',
      format('Caisse clôturée : attendu %s F, compté %s F, écart %s F', v_exp, new.counted_balance, v_gap), jsonb_build_object('attendu', v_exp, 'compte', new.counted_balance, 'ecart', v_gap));
    if abs(v_gap) >= greatest(v_thr, 1) then
      perform public.raise_owner_alert(new.organization_id, new.establishment_id, case when v_gap < 0 then 'critical' else 'warning' end, 'cash_gap',
        format('Écart de caisse de %s F à la clôture (attendu %s F, compté %s F)', v_gap, v_exp, new.counted_balance), 'caisse', new.id);
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.audit_cash_sessions() from public, anon, authenticated;
create trigger trg_zz_audit_cashsess after insert or update on public.cash_sessions for each row execute function public.audit_cash_sessions();

-- ===== Chambres (prix, mise hors ligne) =====
create or replace function public.audit_rooms()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.write_audit(new.organization_id, new.establishment_id, 'chambre', new.id, 'creation', format('Chambre %s créée (%s F/nuit)', new.number, coalesce(new.base_rate, 0)), '{}'::jsonb);
  elsif new.base_rate is distinct from old.base_rate then
    perform public.write_audit(new.organization_id, new.establishment_id, 'chambre', new.id, 'prix', format('Prix de la chambre %s : %s F → %s F', new.number, coalesce(old.base_rate, 0), coalesce(new.base_rate, 0)), '{}'::jsonb);
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'room_price', format('Prix de la chambre %s modifié : %s F → %s F', new.number, coalesce(old.base_rate, 0), coalesce(new.base_rate, 0)), 'chambre', new.id);
  elsif new.is_active is distinct from old.is_active then
    perform public.write_audit(new.organization_id, new.establishment_id, 'chambre', new.id, case when new.is_active then 'reactivation' else 'desactivation' end, format('Chambre %s %s', new.number, case when new.is_active then 'réactivée' else 'désactivée' end), '{}'::jsonb);
    if not new.is_active then perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'room_disabled', format('Chambre %s désactivée', new.number), 'chambre', new.id); end if;
  elsif new.housekeeping_status = 'out_of_service' and old.housekeeping_status <> 'out_of_service' then
    perform public.write_audit(new.organization_id, new.establishment_id, 'chambre', new.id, 'hors_service', format('Chambre %s mise hors service', new.number), '{}'::jsonb);
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'info', 'room_oos', format('Chambre %s mise hors service', new.number), 'chambre', new.id);
  end if;
  return new;
end $$;
revoke execute on function public.audit_rooms() from public, anon, authenticated;
create trigger trg_zz_audit_rooms after insert or update on public.rooms for each row execute function public.audit_rooms();

-- ===== Équipe =====
create or replace function public.audit_members()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.write_audit(new.organization_id, new.establishment_id, 'equipe', new.id, 'ajout', format('Membre ajouté (rôle %s)', new.role), jsonb_build_object('user_id', new.user_id));
  elsif new.role is distinct from old.role or new.is_active is distinct from old.is_active then
    perform public.write_audit(new.organization_id, new.establishment_id, 'equipe', new.id, 'modification',
      format('Membre : rôle %s → %s, %s', old.role, new.role, case when new.is_active then 'actif' else 'désactivé' end), jsonb_build_object('user_id', new.user_id));
  end if;
  return new;
end $$;
revoke execute on function public.audit_members() from public, anon, authenticated;
create trigger trg_zz_audit_members after insert or update on public.organization_members for each row execute function public.audit_members();

-- ===== Factures =====
create or replace function public.audit_invoices()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.write_audit(new.organization_id, new.establishment_id, 'facture', new.id, 'emission', format('Facture %s émise : %s, %s F (reste %s F)', new.number, new.guest_name, new.total, new.balance), '{}'::jsonb);
  return new;
end $$;
revoke execute on function public.audit_invoices() from public, anon, authenticated;
create trigger trg_zz_audit_invoices after insert on public.guest_invoices for each row execute function public.audit_invoices();

-- ===== Rapport quotidien =====
create or replace function public.daily_report(p_org uuid, p_day date default current_date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not public.has_org_role(p_org, array['owner','admin','accountant']) then raise exception 'Accès refusé.'; end if;
  select jsonb_build_object(
    'day', p_day,
    'rooms', (select count(*) from public.rooms where organization_id = p_org and is_active),
    'occupied', (select count(*) from public.reservations where organization_id = p_org and status in ('checked_in','checked_out','confirmed') and check_in <= p_day and check_out > p_day and status <> 'cancelled'),
    'arrivals', (select count(*) from public.reservations where organization_id = p_org and check_in = p_day and status not in ('cancelled','no_show')),
    'departures', (select count(*) from public.reservations where organization_id = p_org and check_out = p_day and status not in ('cancelled','no_show')),
    'new_reservations', (select count(*) from public.reservations where organization_id = p_org and created_at::date = p_day),
    'cancellations', (select count(*) from public.audit_log where organization_id = p_org and entity = 'reservation' and created_at::date = p_day and details->'statut'->>1 = 'cancelled'),
    'cash_in', (select coalesce(sum(amount), 0) from public.cash_movements where organization_id = p_org and created_at::date = p_day and kind in ('payment','income')),
    'cash_out', (select coalesce(sum(amount), 0) from public.cash_movements where organization_id = p_org and created_at::date = p_day and kind in ('expense','refund')),
    'by_method', (select coalesce(jsonb_object_agg(method, total), '{}'::jsonb) from (select method, sum(case when kind in ('payment','income') then amount else -amount end) total from public.cash_movements where organization_id = p_org and created_at::date = p_day group by method) x),
    'alerts', (select count(*) from public.owner_alerts where organization_id = p_org and created_at::date = p_day),
    'critical_alerts', (select count(*) from public.owner_alerts where organization_id = p_org and created_at::date = p_day and severity = 'critical')
  ) into v;
  return v;
end $$;

revoke execute on function public.mark_alerts_read(uuid, bigint[]), public.daily_report(uuid, date) from public, anon;
grant execute on function public.mark_alerts_read(uuid, bigint[]), public.daily_report(uuid, date) to authenticated;

/* ROLLBACK (supprime le journal et les alertes) :
drop trigger if exists trg_zz_audit_invoices on public.guest_invoices;   drop function if exists public.audit_invoices();
drop trigger if exists trg_zz_audit_members on public.organization_members; drop function if exists public.audit_members();
drop trigger if exists trg_zz_audit_rooms on public.rooms;               drop function if exists public.audit_rooms();
drop trigger if exists trg_zz_audit_cashsess on public.cash_sessions;    drop function if exists public.audit_cash_sessions();
drop trigger if exists trg_zz_audit_cash on public.cash_movements;       drop function if exists public.audit_cash_movements();
drop trigger if exists trg_zz_audit_resa on public.reservations;         drop function if exists public.audit_reservations();
drop function if exists public.daily_report(uuid, date); drop function if exists public.mark_alerts_read(uuid, bigint[]);
drop function if exists public.raise_owner_alert(uuid, uuid, text, text, text, text, uuid);
drop function if exists public.write_audit(uuid, uuid, text, uuid, text, text, jsonb); drop function if exists public.actor_role(uuid);
drop table if exists public.owner_alerts; drop table if exists public.audit_log;
alter table public.organizations drop column if exists alert_discount_pct, drop column if exists alert_expense_amount, drop column if exists alert_cash_gap_amount;
*/
