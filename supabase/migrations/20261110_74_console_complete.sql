-- 74 · Console Nuittea complète : CRM, support, annonces, signalements, contrôle des publications,
-- modération des avis, encaissement des commissions, vue client, démonstration, sécurité.
-- Uniquement des ajouts. Seule donnée existante touchée : marketplace_listings.review_status = 'valide'
-- pour les fiches déjà publiées (elles restent en ligne).

-- ===== Réglages de la console =====
insert into public.platform_settings (key, value) values ('nuittea_review_required', 'false'), ('staff_mfa_required', 'false')
on conflict (key) do nothing;

create or replace function public._setting(p_key text) returns text language sql stable security definer set search_path to '' as $$
  select value from public.platform_settings where key = p_key;
$$;

-- Validation en deux étapes : si exigée, les accès de l'équipe demandent une session à deux facteurs
create or replace function public.staff_can(p_perm text)
returns boolean language sql stable security definer set search_path to '' as $$
  select p_perm = any(public.platform_perms(auth.uid()))
     and (coalesce(public._setting('staff_mfa_required'), 'false') <> 'true' or coalesce(auth.jwt()->>'aal', 'aal1') = 'aal2');
$$;

create or replace function public.admin_setting_set(p_key text, p_value text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('settings') then raise exception 'Accès refusé.'; end if;
  if p_key not in ('nuittea_review_required', 'staff_mfa_required', 'naya_payment_instructions', 'naya_payment_delay_days') then raise exception 'Réglage inconnu.'; end if;
  if p_key = 'staff_mfa_required' and p_value = 'true' and coalesce(auth.jwt()->>'aal', 'aal1') <> 'aal2' then
    raise exception 'Activez d''abord la validation en deux étapes sur votre propre compte.'; end if;
  insert into public.platform_settings (key, value, updated_at) values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  perform public._staff_log('reglage_modifie', 'setting', p_key, jsonb_build_object('valeur', p_value));
end $$;

-- ===== Contrôle des publications =====
alter table public.marketplace_listings add column if not exists review_status text not null default 'a_verifier'
  check (review_status in ('a_verifier', 'valide', 'refuse'));
alter table public.marketplace_listings add column if not exists review_note text;
alter table public.marketplace_listings add column if not exists reviewed_at timestamptz;
alter table public.marketplace_listings add column if not exists reviewed_by uuid;
update public.marketplace_listings set review_status = 'valide', reviewed_at = now() where review_status = 'a_verifier';

create or replace function public._review_ok(p_status text) returns boolean language sql stable security definer set search_path to '' as $$
  select case when p_status = 'refuse' then false
              when coalesce(public._setting('nuittea_review_required'), 'false') = 'true' then p_status = 'valide'
              else true end;
$$;

alter table public.reviews add column if not exists nuittea_reply text check (nuittea_reply is null or length(nuittea_reply) <= 1000);
alter table public.reviews add column if not exists moderated_at timestamptz;
alter table public.reviews add column if not exists moderation_reason text;

-- Une fiche refusée qui est republiée repasse « à vérifier »
create or replace function public._listing_review_reset() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.listed and (tg_op = 'INSERT' or not old.listed) and new.review_status = 'refuse' then new.review_status := 'a_verifier'; end if;
  return new;
end $$;
drop trigger if exists trg_listing_review on public.marketplace_listings;
create trigger trg_listing_review before insert or update on public.marketplace_listings for each row execute function public._listing_review_reset();

create or replace function public.admin_listing_review(p_est uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('moderation') then raise exception 'Accès refusé.'; end if;
  if p_status not in ('valide', 'refuse', 'a_verifier') then raise exception 'Statut invalide.'; end if;
  if p_status = 'refuse' and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Indiquez ce que l''hôtel doit corriger.'; end if;
  update public.marketplace_listings set review_status = p_status, review_note = p_note, reviewed_at = now(), reviewed_by = auth.uid() where establishment_id = p_est;
  if not found then raise exception 'Fiche introuvable.'; end if;
  perform public._staff_log('fiche_' || p_status, 'establishment', p_est::text, jsonb_build_object('motif', p_note));
end $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public._market_est'::regproc);
  execute replace(d, 'm.listed and', 'm.listed and public._review_ok(m.review_status) and');
  d := pg_get_functiondef('public.market_search'::regproc);
  execute replace(d, 'where m.listed and', 'where m.listed and public._review_ok(m.review_status) and');
  d := pg_get_functiondef('public.market_location'::regproc);
  execute replace(d, 'where e.slug = p_slug and m.listed', 'where e.slug = p_slug and m.listed and public._review_ok(m.review_status)');
  d := pg_get_functiondef('public.market_establishment'::regproc);
  execute replace(d, '''comment'', v.comment, ''date''', '''comment'', v.comment, ''nuittea_reply'', v.nuittea_reply, ''date''');
end $$;

-- ===== Avis clients =====

create or replace function public.admin_review_moderate(p_review uuid, p_published boolean, p_reason text default null, p_reply text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('moderation') then raise exception 'Accès refusé.'; end if;
  if not p_published and length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Indiquez un motif.'; end if;
  update public.reviews set is_published = p_published, moderated_at = now(), moderation_reason = case when p_published then null else p_reason end,
    nuittea_reply = coalesce(nullif(trim(p_reply), ''), nuittea_reply) where id = p_review;
  if not found then raise exception 'Avis introuvable.'; end if;
  perform public._staff_log(case when p_published then 'avis_publie' else 'avis_masque' end, 'review', p_review::text, jsonb_build_object('motif', p_reason, 'reponse', p_reply));
end $$;

-- ===== Signalements des voyageurs =====
create table if not exists public.nuittea_reports (
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  reason text not null check (reason in ('photos', 'prix', 'injoignable', 'adresse', 'comportement', 'autre')),
  message text check (message is null or length(message) <= 1000),
  contact text check (contact is null or length(contact) <= 160),
  status text not null default 'nouveau' check (status in ('nouveau', 'traite', 'rejete')),
  handled_by uuid, handled_at timestamptz, created_at timestamptz not null default now()
);
alter table public.nuittea_reports enable row level security;
create policy nrep_select on public.nuittea_reports for select using ((select public.staff_can('moderation')));

create or replace function public.public_report_listing(p_slug text, p_reason text, p_message text default null, p_contact text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_est uuid;
begin
  if public._rate_hit('report:ip:' || public._client_ip(), 5, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'Trop de signalements. Réessayez plus tard.'); end if;
  select id into v_est from public.establishments where slug = lower(trim(coalesce(p_slug, '')));
  if v_est is null then return jsonb_build_object('ok', false, 'error', 'Établissement introuvable.'); end if;
  if p_reason not in ('photos', 'prix', 'injoignable', 'adresse', 'comportement', 'autre') then return jsonb_build_object('ok', false, 'error', 'Motif invalide.'); end if;
  insert into public.nuittea_reports (establishment_id, reason, message, contact) values (v_est, p_reason, left(nullif(trim(p_message), ''), 1000), left(nullif(trim(p_contact), ''), 160));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.public_report_listing(text, text, text, text) to anon, authenticated;

create or replace function public.admin_report_handle(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('moderation') then raise exception 'Accès refusé.'; end if;
  update public.nuittea_reports set status = p_status, handled_by = auth.uid(), handled_at = now() where id = p_id;
  perform public._staff_log('signalement_' || p_status, 'report', p_id::text, '{}');
end $$;

-- ===== CRM =====
create table if not exists public.crm_prospects (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 160),
  contact_name text, phone text, email text, city text, rooms int,
  stage text not null default 'a_contacter' check (stage in ('a_contacter', 'contacte', 'demo', 'essai', 'abonne', 'perdu')),
  source text, owner uuid, next_action_at date, organization_id uuid references public.organizations(id) on delete set null,
  lost_reason text, created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.crm_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  prospect_id uuid references public.crm_prospects(id) on delete cascade,
  kind text not null default 'note' check (kind in ('note', 'appel', 'whatsapp', 'email', 'visite', 'demo')),
  body text not null check (length(body) between 1 and 4000),
  author uuid default auth.uid(), at timestamptz not null default now(),
  check (organization_id is not null or prospect_id is not null)
);
create table if not exists public.crm_tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 2 and 200),
  due_date date, done_at timestamptz, assignee uuid default auth.uid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  prospect_id uuid references public.crm_prospects(id) on delete cascade,
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table public.crm_prospects enable row level security;
alter table public.crm_notes enable row level security;
alter table public.crm_tasks enable row level security;
create policy crmp_all on public.crm_prospects for all using ((select public.staff_can('crm'))) with check ((select public.staff_can('crm')));
create policy crmn_select on public.crm_notes for select using ((select public.staff_can('crm')) or (select public.staff_can('clients')));
create policy crmn_insert on public.crm_notes for insert with check (((select public.staff_can('crm')) or (select public.staff_can('clients'))) and author = auth.uid());
create policy crmt_all on public.crm_tasks for all using ((select public.staff_can('crm')) or assignee = auth.uid() and (select public.staff_can('dashboard')))
  with check ((select public.staff_can('crm')) or assignee = auth.uid() and (select public.staff_can('dashboard')));
create index if not exists crm_notes_org_idx on public.crm_notes (organization_id, at desc);
create index if not exists crm_notes_pros_idx on public.crm_notes (prospect_id, at desc);

-- ===== Support =====
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid references public.establishments(id) on delete set null,
  created_by uuid default auth.uid(),
  subject text not null check (length(trim(subject)) between 3 and 160),
  category text not null default 'question' check (category in ('question', 'probleme', 'facturation', 'nuittea', 'suggestion')),
  status text not null default 'ouvert' check (status in ('ouvert', 'en_cours', 'attente_client', 'resolu', 'ferme')),
  priority text not null default 'normale' check (priority in ('basse', 'normale', 'haute', 'urgente')),
  assignee uuid, first_response_at timestamptz, resolved_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  author uuid default auth.uid(), from_staff boolean not null default false,
  body text not null check (length(body) between 1 and 4000), at timestamptz not null default now()
);
alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
create policy st_select on public.support_tickets for select using ((select public.is_org_member(organization_id)) or (select public.staff_can('support')));
create policy sm_select on public.support_messages for select using (exists (select 1 from public.support_tickets t where t.id = ticket_id
  and ((select public.is_org_member(t.organization_id)) or (select public.staff_can('support')))));
create index if not exists support_messages_t_idx on public.support_messages (ticket_id, at);

create or replace function public.support_ticket_create(p_org uuid, p_est uuid, p_subject text, p_category text, p_body text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid;
begin
  if not public.is_org_member(p_org) then raise exception 'Accès refusé.'; end if;
  if length(trim(coalesce(p_body, ''))) < 3 then raise exception 'Décrivez votre demande.'; end if;
  insert into public.support_tickets (organization_id, establishment_id, subject, category, priority)
  values (p_org, p_est, trim(p_subject), coalesce(p_category, 'question'), case when p_category = 'probleme' then 'haute' else 'normale' end) returning id into v;
  insert into public.support_messages (ticket_id, body) values (v, trim(p_body));
  return v;
end $$;

create or replace function public.support_message_add(p_ticket uuid, p_body text)
returns void language plpgsql security definer set search_path to '' as $$
declare t public.support_tickets; v_staff boolean;
begin
  select * into t from public.support_tickets where id = p_ticket;
  if t.id is null then raise exception 'Demande introuvable.'; end if;
  v_staff := public.staff_can('support');
  if not (v_staff or public.is_org_member(t.organization_id)) then raise exception 'Accès refusé.'; end if;
  insert into public.support_messages (ticket_id, body, from_staff) values (p_ticket, trim(p_body), v_staff and not public.is_org_member(t.organization_id));
  update public.support_tickets set updated_at = now(),
    first_response_at = case when v_staff then coalesce(first_response_at, now()) else first_response_at end,
    status = case when v_staff and status = 'ouvert' then 'en_cours' when not v_staff and status in ('attente_client', 'resolu') then 'en_cours' else status end
   where id = p_ticket;
end $$;

create or replace function public.admin_ticket_update(p_ticket uuid, p_status text, p_priority text, p_assignee uuid)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('support') then raise exception 'Accès refusé.'; end if;
  update public.support_tickets set status = coalesce(p_status, status), priority = coalesce(p_priority, priority), assignee = p_assignee, updated_at = now(),
    resolved_at = case when p_status in ('resolu', 'ferme') then coalesce(resolved_at, now()) else null end where id = p_ticket;
  perform public._staff_log('ticket_modifie', 'ticket', p_ticket::text, jsonb_build_object('statut', p_status, 'priorite', p_priority));
end $$;

-- ===== Annonces aux hôtels =====
create table if not exists public.platform_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 3 and 120),
  body text not null check (length(body) between 3 and 2000),
  level text not null default 'info' check (level in ('info', 'important', 'maintenance')),
  plans text[] not null default '{}',
  starts_at timestamptz not null default now(), ends_at timestamptz,
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table public.platform_announcements enable row level security;
create policy pann_staff on public.platform_announcements for select using ((select public.staff_can('dashboard')));

create or replace function public.my_announcements(p_org uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'body', a.body, 'level', a.level, 'at', a.starts_at) order by a.starts_at desc), '[]')
  from public.platform_announcements a
  where public.is_org_member(p_org) and a.starts_at <= now() and (a.ends_at is null or a.ends_at > now())
    and (cardinality(a.plans) = 0 or exists (select 1 from public.subscriptions s join public.plans p on p.id = s.plan_id
         where s.organization_id = p_org and s.status in ('active', 'trial') and p.slug = any(a.plans)));
$$;

create or replace function public.admin_announcement_save(p_id uuid, p_title text, p_body text, p_level text, p_plans text[], p_starts timestamptz, p_ends timestamptz)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := p_id;
begin
  if not public.staff_can('support') then raise exception 'Accès refusé.'; end if;
  if v is null then
    insert into public.platform_announcements (title, body, level, plans, starts_at, ends_at)
    values (trim(p_title), trim(p_body), coalesce(p_level, 'info'), coalesce(p_plans, '{}'), coalesce(p_starts, now()), p_ends) returning id into v;
  else
    update public.platform_announcements set title = trim(p_title), body = trim(p_body), level = coalesce(p_level, 'info'), plans = coalesce(p_plans, '{}'),
      starts_at = coalesce(p_starts, starts_at), ends_at = p_ends where id = v;
  end if;
  perform public._staff_log('annonce_enregistree', 'announcement', v::text, jsonb_build_object('titre', p_title));
  return v;
end $$;

-- ===== Commissions : enregistrer un encaissement =====
create or replace function public.admin_commission_pay(p_org uuid, p_amount numeric, p_method text, p_reference text, p_note text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.staff_can('finance') then raise exception 'Accès refusé.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Indiquez un montant.'; end if;
  insert into public.naya_commission_payments (organization_id, amount, method, reference, note, paid_at, recorded_by)
  values (p_org, p_amount, coalesce(p_method, 'mobile_money'), p_reference, p_note, now(), auth.uid());
  perform public._staff_log('commission_encaissee', 'organization', p_org::text, jsonb_build_object('montant', p_amount, 'moyen', p_method, 'reference', p_reference));
end $$;

-- ===== Vue client (lecture seule, tracée) =====
create or replace function public.admin_org_view(p_org uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare r jsonb;
begin
  if not public.staff_can('impersonate') then raise exception 'Accès refusé.'; end if;
  perform public._staff_log('vue_client', 'organization', p_org::text, '{}');
  select jsonb_build_object(
    'org', (select jsonb_build_object('name', o.name, 'created_at', o.created_at, 'is_test', o.is_test) from public.organizations o where o.id = p_org),
    'subscription', (select jsonb_build_object('plan', p.name, 'status', s.status, 'cycle', s.billing_cycle, 'end', coalesce(s.current_period_end, s.trial_end_at)) from public.subscriptions s left join public.plans p on p.id = s.plan_id where s.organization_id = p_org order by s.created_at desc limit 1),
    'members', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(m.display_name, u.email, m.username), 'role', m.role, 'active', m.is_active, 'last', u.last_sign_in_at) order by m.role) from public.organization_members m left join auth.users u on u.id = m.user_id where m.organization_id = p_org), '[]'),
    'establishments', coalesce((select jsonb_agg(jsonb_build_object('name', e.name, 'city', e.city,
        'rooms', (select count(*) from public.rooms x where x.establishment_id = e.id and x.is_active),
        'occupied', (select count(*) from public.reservations x where x.establishment_id = e.id and x.status = 'checked_in'),
        'arrivals', (select count(*) from public.reservations x where x.establishment_id = e.id and x.check_in = current_date and x.status in ('pending', 'confirmed')),
        'open_cash', (select count(*) from public.cash_sessions x where x.establishment_id = e.id and x.status = 'open'))) from public.establishments e where e.organization_id = p_org), '[]'),
    'reservations', coalesce((select jsonb_agg(z) from (select jsonb_build_object('guest', x.guest_name, 'in', x.check_in, 'out', x.check_out, 'status', x.status, 'source', x.source, 'total', x.total_amount) z
        from public.reservations x where x.organization_id = p_org order by x.created_at desc limit 15) q), '[]'),
    'month', (select jsonb_build_object('count', count(*), 'revenue', coalesce(sum(total_amount), 0)) from public.reservations x where x.organization_id = p_org and x.check_in >= date_trunc('month', current_date) and x.status not in ('cancelled', 'no_show')),
    'alerts', coalesce((select jsonb_agg(z) from (select jsonb_build_object('at', a.created_at, 'message', a.message, 'severity', a.severity) z from public.owner_alerts a where a.organization_id = p_org order by a.created_at desc limit 10) q), '[]')
  ) into r;
  return r;
end $$;

-- ===== Démonstration : préparation d'une organisation de démonstration (appelée par la fonction serveur demo-access) =====
create or replace function public.demo_seed(p_users jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_org uuid; v_est uuid; v_plan uuid; i int; v_room uuid; v_rooms uuid[] := '{}'; u record; v_g uuid; v_names text[] := array['Awa Koné','Yao Kouassi','Fatou Traoré','Jean Bamba','Mariam Diallo','Serge Kouadio','Aïcha Ouattara','Paul N''Guessan'];
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then raise exception 'Accès refusé.'; end if;
  select id into v_org from public.organizations where is_test and name = 'Hôtel Démo Nuittea';
  if v_org is not null then
    delete from public.cash_movements where organization_id = v_org; delete from public.cash_sessions where organization_id = v_org;
    delete from public.reservations where organization_id = v_org; delete from public.guests where organization_id = v_org;
    delete from public.cash_registers where organization_id = v_org;
    delete from public.rooms where organization_id = v_org; delete from public.marketplace_listings where organization_id = v_org;
    delete from public.organization_members where organization_id = v_org; delete from public.establishments where organization_id = v_org;
  else
    insert into public.organizations (name, is_test) values ('Hôtel Démo Nuittea', true) returning id into v_org;
  end if;
  select id into v_plan from public.plans where slug = 'pro' limit 1;
  update public.subscriptions set plan_id = v_plan, billing_cycle = 'yearly', status = 'active', current_period_start = now(), current_period_end = now() + interval '10 years',
    next_billing_at = null, cancelled_at = null, suspended_reason = null where organization_id = v_org;
  if not found then insert into public.subscriptions (organization_id, plan_id, billing_cycle, status, current_period_start, current_period_end)
    values (v_org, v_plan, 'yearly', 'active', now(), now() + interval '10 years'); end if;
  insert into public.establishments (organization_id, name, city, currency, checkin_time, checkout_time) values (v_org, 'Hôtel Démo Nuittea', 'Abidjan', 'XOF', '14:00', '12:00') returning id into v_est;
  insert into public.cash_registers (organization_id, establishment_id, name) values (v_org, v_est, 'Réception');
  for i in 1..10 loop
    insert into public.rooms (organization_id, establishment_id, number, room_type, base_rate, capacity, amenities, housekeeping_status)
    values (v_org, v_est, 'CH-' || lpad(i::text, 2, '0'), case when i <= 6 then 'Standard' when i <= 9 then 'Confort' else 'Suite' end,
            case when i <= 6 then 20000 when i <= 9 then 30000 else 55000 end, case when i = 10 then 4 else 2 end, array['wifi','clim','tv','eau_chaude'],
            case when i in (3, 7) then 'dirty' else 'clean' end) returning id into v_room;
    v_rooms := v_rooms || v_room;
  end loop;
  for u in select * from jsonb_to_recordset(p_users) as x(user_id uuid, role text, name text) loop
    insert into public.organization_members (organization_id, user_id, establishment_id, role, display_name, is_active)
    values (v_org, u.user_id, case when u.role = 'owner' then null else v_est end, u.role, u.name, true);
  end loop;
  perform set_config('horus.marketplace', 'on', true);
  for i in 1..8 loop
    insert into public.guests (organization_id, full_name, phone) values (v_org, v_names[i], '+22507000000' || i) returning id into v_g;
    insert into public.reservations (organization_id, establishment_id, room_id, guest_id, guest_name, guest_phone, check_in, check_out, adults, nightly_rate, status, source)
    values (v_org, v_est, v_rooms[i], v_g, v_names[i], '+22507000000' || i,
      current_date + (case when i <= 3 then -1 when i <= 5 then 0 else i - 4 end), current_date + (case when i <= 3 then 2 when i <= 5 then 2 else i - 2 end), 2,
      case when i <= 6 then 20000 else 30000 end, case when i <= 3 then 'checked_in' else 'confirmed' end,
      (array['direct','telephone','whatsapp','naya','walk_in','en_ligne','agence','direct'])[i]);
  end loop;
  perform set_config('horus.marketplace', 'off', true);
  return v_org;
end $$;
revoke all on function public.demo_seed(jsonb) from public, anon, authenticated;

-- ===== Droits d'exécution =====
revoke all on function public.admin_setting_set(text, text), public.admin_listing_review(uuid, text, text), public.admin_review_moderate(uuid, boolean, text, text),
  public.admin_report_handle(uuid, text), public.support_ticket_create(uuid, uuid, text, text, text), public.support_message_add(uuid, text),
  public.admin_ticket_update(uuid, text, text, uuid), public.my_announcements(uuid), public.admin_announcement_save(uuid, text, text, text, text[], timestamptz, timestamptz),
  public.admin_commission_pay(uuid, numeric, text, text, text), public.admin_org_view(uuid) from public, anon;
grant execute on function public.admin_setting_set(text, text), public.admin_listing_review(uuid, text, text), public.admin_review_moderate(uuid, boolean, text, text),
  public.admin_report_handle(uuid, text), public.support_ticket_create(uuid, uuid, text, text, text), public.support_message_add(uuid, text),
  public.admin_ticket_update(uuid, text, text, uuid), public.my_announcements(uuid), public.admin_announcement_save(uuid, text, text, text, text[], timestamptz, timestamptz),
  public.admin_commission_pay(uuid, numeric, text, text, text), public.admin_org_view(uuid) to authenticated;

-- ===== Lecture complète pour la console =====
create or replace function public.admin_console_data()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_delay int := coalesce(nullif(public._setting('naya_payment_delay_days'), '')::int, 7);
begin
  if not public.staff_can('dashboard') then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object(
    'me', jsonb_build_object('id', auth.uid(), 'perms', public.platform_perms(auth.uid()), 'role', (select role from public.platform_staff where user_id = auth.uid()), 'aal', coalesce(auth.jwt()->>'aal', 'aal1')),
    'settings', jsonb_build_object('review_required', public._setting('nuittea_review_required') = 'true', 'mfa_required', public._setting('staff_mfa_required') = 'true'),
    'stats', jsonb_build_object(
      'orgs', (select count(*) from public.organizations where not is_test),
      'ests', (select count(*) from public.establishments e join public.organizations o on o.id = e.organization_id where not o.is_test),
      'listed', (select count(*) from public.marketplace_listings where listed),
      'to_review', (select count(*) from public.marketplace_listings where listed and review_status = 'a_verifier'),
      'suspended', (select count(*) from public.establishments where nuittea_suspended_at is not null),
      'hidden_rooms', (select count(*) from public.rooms where nuittea_hidden),
      'naya_30', (select count(*) from public.reservations where source = 'naya' and created_at > now() - interval '30 days'),
      'mrr', (select coalesce(sum(case when s.billing_cycle = 'yearly' then p.yearly_price / 12.0 else p.monthly_price end), 0)::int
              from public.subscriptions s join public.plans p on p.id = s.plan_id join public.organizations o on o.id = s.organization_id where s.status = 'active' and not o.is_test),
      'active', (select count(*) from public.subscriptions s join public.organizations o on o.id = s.organization_id where s.status = 'active' and not o.is_test),
      'trials', (select count(*) from public.subscriptions s join public.organizations o on o.id = s.organization_id where s.status = 'trial' and not o.is_test),
      'paid_30', (select coalesce(sum(amount), 0) from public.payments where status in ('succeeded', 'paid', 'completed') and paid_at > now() - interval '30 days'),
      'reports', (select count(*) from public.nuittea_reports where status = 'nouveau'),
      'tickets', (select count(*) from public.support_tickets where status in ('ouvert', 'en_cours'))),
    'orgs', case when public.staff_can('clients') then coalesce((select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object('id', o.id, 'name', o.name, 'is_test', o.is_test, 'created_at', o.created_at,
        'plan', p.name, 'plan_slug', p.slug, 'status', s.status, 'cycle', s.billing_cycle, 'end', coalesce(s.current_period_end, s.trial_end_at),
        'price', case when s.billing_cycle = 'yearly' then p.yearly_price else p.monthly_price end,
        'owner_email', (select u.email from public.organization_members m join auth.users u on u.id = m.user_id where m.organization_id = o.id and m.role = 'owner' limit 1),
        'owner_phone', (select e.public_phone from public.establishments e where e.organization_id = o.id and e.public_phone is not null limit 1),
        'last_login', (select max(u.last_sign_in_at) from public.organization_members m join auth.users u on u.id = m.user_id where m.organization_id = o.id),
        'resas_30', (select count(*) from public.reservations r where r.organization_id = o.id and r.created_at > now() - interval '30 days'),
        'rooms', (select count(*) from public.rooms r where r.organization_id = o.id and r.is_active),
        'ests', (select count(*) from public.establishments e where e.organization_id = o.id),
        'commission', (select jsonb_build_object('earned', ce.e, 'paid', cp.p, 'balance', greatest(ce.e - cp.p, 0), 'overdue', greatest(ce.o - cp.p, 0))
           from (select coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)), 0) e,
                        coalesce(sum(round(r.total_amount * coalesce(r.commission_pct, 0) / 100)) filter (where r.check_in < current_date - v_delay), 0) o
                   from public.reservations r where r.organization_id = o.id and r.source = 'naya' and r.status in ('confirmed', 'checked_in', 'checked_out') and r.check_in <= current_date) ce,
                (select coalesce(sum(amount), 0) p from public.naya_commission_payments where organization_id = o.id) cp),
        'online', (select jsonb_build_object('collected', coalesce(sum(coalesce(b.gp_net, b.amount)), 0), 'count', count(*)) from public.booking_payments b where b.organization_id = o.id and b.status = 'succeeded' and b.environment is distinct from 'sandbox'),
        'unpaid', (select count(*) from public.payments y where y.organization_id = o.id and y.status in ('pending', 'failed') and y.created_at > now() - interval '30 days')) x
      from public.organizations o
      left join lateral (select * from public.subscriptions s where s.organization_id = o.id order by s.created_at desc limit 1) s on true
      left join public.plans p on p.id = s.plan_id) z), '[]') end,
    'ests', coalesce((select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object('id', e.id, 'org_id', o.id, 'name', coalesce(e.public_name, e.name), 'city', e.city, 'slug', e.slug, 'org', o.name, 'is_test', o.is_test,
        'listed', coalesce(m.listed, false), 'commission', m.commission_pct, 'review', m.review_status, 'review_note', m.review_note, 'listed_at', m.terms_accepted_at,
        'suspended_at', e.nuittea_suspended_at, 'suspended_reason', e.nuittea_suspended_reason,
        'phone', e.public_phone, 'whatsapp', e.public_whatsapp, 'email', e.public_email, 'cover', e.public_cover_url,
        'has_description', length(coalesce(e.public_description, '')) >= 40, 'photos', jsonb_array_length(coalesce(e.public_photos, '[]')),
        'rooms', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'type', r.room_type, 'rate', r.base_rate, 'active', r.is_active,
            'hidden', r.nuittea_hidden, 'reason', r.nuittea_hidden_reason, 'photo', r.photos->>0, 'photos', jsonb_array_length(r.photos)) order by r.number) from public.rooms r where r.establishment_id = e.id), '[]'),
        'bookings', coalesce((select jsonb_agg(b) from (select jsonb_build_object('ref', v.public_reference, 'guest', v.guest_name, 'phone', v.guest_phone,
            'in', v.check_in, 'out', v.check_out, 'status', v.status) b from public.reservations v where v.establishment_id = e.id and v.source = 'naya' order by v.created_at desc limit 8) z), '[]'),
        'cancel_rate', (select round(100.0 * count(*) filter (where v.status in ('cancelled', 'no_show')) / nullif(count(*), 0)) from public.reservations v where v.establishment_id = e.id and v.source = 'naya' and v.created_at > now() - interval '30 days')) x
      from public.establishments e join public.organizations o on o.id = e.organization_id left join public.marketplace_listings m on m.establishment_id = e.id
      where m.establishment_id is not null or e.nuittea_suspended_at is not null) s), '[]'),
    'reviews', case when public.staff_can('moderation') then coalesce((select jsonb_agg(z) from (select jsonb_build_object('id', v.id, 'est', coalesce(e.public_name, e.name), 'guest', v.guest_name, 'rating', v.rating,
        'comment', v.comment, 'reply', v.reply, 'nuittea_reply', v.nuittea_reply, 'published', v.is_published, 'reason', v.moderation_reason, 'at', v.submitted_at) z
        from public.reviews v join public.establishments e on e.id = v.establishment_id where v.status = 'submitted' order by v.submitted_at desc limit 200) q), '[]') end,
    'reports', case when public.staff_can('moderation') then coalesce((select jsonb_agg(z) from (select jsonb_build_object('id', r.id, 'est_id', r.establishment_id, 'est', coalesce(e.public_name, e.name), 'reason', r.reason,
        'message', r.message, 'contact', r.contact, 'status', r.status, 'at', r.created_at) z from public.nuittea_reports r join public.establishments e on e.id = r.establishment_id order by r.created_at desc limit 200) q), '[]') end,
    'prospects', case when public.staff_can('crm') then coalesce((select jsonb_agg(to_jsonb(p) order by p.updated_at desc) from public.crm_prospects p), '[]') end,
    'notes', case when public.staff_can('crm') or public.staff_can('clients') then coalesce((select jsonb_agg(z) from (select jsonb_build_object('id', n.id, 'org', n.organization_id, 'prospect', n.prospect_id, 'kind', n.kind, 'body', n.body, 'at', n.at,
        'author', coalesce(s.display_name, s.email)) z from public.crm_notes n left join public.platform_staff s on s.user_id = n.author order by n.at desc limit 500) q), '[]') end,
    'tasks', coalesce((select jsonb_agg(z) from (select jsonb_build_object('id', t.id, 'title', t.title, 'due', t.due_date, 'done', t.done_at, 'assignee', t.assignee, 'org', t.organization_id, 'prospect', t.prospect_id,
        'assignee_name', coalesce(s.display_name, s.email)) z from public.crm_tasks t left join public.platform_staff s on s.user_id = t.assignee
        where public.staff_can('crm') or t.assignee = auth.uid() order by t.done_at nulls first, t.due_date nulls last limit 300) q), '[]'),
    'tickets', case when public.staff_can('support') then coalesce((select jsonb_agg(z) from (select jsonb_build_object('id', t.id, 'number', t.number, 'org_id', t.organization_id, 'org', o.name, 'subject', t.subject,
        'category', t.category, 'status', t.status, 'priority', t.priority, 'assignee', t.assignee, 'created_at', t.created_at, 'updated_at', t.updated_at, 'first_response_at', t.first_response_at,
        'author', (select coalesce(m.display_name, u.email) from auth.users u left join public.organization_members m on m.user_id = u.id and m.organization_id = t.organization_id where u.id = t.created_by limit 1),
        'messages', coalesce((select jsonb_agg(jsonb_build_object('body', sm.body, 'staff', sm.from_staff, 'at', sm.at) order by sm.at) from public.support_messages sm where sm.ticket_id = t.id), '[]')) z
        from public.support_tickets t join public.organizations o on o.id = t.organization_id order by (t.status in ('resolu', 'ferme')), t.updated_at desc limit 200) q), '[]') end,
    'announcements', coalesce((select jsonb_agg(to_jsonb(a) order by a.starts_at desc) from public.platform_announcements a), '[]'),
    'plans', coalesce((select jsonb_agg(jsonb_build_object('slug', slug, 'name', name) order by sort_order) from public.plans where is_active and not is_trial), '[]'),
    'staff', case when public.staff_can('team') or public.staff_can('crm') or public.staff_can('support') then coalesce((select jsonb_agg(jsonb_build_object('user_id', user_id, 'email', email, 'name', display_name, 'role', role,
        'active', is_active, 'overrides', overrides, 'perms', public.platform_perms(user_id)) order by created_at) from public.platform_staff), '[]') end,
    'demo', case when public.staff_can('demo') then (select jsonb_build_object('org_id', o.id, 'members', coalesce((select jsonb_agg(jsonb_build_object('role', m.role, 'name', m.display_name)) from public.organization_members m where m.organization_id = o.id), '[]'),
        'resas', (select count(*) from public.reservations r where r.organization_id = o.id)) from public.organizations o where o.is_test and o.name = 'Hôtel Démo Nuittea') end,
    'journal', case when public.staff_can('journal') then coalesce((select jsonb_agg(j) from (select jsonb_build_object('at', a.at, 'actor', coalesce(s.display_name, s.email), 'action', a.action,
        'type', a.target_type, 'id', a.target_id, 'detail', a.detail) j from public.platform_audit a left join public.platform_staff s on s.user_id = a.actor order by a.at desc limit 300) q), '[]') end);
end $$;
revoke all on function public.admin_console_data() from public, anon;
grant execute on function public.admin_console_data() to authenticated;

-- CRM : enregistrement des prospects, notes et tâches
create or replace function public.crm_prospect_save(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id', '')::uuid;
begin
  if not public.staff_can('crm') then raise exception 'Accès refusé.'; end if;
  if v is null then
    insert into public.crm_prospects (name, contact_name, phone, email, city, rooms, stage, source, owner, next_action_at, lost_reason)
    values (p->>'name', p->>'contact_name', p->>'phone', p->>'email', p->>'city', nullif(p->>'rooms', '')::int, coalesce(nullif(p->>'stage', ''), 'a_contacter'), p->>'source',
            coalesce(nullif(p->>'owner', '')::uuid, auth.uid()), nullif(p->>'next_action_at', '')::date, p->>'lost_reason') returning id into v;
  else
    update public.crm_prospects set name = p->>'name', contact_name = p->>'contact_name', phone = p->>'phone', email = p->>'email', city = p->>'city', rooms = nullif(p->>'rooms', '')::int,
      stage = coalesce(nullif(p->>'stage', ''), stage), source = p->>'source', owner = nullif(p->>'owner', '')::uuid, next_action_at = nullif(p->>'next_action_at', '')::date,
      lost_reason = p->>'lost_reason', organization_id = coalesce(nullif(p->>'organization_id', '')::uuid, organization_id), updated_at = now() where id = v;
  end if;
  return v;
end $$;
create or replace function public.crm_task_save(p_id uuid, p_title text, p_due date, p_assignee uuid, p_org uuid, p_prospect uuid, p_done boolean)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := p_id;
begin
  if not (public.staff_can('crm') or (p_id is not null and exists (select 1 from public.crm_tasks where id = p_id and assignee = auth.uid()) and public.staff_can('dashboard'))) then raise exception 'Accès refusé.'; end if;
  if v is null then
    insert into public.crm_tasks (title, due_date, assignee, organization_id, prospect_id) values (p_title, p_due, coalesce(p_assignee, auth.uid()), p_org, p_prospect) returning id into v;
  else
    update public.crm_tasks set title = coalesce(p_title, title), due_date = p_due, assignee = coalesce(p_assignee, assignee),
      done_at = case when p_done then coalesce(done_at, now()) else null end where id = v;
  end if;
  return v;
end $$;
revoke all on function public.crm_prospect_save(jsonb), public.crm_task_save(uuid, text, date, uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.crm_prospect_save(jsonb), public.crm_task_save(uuid, text, date, uuid, uuid, uuid, boolean) to authenticated;

-- Support côté hôtel : mes demandes
create or replace function public.my_tickets(p_org uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'number', t.number, 'subject', t.subject, 'category', t.category, 'status', t.status, 'updated_at', t.updated_at,
    'messages', coalesce((select jsonb_agg(jsonb_build_object('body', m.body, 'staff', m.from_staff, 'at', m.at) order by m.at) from public.support_messages m where m.ticket_id = t.id), '[]')) order by t.updated_at desc), '[]')
  from public.support_tickets t where t.organization_id = p_org and public.is_org_member(p_org);
$$;
revoke all on function public.my_tickets(uuid) from public, anon;
grant execute on function public.my_tickets(uuid) to authenticated;
