-- 48 · Comptes voyageurs Nuittea.com : favoris synchronisés et avis après séjour — ajout uniquement.
-- • traveler_favorites : favoris du voyageur connecté (chaque voyageur ne voit et ne modifie que les siens).
-- • market_my_bookings : renvoie aussi l'avis déjà laissé et si un avis peut être donné (séjour terminé depuis moins de 90 jours).
-- • market_review_submit : avis d'un voyageur sur son propre séjour Nuittea terminé, mêmes règles que le lien d'avis envoyé par l'hôtel
--   (note 1 à 5, commentaire de 1000 caractères au plus, alerte au propriétaire si la note est de 2 ou moins).

create table if not exists public.traveler_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  slug text not null check (length(slug) between 1 and 120),
  created_at timestamptz not null default now(),
  primary key (user_id, slug)
);
alter table public.traveler_favorites enable row level security;
create policy fav_select on public.traveler_favorites for select to authenticated using (user_id = (select auth.uid()));
create policy fav_insert on public.traveler_favorites for insert to authenticated with check (user_id = (select auth.uid()));
create policy fav_delete on public.traveler_favorites for delete to authenticated using (user_id = (select auth.uid()));

create or replace function public.market_my_bookings()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'reference', r.public_reference, 'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out,
      'nights', r.check_out - r.check_in, 'adults', r.adults, 'total', r.total_amount, 'room_type', rm.room_type,
      'hotel', coalesce(e.public_name, e.name), 'slug', e.slug, 'city', e.city, 'phone', e.public_phone, 'whatsapp', e.public_whatsapp,
      'cover', e.public_cover_url, 'created_at', r.created_at,
      'can_cancel', r.status in ('pending', 'confirmed') and r.check_in > current_date,
      'review', (select jsonb_build_object('rating', v.rating, 'comment', v.comment) from public.reviews v where v.reservation_id = r.id and v.status = 'submitted'),
      'can_review', r.status = 'checked_out' and r.check_out >= current_date - 90
                    and not exists (select 1 from public.reviews v where v.reservation_id = r.id and v.status = 'submitted'))
    order by r.check_in desc)
    from public.reservations r join public.establishments e on e.id = r.establishment_id left join public.rooms rm on rm.id = r.room_id
    where r.naya_user_id = auth.uid() and r.source = 'naya'), '[]'::jsonb);
end $$;

create or replace function public.market_review_submit(p_reference text, p_rating int, p_comment text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.reservations; v public.reviews; c text := nullif(left(trim(coalesce(p_comment, '')), 1000), '');
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if public._rate_hit('review:' || auth.uid()::text, 10, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'Trop de tentatives : réessayez plus tard.'); end if;
  select * into r from public.reservations where public_reference = p_reference and naya_user_id = auth.uid() and source = 'naya';
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'Réservation introuvable.'); end if;
  if r.status <> 'checked_out' then return jsonb_build_object('ok', false, 'error', 'Vous pourrez donner votre avis après votre séjour.'); end if;
  if r.check_out < current_date - 90 then return jsonb_build_object('ok', false, 'error', 'Le délai pour donner un avis est dépassé (90 jours).'); end if;
  if p_rating is null or p_rating not between 1 and 5 then return jsonb_build_object('ok', false, 'error', 'Choisissez une note de 1 à 5.'); end if;
  select * into v from public.reviews where reservation_id = r.id for update;
  if v.id is not null and v.status = 'submitted' then return jsonb_build_object('ok', false, 'error', 'Merci, votre avis a déjà été enregistré.'); end if;
  if v.id is null then
    insert into public.reviews (organization_id, establishment_id, reservation_id, guest_name, rating, comment, status, submitted_at)
    values (r.organization_id, r.establishment_id, r.id, left(r.guest_name, 120), p_rating, c, 'submitted', now()) returning * into v;
  else
    update public.reviews set rating = p_rating, comment = c, status = 'submitted', submitted_at = now() where id = v.id;
  end if;
  if p_rating <= 2 then
    insert into public.owner_alerts (organization_id, establishment_id, severity, kind, message, entity, entity_id)
    values (r.organization_id, r.establishment_id, 'warning', 'review', 'Avis négatif (' || p_rating || '/5) de ' || coalesce(r.guest_name, 'un client') || coalesce(' : ' || left(c, 200), ''), 'review', v.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.market_review_submit(text, int, text) from public, anon;
grant execute on function public.market_review_submit(text, int, text) to authenticated;
