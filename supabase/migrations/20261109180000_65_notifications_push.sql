-- 65 · Notifications push (Web Push) : appareils abonnés, file d'envoi, déclencheurs métier, rappel du soir.
-- Ajouts uniquement. Les déclencheurs n'échouent jamais : une erreur d'envoi n'empêche aucune opération métier.

create extension if not exists pg_net;

-- Appareils abonnés (chaque utilisateur gère les siens)
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  prefs jsonb not null default '{"booking":true,"payment":true,"control":true,"stock":true,"cancel":true,"daily":true}'::jsonb,
  user_agent text,
  failures integer not null default 0,
  created_at timestamptz not null default now(),
  last_sent_at timestamptz
);
create index if not exists push_subscriptions_org_idx on public.push_subscriptions (organization_id);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
create policy push_sub_own on public.push_subscriptions for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and public.is_org_member(organization_id));
revoke all on public.push_subscriptions from anon;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

-- File d'envoi (lue et vidée par la fonction serveur « push »)
create table if not exists public.push_outbox (
  id bigserial primary key,
  organization_id uuid not null,
  establishment_id uuid,
  kind text not null check (kind in ('booking','payment','control','stock','cancel','daily','test')),
  title text not null,
  body text not null,
  url text,
  roles text[] not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  sent_count integer
);
create index if not exists push_outbox_pending_idx on public.push_outbox (id) where sent_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from public, anon, authenticated;
grant all on public.push_outbox to service_role;
grant usage, select on sequence public.push_outbox_id_seq to service_role;

-- Clés d'envoi et secret d'appel interne : lus uniquement par le serveur
create table if not exists public.push_keys (
  key text primary key,
  public_key text,
  private_key text,
  hook_secret text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  created_at timestamptz not null default now()
);
alter table public.push_keys enable row level security;
revoke all on public.push_keys from public, anon, authenticated;
grant all on public.push_keys to service_role;
insert into public.push_keys (key) values ('vapid') on conflict (key) do nothing;

-- Ajoute une notification à la file et réveille la fonction d'envoi (sans jamais bloquer l'opération appelante)
create or replace function public._push(p_org uuid, p_est uuid, p_kind text, p_title text, p_body text, p_url text, p_roles text[])
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_secret text;
begin
  insert into public.push_outbox (organization_id, establishment_id, kind, title, body, url, roles)
  values (p_org, p_est, p_kind, left(p_title, 120), left(p_body, 240), p_url, p_roles);
  begin
    select hook_secret into v_secret from public.push_keys where key = 'vapid';
    perform net.http_post(
      url := 'https://kuuyhtvdnoqyikrcbpot.supabase.co/functions/v1/push',
      body := jsonb_build_object('action', 'flush'),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
      timeout_milliseconds := 5000);
  exception when others then null; -- l'envoi sera repris par la tâche de fond
  end;
exception when others then null;
end $$;
revoke execute on function public._push(uuid, uuid, text, text, text, text, text[]) from public, anon, authenticated;

-- Nouvelle réservation ou annulation venant de Nuittea.com
create or replace function public._push_resa()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare v_room text;
begin
  if new.source <> 'naya' then return new; end if;
  select number into v_room from public.rooms where id = new.room_id;
  if tg_op = 'INSERT' then
    perform public._push(new.organization_id, new.establishment_id, 'booking',
      case when new.status = 'pending' then 'Nouvelle demande de réservation' else 'Nouvelle réservation Nuittea.com' end,
      coalesce(new.guest_name, 'Client') || ' · ch. ' || coalesce(v_room, '?') || ' · ' || to_char(new.check_in, 'DD/MM') || ' → ' || to_char(new.check_out, 'DD/MM'),
      '?resa=' || new.id, array['owner','admin','manager','receptionist']);
  elsif new.status = 'cancelled' and old.status <> 'cancelled' then
    perform public._push(new.organization_id, new.establishment_id, 'cancel', 'Réservation annulée',
      coalesce(new.guest_name, 'Client') || ' a annulé · ch. ' || coalesce(v_room, '?') || ' · ' || to_char(new.check_in, 'DD/MM'),
      '?resa=' || new.id, array['owner','admin','manager','receptionist']);
  end if;
  return new;
end $$;
drop trigger if exists push_resa_ins on public.reservations;
create trigger push_resa_ins after insert on public.reservations for each row execute function public._push_resa();
drop trigger if exists push_resa_upd on public.reservations;
create trigger push_resa_upd after update of status on public.reservations for each row execute function public._push_resa();

-- Paiement en ligne reçu
create or replace function public._push_payment()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare r public.reservations;
begin
  if new.status = 'succeeded' and old.status <> 'succeeded' then
    select * into r from public.reservations where id = new.reservation_id;
    perform public._push(new.organization_id, new.establishment_id, 'payment', 'Paiement en ligne reçu',
      (case new.kind when 'deposit' then 'Acompte de ' else 'Paiement de ' end) || to_char(new.amount, 'FM999G999G999') || ' F · ' || coalesce(r.guest_name, 'Client'),
      '?resa=' || new.reservation_id, array['owner','admin','manager','receptionist','accountant']);
  end if;
  return new;
end $$;
drop trigger if exists push_payment_upd on public.booking_payments;
create trigger push_payment_upd after update of status on public.booking_payments for each row execute function public._push_payment();

-- Alerte de contrôle du propriétaire
create or replace function public._push_alert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform public._push(new.organization_id, new.establishment_id, 'control',
    case when new.severity = 'critical' then 'Alerte importante' else 'Alerte de contrôle' end,
    coalesce(new.message, 'Nouvelle alerte'), '?go=controle', array['owner','admin']);
  return new;
end $$;
drop trigger if exists push_alert_ins on public.owner_alerts;
create trigger push_alert_ins after insert on public.owner_alerts for each row execute function public._push_alert();

-- Stock bas ou épuisé (au passage du seuil)
create or replace function public._push_stock()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare v_seuil int := coalesce(new.alert_qty, 3);
begin
  if new.stock is not null and old.stock is not null and new.stock <= v_seuil and old.stock > v_seuil and new.is_active then
    perform public._push(new.organization_id, new.establishment_id, 'stock',
      case when new.stock <= 0 then 'Produit épuisé' else 'Stock bas' end,
      new.label || ' · ' || case when new.stock <= 0 then 'plus aucune unité' else 'reste ' || new.stock end,
      '?go=produits', array['owner','admin','manager']);
  end if;
  return new;
end $$;
drop trigger if exists push_stock_upd on public.extra_items;
create trigger push_stock_upd after update of stock on public.extra_items for each row execute function public._push_stock();

-- Rappel du soir : caisse non clôturée, départs non faits
create or replace function public.push_daily()
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e record; v_cash boolean; v_late int;
begin
  for e in select id, organization_id from public.establishments loop
    select exists (select 1 from public.cash_sessions c where c.establishment_id = e.id and c.closed_at is null) into v_cash;
    select count(*) into v_late from public.reservations r where r.establishment_id = e.id and r.status = 'checked_in' and r.check_out <= current_date;
    if v_cash or v_late > 0 then
      perform public._push(e.organization_id, e.id, 'daily', 'Avant de fermer la journée',
        concat_ws(' · ', case when v_cash then 'caisse à clôturer' end, case when v_late > 0 then v_late || ' départ(s) à enregistrer' end),
        '?go=dashboard', array['owner','admin','manager']);
    end if;
  end loop;
end $$;
revoke execute on function public.push_daily() from public, anon, authenticated;

-- Reprise des envois en attente chaque minute, rappel chaque soir à 20 h (heure d'Abidjan = UTC)
create or replace function public.push_flush_ping()
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_secret text;
begin
  if not exists (select 1 from public.push_outbox where sent_at is null) then return; end if;
  select hook_secret into v_secret from public.push_keys where key = 'vapid';
  perform net.http_post(url := 'https://kuuyhtvdnoqyikrcbpot.supabase.co/functions/v1/push',
    body := jsonb_build_object('action', 'flush'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret), timeout_milliseconds := 5000);
end $$;
revoke execute on function public.push_flush_ping() from public, anon, authenticated;
select cron.schedule('push-flush', '* * * * *', 'select public.push_flush_ping()');
select cron.schedule('push-daily', '0 20 * * *', 'select public.push_daily()');
