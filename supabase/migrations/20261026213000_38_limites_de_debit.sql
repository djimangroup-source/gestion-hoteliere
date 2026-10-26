-- 38 · Limites de débit (anti-abus) pour les actions publiques de NAYA
-- • rate_events + _rate_hit(clé, maximum, fenêtre) : compteur glissant, inaccessible aux clients.
-- • market_book : 20 tentatives/heure par adresse IP, 5 réservations/24 h par compte voyageur
--   (en plus des limites existantes : 3/24 h par téléphone, 40/heure par établissement).
-- • market_cancel_booking : 5 annulations/24 h par compte.
-- • market_search / market_establishment : 120 appels/minute par adresse IP.
-- Migration additive ; les anciennes traces sont purgées au fil de l'eau (plus de 2 jours).

create table if not exists public.rate_events (
  id bigint generated always as identity primary key,
  key text not null,
  created_at timestamptz not null default now()
);
create index if not exists rate_events_key_time on public.rate_events (key, created_at desc);
alter table public.rate_events enable row level security; -- aucune politique : invisible pour les clients
revoke all on public.rate_events from anon, authenticated;

create or replace function public._client_ip() returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(split_part(coalesce((current_setting('request.headers', true)::json ->> 'x-forwarded-for'), ''), ',', 1), ''),
                  (current_setting('request.headers', true)::json ->> 'cf-connecting-ip'), 'inconnue');
$$;

-- Vrai si la limite est atteinte (et dans ce cas l'appel n'est pas compté) ; sinon compte l'appel et renvoie faux.
create or replace function public._rate_hit(p_key text, p_max int, p_window interval) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if random() < 0.01 then delete from public.rate_events where created_at < now() - interval '2 days'; end if;
  select count(*) into n from public.rate_events where key = p_key and created_at > now() - p_window;
  if n >= p_max then return true; end if;
  insert into public.rate_events (key) values (p_key);
  return false;
end $$;
revoke execute on function public._rate_hit(text, int, interval), public._client_ip() from public, anon, authenticated;

do $$
declare d text; marker text := '  e := public._market_est(p_slug);';
begin
  -- Réservation
  d := pg_get_functiondef('public.market_book(text, text, date, date, integer, text, text, text, text)'::regprocedure);
  if position('_rate_hit' in d) = 0 then
    if position(marker in d) = 0 then raise exception 'market_book : repère introuvable.'; end if;
    d := replace(d, marker, $r$  if public._rate_hit('book:ip:' || public._client_ip(), 20, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'Trop de tentatives depuis cette connexion. Réessayez dans une heure.');
  end if;
  if auth.uid() is not null and public._rate_hit('book:user:' || auth.uid()::text, 5, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'Vous avez atteint la limite de 5 réservations par jour. Contactez-nous si besoin.');
  end if;
$r$ || marker);
    execute d;
  end if;
  -- Annulation
  d := pg_get_functiondef('public.market_cancel_booking(text)'::regprocedure);
  if position('_rate_hit' in d) = 0 then
    d := replace(d, $r$  select * into r from public.reservations where public_reference$r$, $r$  if public._rate_hit('cancel:user:' || auth.uid()::text, 5, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'Trop d''annulations aujourd''hui. Contactez l''établissement.');
  end if;
  select * into r from public.reservations where public_reference$r$);
    execute d;
  end if;
end $$;

-- Recherche et fiche : limite large contre l'aspiration automatique
do $$
declare d text; f text;
begin
  foreach f in array array['public.market_search(text, date, date, integer)', 'public.market_establishment(text, date, date, integer)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('_rate_hit' in d) = 0 then
      d := regexp_replace(d, E'\\mSTABLE\\M', 'VOLATILE');  -- un compteur écrit en base : la fonction ne peut plus être « stable »
      d := regexp_replace(d, E'\nbegin\n', E'\nbegin\n  if public._rate_hit(''read:ip:'' || public._client_ip(), 120, interval ''1 minute'') then raise exception ''Trop de requêtes : patientez une minute.''; end if;\n', '');
      if position('_rate_hit' in d) = 0 then raise exception '% : repère introuvable.', f; end if;
      execute d;
    end if;
  end loop;
end $$;
