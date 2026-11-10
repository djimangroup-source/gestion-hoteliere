-- 75 · Actions sur les comptes clients depuis la console + alertes e-mail (immédiates et hebdomadaires).
-- Ajouts uniquement. Deux fonctions existantes réécrites de façon ciblée : org_has_feature et enforce_plan_limits
-- (prise en compte des dérogations ; sans dérogation, comportement identique).

-- ===== Dérogations par client =====
alter table public.organizations add column if not exists admin_overrides jsonb not null default '{}'::jsonb;

create or replace function public.org_has_feature(p_org uuid, p_feature text)
returns boolean language sql stable security definer set search_path to '' as $$
  select public.org_can_write(p_org) and (
    exists (select 1 from public.organizations o where o.id = p_org and coalesce(o.admin_overrides->'features_add', '[]') ? p_feature)
    or (exists (select 1 from public.subscriptions s join public.plans p on p.id = s.plan_id where s.organization_id = p_org and p.features ? p_feature)
        and not exists (select 1 from public.organizations o where o.id = p_org and coalesce(o.admin_overrides->'features_remove', '[]') ? p_feature)));
$$;

do $$ declare d text; begin
  d := pg_get_functiondef('public.enforce_plan_limits'::regproc);
  d := replace(d, 'v_max := v_plan.max_rooms;', 'v_max := coalesce((select nullif(o.admin_overrides->>''max_rooms'', '''')::int from public.organizations o where o.id = new.organization_id), v_plan.max_rooms);');
  d := replace(d, 'v_max := v_plan.max_users;', 'v_max := coalesce((select nullif(o.admin_overrides->>''max_users'', '''')::int from public.organizations o where o.id = new.organization_id), v_plan.max_users);');
  execute d;
end $$;

-- ===== Outils internes =====
create or replace function public._notify_org(p_org uuid, p_msg text, p_sev text default 'info')
returns void language sql security definer set search_path to '' as $$
  insert into public.owner_alerts (organization_id, severity, kind, message, actor_id) values (p_org, p_sev, 'nuittea', p_msg, auth.uid());
$$;
revoke all on function public._notify_org(uuid, text, text) from public, anon, authenticated;

create or replace function public._sub_snapshot(p_org uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('plan', p.slug, 'statut', s.status, 'cycle', s.billing_cycle, 'fin', coalesce(s.current_period_end, s.trial_end_at))
  from public.subscriptions s left join public.plans p on p.id = s.plan_id where s.organization_id = p_org;
$$;

-- ===== Abonnement (accès « Finances ») =====
create or replace function public.admin_sub_set(p_org uuid, p_plan text, p_cycle text, p_end timestamptz, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare v_plan public.plans; v_before jsonb := public._sub_snapshot(p_org);
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  select * into v_plan from public.plans where slug = p_plan and is_active and not is_trial;
  if v_plan.id is null then raise exception 'Formule inconnue.'; end if;
  if p_cycle not in ('monthly', 'yearly') then raise exception 'Périodicité invalide.'; end if;
  update public.subscriptions set plan_id = v_plan.id, billing_cycle = p_cycle, status = 'active', suspended_reason = null, cancelled_at = null,
    current_period_start = coalesce(current_period_start, now()),
    current_period_end = coalesce(p_end, case when coalesce(current_period_end, now()) > now() then current_period_end else now() + case when p_cycle = 'yearly' then interval '1 year' else interval '1 month' end end),
    updated_at = now() where organization_id = p_org;
  if not found then raise exception 'Abonnement introuvable.'; end if;
  perform public._staff_log('formule_modifiee', 'organization', p_org::text, jsonb_build_object('avant', v_before, 'apres', public._sub_snapshot(p_org), 'motif', p_reason));
  perform public._notify_org(p_org, format('Votre formule Nuittea Manager est désormais %s (%s), valable jusqu''au %s.', v_plan.name,
    case when p_cycle = 'yearly' then 'annuelle' else 'mensuelle' end, to_char((select current_period_end from public.subscriptions where organization_id = p_org), 'DD/MM/YYYY')));
end $$;

create or replace function public.admin_sub_extend(p_org uuid, p_days int, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare s public.subscriptions; v_before jsonb := public._sub_snapshot(p_org); v_end timestamptz;
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  if coalesce(p_days, 0) not between 1 and 366 then raise exception 'Indiquez un nombre de jours entre 1 et 366.'; end if;
  select * into s from public.subscriptions where organization_id = p_org;
  if s.id is null then raise exception 'Abonnement introuvable.'; end if;
  if s.status = 'trial' or s.billing_cycle = 'trial' then
    v_end := greatest(coalesce(s.trial_end_at, now()), now()) + make_interval(days => p_days);
    update public.subscriptions set status = 'trial', trial_end_at = v_end, updated_at = now() where id = s.id;
  else
    v_end := greatest(coalesce(s.current_period_end, now()), now()) + make_interval(days => p_days);
    update public.subscriptions set status = case when status in ('expired', 'past_due') then 'active' else status end, current_period_end = v_end, updated_at = now() where id = s.id;
  end if;
  perform public._staff_log('abonnement_prolonge', 'organization', p_org::text, jsonb_build_object('jours', p_days, 'avant', v_before, 'apres', public._sub_snapshot(p_org), 'motif', p_reason));
  perform public._notify_org(p_org, format('Nuittea vous offre %s jour(s) supplémentaire(s) : votre accès est prolongé jusqu''au %s.', p_days, to_char(v_end, 'DD/MM/YYYY')));
end $$;

create or replace function public.admin_payment_record(p_org uuid, p_amount int, p_cycle text, p_method text, p_reference text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare s public.subscriptions; v_start timestamptz; v_end timestamptz;
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Indiquez un montant.'; end if;
  if p_cycle not in ('monthly', 'yearly') then raise exception 'Périodicité invalide.'; end if;
  select * into s from public.subscriptions where organization_id = p_org;
  if s.id is null then raise exception 'Abonnement introuvable.'; end if;
  if (select is_trial from public.plans where id = s.plan_id) then raise exception 'Choisissez d''abord une formule payante pour ce client.'; end if;
  v_start := greatest(coalesce(case when s.status in ('active', 'past_due', 'cancelled') then s.current_period_end end, now()), now());
  v_end := v_start + case when p_cycle = 'yearly' then interval '1 year' else interval '1 month' end;
  insert into public.payments (subscription_id, organization_id, plan_id, billing_cycle, amount, currency, payment_method, provider, transaction_reference, status, paid_at, metadata, created_by)
  values (s.id, p_org, s.plan_id, p_cycle, p_amount, 'XOF', p_method, p_method, p_reference, 'succeeded', now(), jsonb_build_object('saisi_par_nuittea', true), auth.uid());
  update public.subscriptions set status = 'active', billing_cycle = p_cycle, current_period_start = v_start, current_period_end = v_end, cancelled_at = null, suspended_reason = null, updated_at = now() where id = s.id;
  perform public._staff_log('paiement_enregistre', 'organization', p_org::text, jsonb_build_object('montant', p_amount, 'moyen', p_method, 'reference', p_reference, 'jusqu_au', v_end));
  perform public._notify_org(p_org, format('Paiement de %s F reçu. Votre abonnement est actif jusqu''au %s. Merci.', p_amount, to_char(v_end, 'DD/MM/YYYY')));
end $$;

create or replace function public.admin_org_suspend(p_org uuid, p_suspend boolean, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare s public.subscriptions;
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  select * into s from public.subscriptions where organization_id = p_org;
  if s.id is null then raise exception 'Abonnement introuvable.'; end if;
  if p_suspend then
    if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Indiquez un motif.'; end if;
    update public.subscriptions set status = 'suspended', suspended_reason = p_reason, updated_at = now() where id = s.id;
    perform public._notify_org(p_org, 'Votre compte Nuittea Manager est suspendu : ' || p_reason || '. Vos données sont conservées. Contactez l''assistance Nuittea.', 'critical');
  else
    update public.subscriptions set suspended_reason = null, updated_at = now(),
      status = case when coalesce(current_period_end, now() - interval '1 day') > now() then 'active' when coalesce(trial_end_at, now() - interval '1 day') > now() then 'trial' else 'expired' end
     where id = s.id;
    perform public._notify_org(p_org, 'Votre compte Nuittea Manager est réactivé.');
  end if;
  perform public._staff_log(case when p_suspend then 'compte_suspendu' else 'compte_reactive' end, 'organization', p_org::text, jsonb_build_object('motif', p_reason));
end $$;

create or replace function public.admin_sub_cancel(p_org uuid, p_immediate boolean, p_reason text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Indiquez un motif.'; end if;
  update public.subscriptions set status = 'cancelled', cancelled_at = now(), updated_at = now(),
    current_period_end = case when p_immediate then now() else current_period_end end where organization_id = p_org;
  if not found then raise exception 'Abonnement introuvable.'; end if;
  perform public._staff_log('abonnement_resilie', 'organization', p_org::text, jsonb_build_object('immediat', p_immediate, 'motif', p_reason));
  perform public._notify_org(p_org, case when p_immediate then 'Votre abonnement Nuittea Manager est résilié. Vos données sont conservées.'
    else 'Votre abonnement Nuittea Manager ne sera pas renouvelé ; il reste actif jusqu''à son échéance.' end, 'warning');
end $$;

-- ===== Compte (accès « Support ») =====
create or replace function public.admin_org_features(p_org uuid, p_add text[], p_remove text[], p_rooms int, p_users int, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare v_before jsonb;
begin
  if not public.staff_can('support') then raise exception 'Accès refusé.'; end if;
  select admin_overrides into v_before from public.organizations where id = p_org;
  if not found then raise exception 'Client introuvable.'; end if;
  update public.organizations set admin_overrides = jsonb_strip_nulls(jsonb_build_object(
      'features_add', to_jsonb(coalesce(p_add, '{}')), 'features_remove', to_jsonb(coalesce(p_remove, '{}')),
      'max_rooms', p_rooms, 'max_users', p_users)) where id = p_org;
  perform public._staff_log('derogations_modifiees', 'organization', p_org::text, jsonb_build_object('avant', v_before, 'apres', (select admin_overrides from public.organizations where id = p_org), 'motif', p_reason));
  if coalesce(cardinality(p_add), 0) > 0 then
    perform public._notify_org(p_org, 'Nuittea a activé pour vous des fonctions supplémentaires. Actualisez l''application pour les voir.');
  end if;
end $$;

create or replace function public.admin_org_commission(p_org uuid, p_pct numeric, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 50 then raise exception 'Commission entre 0 et 50 %%.'; end if;
  update public.marketplace_listings set commission_pct = p_pct, updated_at = now() where organization_id = p_org;
  if not found then raise exception 'Ce client n''est pas encore inscrit sur Nuittea.com.'; end if;
  perform public._staff_log('commission_modifiee', 'organization', p_org::text, jsonb_build_object('taux', p_pct, 'motif', p_reason));
  perform public._notify_org(p_org, format('Votre commission Nuittea.com est désormais de %s %% pour les prochaines réservations.', p_pct));
end $$;

create or replace function public.admin_member_set(p_member uuid, p_active boolean)
returns void language plpgsql security definer set search_path to '' as $$
declare m public.organization_members;
begin
  if not public.staff_can('support') then raise exception 'Accès refusé.'; end if;
  select * into m from public.organization_members where id = p_member;
  if m.id is null then raise exception 'Compte introuvable.'; end if;
  if m.role in ('owner', 'admin') then raise exception 'Les comptes propriétaire et administrateur se gèrent par le propriétaire de l''hôtel.'; end if;
  update public.organization_members set is_active = p_active where id = p_member;
  perform public._staff_log(case when p_active then 'employe_reactive' else 'employe_desactive' end, 'organization', m.organization_id::text, jsonb_build_object('employe', coalesce(m.display_name, m.username), 'role', m.role));
end $$;

create or replace function public.admin_org_set_test(p_org uuid, p_test boolean)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('settings') then raise exception 'Accès refusé.'; end if;
  update public.organizations set is_test = p_test where id = p_org;
  perform public._staff_log(case when p_test then 'compte_marque_test' else 'compte_marque_reel' end, 'organization', p_org::text, '{}');
end $$;

create or replace function public.admin_org_detail(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.staff_can('clients') then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object(
    'overrides', (select admin_overrides from public.organizations where id = p_org),
    'plan_features', (select p.features from public.subscriptions s join public.plans p on p.id = s.plan_id where s.organization_id = p_org),
    'plan_limits', (select jsonb_build_object('rooms', p.max_rooms, 'users', p.max_users) from public.subscriptions s join public.plans p on p.id = s.plan_id where s.organization_id = p_org),
    'suspended_reason', (select suspended_reason from public.subscriptions where organization_id = p_org),
    'commission', (select max(commission_pct) from public.marketplace_listings where organization_id = p_org),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', coalesce(m.display_name, m.username, u.email), 'role', m.role, 'active', m.is_active, 'last', u.last_sign_in_at) order by m.role, m.display_name)
       from public.organization_members m left join auth.users u on u.id = m.user_id where m.organization_id = p_org), '[]'),
    'payments', coalesce((select jsonb_agg(z) from (select jsonb_build_object('amount', y.amount, 'status', y.status, 'method', y.payment_method, 'cycle', y.billing_cycle, 'at', coalesce(y.paid_at, y.created_at), 'ref', y.transaction_reference) z
       from public.payments y where y.organization_id = p_org order by y.created_at desc limit 12) q), '[]'));
end $$;

revoke all on function public.admin_sub_set(uuid, text, text, timestamptz, text), public.admin_sub_extend(uuid, int, text), public.admin_payment_record(uuid, int, text, text, text),
  public.admin_org_suspend(uuid, boolean, text), public.admin_sub_cancel(uuid, boolean, text), public.admin_org_features(uuid, text[], text[], int, int, text),
  public.admin_org_commission(uuid, numeric, text), public.admin_member_set(uuid, boolean), public.admin_org_set_test(uuid, boolean), public.admin_org_detail(uuid) from public, anon;
grant execute on function public.admin_sub_set(uuid, text, text, timestamptz, text), public.admin_sub_extend(uuid, int, text), public.admin_payment_record(uuid, int, text, text, text),
  public.admin_org_suspend(uuid, boolean, text), public.admin_sub_cancel(uuid, boolean, text), public.admin_org_features(uuid, text[], text[], int, int, text),
  public.admin_org_commission(uuid, numeric, text), public.admin_member_set(uuid, boolean), public.admin_org_set_test(uuid, boolean), public.admin_org_detail(uuid) to authenticated;

-- Dérogations visibles par l'hôtel (affichage des menus dans Nuittea Manager)
create or replace function public.my_overrides(p_org uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select case when public.is_org_member(p_org) then (select admin_overrides from public.organizations where id = p_org) end;
$$;
revoke all on function public.my_overrides(uuid) from public, anon;
grant execute on function public.my_overrides(uuid) to authenticated;

-- ===== Alertes e-mail =====
alter table public.platform_staff add column if not exists alert_instant boolean not null default true;
alter table public.platform_staff add column if not exists alert_weekly boolean not null default true;

create table if not exists public.email_outbox (
  id bigint generated always as identity primary key,
  perm text not null, subject text not null, body text not null,
  created_at timestamptz not null default now(), sent_at timestamptz, error text
);
alter table public.email_outbox enable row level security;
create table if not exists public.email_keys (key text primary key, hook_secret text not null);
alter table public.email_keys enable row level security;
insert into public.email_keys (key, hook_secret) values ('alerts', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (key) do nothing;

create or replace function public.my_alert_prefs(p_instant boolean, p_weekly boolean)
returns void language sql security definer set search_path to '' as $$
  update public.platform_staff set alert_instant = p_instant, alert_weekly = p_weekly where user_id = auth.uid();
$$;
revoke all on function public.my_alert_prefs(boolean, boolean) from public, anon;
grant execute on function public.my_alert_prefs(boolean, boolean) to authenticated;

create or replace function public._alert(p_perm text, p_subject text, p_body text) returns void language sql security definer set search_path to '' as $$
  insert into public.email_outbox (perm, subject, body) values (p_perm, p_subject, p_body);
$$;
revoke all on function public._alert(text, text, text) from public, anon, authenticated;

create or replace function public._trg_alert_ticket() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.priority in ('haute', 'urgente') then
    perform public._alert('support', 'Demande d''assistance ' || new.priority || ' : ' || new.subject,
      'Hôtel : ' || coalesce((select name from public.organizations where id = new.organization_id), '') || E'\nObjet : ' || new.subject);
  end if;
  return new;
end $$;
drop trigger if exists trg_alert_ticket on public.support_tickets;
create trigger trg_alert_ticket after insert on public.support_tickets for each row execute function public._trg_alert_ticket();

create or replace function public._trg_alert_report() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  perform public._alert('moderation', 'Signalement Nuittea.com : ' || coalesce((select coalesce(public_name, name) from public.establishments where id = new.establishment_id), ''),
    'Motif : ' || new.reason || coalesce(E'\nMessage : ' || new.message, '') || coalesce(E'\nContact : ' || new.contact, ''));
  return new;
end $$;
drop trigger if exists trg_alert_report on public.nuittea_reports;
create trigger trg_alert_report after insert on public.nuittea_reports for each row execute function public._trg_alert_report();

create or replace function public._trg_alert_listing() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.listed and new.review_status = 'a_verifier' and (tg_op = 'INSERT' or not old.listed or old.review_status <> 'a_verifier') then
    perform public._alert('moderation', 'Nouvelle fiche à vérifier : ' || coalesce((select coalesce(public_name, name) from public.establishments where id = new.establishment_id), ''),
      'Un établissement vient de se publier sur Nuittea.com. Vérifiez sa fiche dans la console (Publications).');
  end if;
  return new;
end $$;
drop trigger if exists trg_alert_listing on public.marketplace_listings;
create trigger trg_alert_listing after insert or update on public.marketplace_listings for each row execute function public._trg_alert_listing();

create or replace function public._trg_alert_payment() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed') then
    perform public._alert('finance', 'Paiement d''abonnement en échec : ' || coalesce((select name from public.organizations where id = new.organization_id), ''),
      'Montant : ' || new.amount || ' F' || coalesce(E'\nMotif : ' || new.failure_reason, ''));
  end if;
  return new;
end $$;
drop trigger if exists trg_alert_payment on public.payments;
create trigger trg_alert_payment after insert or update on public.payments for each row execute function public._trg_alert_payment();

-- Contenu du point hebdomadaire (lu par la fonction serveur « alerts »)
create or replace function public.alerts_weekly_digest() returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.is_service_context() then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object(
    'naya_resas', (select count(*) from public.reservations where source = 'naya' and created_at > now() - interval '7 days'),
    'paid', (select coalesce(sum(amount), 0) from public.payments where status = 'succeeded' and paid_at > now() - interval '7 days'),
    'new_orgs', (select count(*) from public.organizations where not is_test and created_at > now() - interval '7 days'),
    'expiring', coalesce((select jsonb_agg(o.name || ' (' || to_char(coalesce(s.current_period_end, s.trial_end_at), 'DD/MM') || ')') from public.subscriptions s join public.organizations o on o.id = s.organization_id
       where not o.is_test and ((s.status = 'active' and s.current_period_end between now() and now() + interval '7 days') or (s.status = 'trial' and s.trial_end_at between now() and now() + interval '7 days'))), '[]'),
    'expired', coalesce((select jsonb_agg(o.name) from public.subscriptions s join public.organizations o on o.id = s.organization_id where not o.is_test and public.effective_subscription_status(o.id) = 'expired' and s.updated_at > now() - interval '30 days'), '[]'),
    'inactive', coalesce((select jsonb_agg(o.name) from public.organizations o where not o.is_test and public.effective_subscription_status(o.id) in ('active', 'trial')
       and coalesce((select max(u.last_sign_in_at) from public.organization_members m join auth.users u on u.id = m.user_id where m.organization_id = o.id), 'epoch') < now() - interval '10 days'), '[]'),
    'reports', (select count(*) from public.nuittea_reports where status = 'nouveau'),
    'tickets', (select count(*) from public.support_tickets where status in ('ouvert', 'en_cours', 'attente_client')),
    'to_review', (select count(*) from public.marketplace_listings where listed and review_status = 'a_verifier'),
    'tasks_open', (select count(*) from public.crm_tasks where done_at is null and due_date <= current_date + 7));
end $$;
revoke all on function public.alerts_weekly_digest() from public, anon, authenticated;

create or replace function public.alerts_ping(p_action text default 'flush') returns void language plpgsql security definer set search_path to '' as $$
declare v_secret text;
begin
  if p_action = 'flush' and not exists (select 1 from public.email_outbox where sent_at is null and error is null) then return; end if;
  select hook_secret into v_secret from public.email_keys where key = 'alerts';
  perform net.http_post(url := 'https://kuuyhtvdnoqyikrcbpot.supabase.co/functions/v1/alerts',
    body := jsonb_build_object('action', p_action),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-alerts-secret', v_secret), timeout_milliseconds := 10000);
end $$;
revoke all on function public.alerts_ping(text) from public, anon, authenticated;

select cron.schedule('alerts-flush', '* * * * *', 'select public.alerts_ping(''flush'')');
-- Lundi 7 h (Abidjan = UTC)
select cron.schedule('alerts-weekly', '0 7 * * 1', 'select public.alerts_ping(''weekly'')');
