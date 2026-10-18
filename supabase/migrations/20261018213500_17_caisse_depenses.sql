-- Horus Hotel — Migration 17 : caisse améliorée et module Dépenses.
-- Additive : nouvelles colonnes, nouvelles tables, fonctions remplacées sans perte de comportement.
-- Aucune donnée existante n'est modifiée ni supprimée.

-- ===== 1. Caisse : catégories, justificatifs, paiements groupés, versements =====
alter table public.cash_movements
  add column if not exists category text check (category is null or length(category) <= 60),
  add column if not exists receipt_path text check (receipt_path is null or length(receipt_path) <= 300),
  add column if not exists payment_group uuid,
  add column if not exists expense_id uuid;
create index if not exists cash_movements_group_idx on public.cash_movements (payment_group) where payment_group is not null;

alter table public.cash_movements drop constraint cash_movements_kind_check;
alter table public.cash_movements add constraint cash_movements_kind_check
  check (kind in ('payment','income','expense','refund','deposit'));
-- Référence de transaction obligatoire pour les encaissements Mobile Money (nouvelles écritures uniquement)
alter table public.cash_movements add constraint cash_movements_momo_ref
  check (kind <> 'payment' or method not in ('orange_money','mtn_money','moov_money','wave') or length(trim(coalesce(reference, ''))) >= 4) not valid;

alter table public.cash_sessions
  add column if not exists counted_detail jsonb,
  add column if not exists gap_reason text check (gap_reason is null or length(gap_reason) <= 300);

create or replace function public.prepare_cash_session()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_exp numeric;
begin
  select organization_id into new.organization_id from public.establishments where id = new.establishment_id;
  if tg_op = 'INSERT' then new.opened_by := auth.uid(); new.status := 'open'; new.closed_at := null; end if;
  if tg_op = 'UPDATE' and old.status = 'closed' then raise exception 'Une caisse clôturée ne peut plus être modifiée.'; end if;
  if tg_op = 'UPDATE' and new.status = 'closed' and old.status = 'open' then
    new.closed_by := auth.uid(); new.closed_at := now();
    select new.opening_balance + coalesce(sum(case when kind in ('payment','income') then amount else -amount end), 0) into v_exp
      from public.cash_movements where session_id = new.id and method = 'cash';
    if coalesce(new.counted_balance, 0) <> v_exp and length(trim(coalesce(new.gap_reason, ''))) < 3 then
      raise exception 'Indiquez le motif de l''écart de caisse (% F).', coalesce(new.counted_balance, 0) - v_exp;
    end if;
  end if;
  return new;
end $$;

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
      format('Caisse clôturée : attendu %s F, compté %s F, écart %s F%s', v_exp, new.counted_balance, v_gap, case when v_gap <> 0 then ' — motif : ' || new.gap_reason else '' end),
      jsonb_build_object('attendu', v_exp, 'compte', new.counted_balance, 'ecart', v_gap, 'motif', new.gap_reason, 'detail', new.counted_detail));
    if abs(v_gap) >= greatest(v_thr, 1) then
      perform public.raise_owner_alert(new.organization_id, new.establishment_id, case when v_gap < 0 then 'critical' else 'warning' end, 'cash_gap',
        format('Écart de caisse de %s F à la clôture (attendu %s F, compté %s F). Motif : %s', v_gap, v_exp, new.counted_balance, coalesce(new.gap_reason, '—')), 'caisse', new.id);
    end if;
  end if;
  return new;
end $$;

create or replace function public.audit_cash_movements()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_thr numeric;
begin
  select alert_expense_amount into v_thr from public.organizations where id = new.organization_id;
  perform public.write_audit(new.organization_id, new.establishment_id, 'caisse', new.id, new.kind,
    format('%s : %s F (%s) — %s', case new.kind when 'payment' then 'Encaissement' when 'income' then 'Entrée' when 'expense' then 'Dépense' when 'deposit' then 'Versement banque' else 'Remboursement' end, new.amount, new.method, new.label),
    jsonb_build_object('reservation', new.reservation_id, 'reference', new.reference, 'groupe', new.payment_group));
  if new.kind = 'refund' then
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'refund', format('Remboursement de %s F : %s', new.amount, new.label), 'caisse', new.id);
  elsif new.kind = 'expense' and new.expense_id is null and new.amount >= v_thr then
    -- les dépenses saisies par le module Dépenses ont leur propre alerte
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'big_expense', format('Dépense de %s F : %s', new.amount, new.label), 'caisse', new.id);
  end if;
  return new;
end $$;

-- ===== 2. Dépenses =====
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  nature text not null default 'operational' check (nature in ('fixed','operational')),
  category text not null check (length(category) between 1 and 60),
  label text not null check (length(label) between 1 and 200),
  amount numeric(14,2) not null check (amount > 0),
  method text check (method in ('cash','orange_money','mtn_money','moov_money','wave','card','bank_transfer')),
  reference text check (reference is null or length(reference) <= 80),
  status text not null default 'paid' check (status in ('due','paid','pending','rejected')),
  due_date date,
  paid_on date,
  receipt_path text check (receipt_path is null or length(receipt_path) <= 300),
  recurring_id uuid,
  cash_movement_id uuid references public.cash_movements(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_note text check (decision_note is null or length(decision_note) <= 300),
  check (status = 'due' or (method is not null and paid_on is not null)),
  check (status <> 'due' or due_date is not null)
);
create index on public.expenses (establishment_id, paid_on);
create index on public.expenses (establishment_id, due_date) where status = 'due';
create unique index expenses_recurring_month on public.expenses (recurring_id, due_date) where recurring_id is not null;
alter table public.expenses enable row level security;

create table public.recurring_charges (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  label text not null check (length(label) between 1 and 200),
  category text not null check (length(category) between 1 and 60),
  amount numeric(14,2) not null check (amount > 0),
  day_of_month int not null default 1 check (day_of_month between 1 and 28),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.recurring_charges enable row level security;
alter table public.expenses add constraint expenses_recurring_fk foreign key (recurring_id) references public.recurring_charges(id) on delete set null;

create table public.expense_budgets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  category text not null check (length(category) between 1 and 60),
  monthly_amount numeric(14,2) not null check (monthly_amount >= 0),
  updated_at timestamptz not null default now(),
  unique (establishment_id, category)
);
alter table public.expense_budgets enable row level security;

-- Rattachement à l'organisation de l'établissement (jamais fourni par le navigateur)
create trigger trg_00_recurring_sync before insert or update on public.recurring_charges for each row execute function public.sync_org_from_establishment();
create trigger trg_00_budget_sync before insert or update on public.expense_budgets for each row execute function public.sync_org_from_establishment();
create trigger trg_recurring_guard before insert or update on public.recurring_charges for each row execute function public.guard_org_writable();
create trigger trg_budget_guard before insert or update on public.expense_budgets for each row execute function public.guard_org_writable();
create trigger trg_expense_guard before insert or update on public.expenses for each row execute function public.guard_org_writable();

-- Règles d'une dépense : approbation, justificatif, sortie de caisse automatique, caractère définitif
create or replace function public.prepare_expense()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_thr numeric; v_owner boolean; v_mv uuid;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'due' then raise exception 'Une dépense enregistrée est définitive : elle ne peut pas être supprimée.'; end if;
    if not public.is_service_context() and not public.has_org_role(old.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
    return old;
  end if;

  select organization_id into new.organization_id from public.establishments where id = new.establishment_id;
  if new.organization_id is null then raise exception 'Établissement introuvable.'; end if;

  if tg_op = 'UPDATE' then
    if current_setting('app.expense_decision', true) = 'on' then return new; end if;
    if old.status <> 'due' then raise exception 'Une dépense enregistrée est définitive : elle ne peut plus être modifiée.'; end if;
    if new.organization_id <> old.organization_id or new.establishment_id <> old.establishment_id or new.recurring_id is distinct from old.recurring_id then
      raise exception 'Modification interdite.';
    end if;
    new.created_by := old.created_by; new.created_at := old.created_at;
  else
    new.created_by := auth.uid(); new.created_at := now();
  end if;
  new.decided_by := null; new.decided_at := null; new.decision_note := null;
  if new.status in ('pending','rejected') then new.status := 'paid'; end if;  -- seul le propriétaire décide

  if new.status = 'paid' then
    new.paid_on := coalesce(new.paid_on, current_date);
    if new.method is null then raise exception 'Indiquez le moyen de paiement.'; end if;
    select alert_expense_amount into v_thr from public.organizations where id = new.organization_id;
    v_owner := public.is_service_context() or public.has_org_role(new.organization_id, array['owner']);
    if not v_owner and new.amount >= v_thr then
      if new.receipt_path is null then raise exception 'Justificatif obligatoire pour une dépense de % F ou plus.', v_thr; end if;
      new.status := 'pending';
    end if;
    if new.method = 'cash' and new.cash_movement_id is null then
      insert into public.cash_movements (establishment_id, kind, method, amount, label, reference, category, receipt_path, expense_id)
      values (new.establishment_id, 'expense', 'cash', new.amount, new.label, new.reference, new.category, new.receipt_path, new.id)
      returning id into v_mv;
      new.cash_movement_id := v_mv;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.prepare_expense() from public, anon, authenticated;
create trigger trg_01_expense_prepare before insert or update or delete on public.expenses for each row execute function public.prepare_expense();

create or replace function public.audit_expense()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or old.status is distinct from new.status then
    perform public.write_audit(new.organization_id, new.establishment_id, 'depense', new.id,
      case when tg_op = 'INSERT' then 'creation' else new.status end,
      format('Dépense %s : %s F — %s (%s)', case new.status when 'due' then 'à payer' when 'paid' then 'payée' when 'pending' then 'en attente de validation' else 'contestée' end, new.amount, new.label, new.category),
      jsonb_build_object('nature', new.nature, 'methode', new.method, 'note', new.decision_note));
  end if;
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status <> 'pending') then
    perform public.raise_owner_alert(new.organization_id, new.establishment_id, 'warning', 'expense_pending',
      format('Dépense à valider : %s F — %s (%s)', new.amount, new.label, new.category), 'depense', new.id);
  end if;
  return new;
end $$;
revoke execute on function public.audit_expense() from public, anon, authenticated;
create trigger trg_zz_audit_expense after insert or update on public.expenses for each row execute function public.audit_expense();

-- Décision du propriétaire sur une dépense en attente
create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_note text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare e public.expenses;
begin
  select * into e from public.expenses where id = p_id for update;
  if not found or not public.has_org_role(e.organization_id, array['owner']) then raise exception 'Accès refusé.'; end if;
  if e.status <> 'pending' then raise exception 'Cette dépense n''est pas en attente de validation.'; end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Indiquez le motif du refus.'; end if;
  perform set_config('app.expense_decision', 'on', true);
  update public.expenses set status = case when p_approve then 'paid' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
  perform set_config('app.expense_decision', 'off', true);
  return case when p_approve then 'paid' else 'rejected' end;
end $$;

-- Création des charges fixes du mois (idempotent)
create or replace function public.generate_recurring_charges(p_est uuid, p_month date default current_date)
returns int language plpgsql security definer set search_path = '' as $$
declare v_org uuid; n int; v_start date := date_trunc('month', p_month)::date;
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if v_org is null or not public.has_org_role(v_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  insert into public.expenses (establishment_id, nature, category, label, amount, status, due_date, recurring_id)
  select r.establishment_id, 'fixed', r.category, r.label, r.amount, 'due', v_start + (r.day_of_month - 1), r.id
    from public.recurring_charges r
   where r.establishment_id = p_est and r.is_active and r.created_at::date <= (v_start + interval '1 month - 1 day')::date
  on conflict (recurring_id, due_date) where recurring_id is not null do nothing;
  get diagnostics n = row_count; return n;
end $$;

revoke execute on function public.decide_expense(uuid, boolean, text), public.generate_recurring_charges(uuid, date) from public, anon;
grant execute on function public.decide_expense(uuid, boolean, text), public.generate_recurring_charges(uuid, date) to authenticated;

-- RLS
create policy exp_select on public.expenses for select to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist','accountant'])));
create policy exp_insert on public.expenses for insert to authenticated
  with check ((select public.has_org_role((select e.organization_id from public.establishments e where e.id = establishment_id), array['owner','admin','manager','receptionist','accountant'])));
create policy exp_update on public.expenses for update to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin','manager','receptionist','accountant'])));
create policy exp_delete on public.expenses for delete to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin','manager'])));

create policy rc_select on public.recurring_charges for select to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin','manager','accountant'])));
create policy rc_write on public.recurring_charges for all to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin','manager','accountant'])))
  with check ((select public.has_org_role((select e.organization_id from public.establishments e where e.id = establishment_id), array['owner','admin','manager','accountant'])));

create policy eb_select on public.expense_budgets for select to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin','manager','accountant'])));
create policy eb_write on public.expense_budgets for all to authenticated
  using ((select public.has_org_role(organization_id, array['owner','admin'])))
  with check ((select public.has_org_role((select e.organization_id from public.establishments e where e.id = establishment_id), array['owner','admin'])));

grant select, insert, update, delete on public.expenses, public.recurring_charges, public.expense_budgets to authenticated;

-- Budget fixé par le propriétaire : toute modification est journalisée
create or replace function public.audit_expense_budget()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.write_audit(coalesce(new.organization_id, old.organization_id), coalesce(new.establishment_id, old.establishment_id), 'budget',
    coalesce(new.id, old.id), lower(tg_op), format('Budget %s : %s F / mois', coalesce(new.category, old.category), coalesce(new.monthly_amount, 0)), '{}'::jsonb);
  return coalesce(new, old);
end $$;
revoke execute on function public.audit_expense_budget() from public, anon, authenticated;
create trigger trg_zz_audit_budget after insert or update or delete on public.expense_budgets for each row execute function public.audit_expense_budget();

-- ===== 3. Justificatifs : stockage privé =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy receipts_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and exists (select 1 from public.organization_members m
    where m.organization_id::text = (storage.foldername(name))[1] and m.user_id = (select auth.uid()) and m.is_active
      and m.role in ('owner','admin','manager','receptionist','accountant')));
create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and exists (select 1 from public.organization_members m
    where m.organization_id::text = (storage.foldername(name))[1] and m.user_id = (select auth.uid()) and m.is_active
      and m.role in ('owner','admin','manager','receptionist','accountant')));

-- ===== 4. Rapport financier : dépenses issues du module Dépenses =====
create or replace function public.financial_report(p_org uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_days int;
begin
  if not public.has_org_role(p_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Période invalide.'; end if;
  v_days := p_to - p_from + 1;
  if v_days > 366 then raise exception 'Période limitée à 366 jours.'; end if;

  with days as (select generate_series(p_from, p_to, interval '1 day')::date d),
  rooms as (select count(*)::numeric n from public.rooms where organization_id = p_org and is_active),
  nights as (
    select d.d, r.id res_id, r.room_id, r.source,
           r.nightly_rate - case when (r.check_out - r.check_in) > 0 then r.discount / (r.check_out - r.check_in) else 0 end as rev
    from public.reservations r join days d on d.d >= r.check_in and d.d < r.check_out
    where r.organization_id = p_org and r.status in ('confirmed','checked_in','checked_out')
  ),
  cash as (
    select created_at::date d, kind, method, amount, expense_id from public.cash_movements
    where organization_id = p_org and created_at >= p_from and created_at < p_to + 1
  ),
  exp as (
    select category, nature, amount from public.expenses
    where organization_id = p_org and status in ('paid','pending','rejected') and paid_on between p_from and p_to
    union all
    select 'Caisse (ancien)', 'operational', amount from cash where kind = 'expense' and expense_id is null
  ),
  series as (
    select d.d, coalesce(sum(n.rev), 0) rev, count(n.res_id) sold,
           (select coalesce(sum(case when kind in ('payment','income') then amount else 0 end), 0) from cash c where c.d = d.d) cash_in
    from days d left join nights n on n.d = d.d group by d.d order by d.d
  ),
  unpaid as (
    select b.id, b.guest_name, b.guest_phone, b.room_number, b.check_in, b.check_out, b.status, b.total_amount, b.paid, b.balance
    from public.reservation_balances b
    where b.organization_id = p_org and b.balance > 0 and b.status in ('checked_in','checked_out','confirmed') and b.check_in <= p_to
    order by b.check_out
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_days,
    'rooms', (select n from rooms),
    'available_nights', (select n from rooms) * v_days,
    'sold_nights', (select count(*) from nights),
    'room_revenue', (select coalesce(round(sum(rev)), 0) from nights),
    'occupancy_pct', case when (select n from rooms) * v_days > 0 then round((select count(*) from nights) * 100.0 / ((select n from rooms) * v_days), 1) else 0 end,
    'adr', case when (select count(*) from nights) > 0 then round((select sum(rev) from nights) / (select count(*) from nights)) else 0 end,
    'revpar', case when (select n from rooms) * v_days > 0 then round(coalesce((select sum(rev) from nights), 0) / ((select n from rooms) * v_days)) else 0 end,
    'cash_in', (select coalesce(sum(amount), 0) from cash where kind in ('payment','income')),
    'expenses', (select coalesce(sum(amount), 0) from exp),
    'expenses_fixed', (select coalesce(sum(amount), 0) from exp where nature = 'fixed'),
    'expenses_by_category', (select coalesce(jsonb_object_agg(category, t), '{}'::jsonb) from (select category, sum(amount) t from exp group by category) x),
    'deposits', (select coalesce(sum(amount), 0) from cash where kind = 'deposit'),
    'refunds', (select coalesce(sum(amount), 0) from cash where kind = 'refund'),
    'by_method', (select coalesce(jsonb_object_agg(method, t), '{}'::jsonb) from (select method, sum(case when kind in ('payment','income') then amount else -amount end) t from cash group by method) x),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'nights', c, 'revenue', round(rv)) order by rv desc), '[]'::jsonb) from (select source, count(*) c, sum(rev) rv from nights group by source) x),
    'by_room', (select coalesce(jsonb_agg(jsonb_build_object('room', number, 'nights', c, 'revenue', round(rv)) order by rv desc), '[]'::jsonb)
                from (select rm.number, count(n.*) c, coalesce(sum(n.rev), 0) rv from public.rooms rm left join nights n on n.room_id = rm.id where rm.organization_id = p_org and rm.is_active group by rm.number) x),
    'cancellations', (select count(*) from public.reservations where organization_id = p_org and status = 'cancelled' and check_in between p_from and p_to),
    'no_shows', (select count(*) from public.reservations where organization_id = p_org and status = 'no_show' and check_in between p_from and p_to),
    'unpaid_total', (select coalesce(sum(balance), 0) from unpaid),
    'unpaid', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from (select * from unpaid limit 200) u),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'rev', round(rev), 'sold', sold, 'cash', cash_in) order by d), '[]'::jsonb) from series)
  ) into v;
  return v;
end $$;

/* ROLLBACK :
drop policy if exists receipts_insert on storage.objects; drop policy if exists receipts_select on storage.objects;
drop function if exists public.decide_expense(uuid, boolean, text); drop function if exists public.generate_recurring_charges(uuid, date);
drop table if exists public.expense_budgets; drop table if exists public.expenses; drop table if exists public.recurring_charges;
drop function if exists public.prepare_expense(); drop function if exists public.audit_expense(); drop function if exists public.audit_expense_budget();
alter table public.cash_movements drop constraint cash_movements_momo_ref;
-- puis restaurer prepare_cash_session, audit_cash_sessions, audit_cash_movements, financial_report (migrations 12 et 14)
*/
