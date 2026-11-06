-- 57 · Minibar par chambre, recettes (consommation d'ingrédients), options proposées à la réservation sur Nuittea.com
-- Ajoute des colonnes, une table et des fonctions. Aucune donnée existante n'est modifiée ni supprimée.

alter table public.extra_items add column if not exists minibar_qty integer not null default 1 check (minibar_qty between 0 and 50);
alter table public.extra_items add column if not exists online_per_night boolean not null default false;

-- Mouvements : nouveau type « consommation » (ingrédient utilisé par une recette)
alter table public.extra_stock_moves drop constraint if exists extra_stock_moves_kind_check;
alter table public.extra_stock_moves add constraint extra_stock_moves_kind_check check (kind in ('in','loss','adjust','use'));

create table if not exists public.extra_recipes (
  item_id uuid not null references public.extra_items(id) on delete cascade,
  ingredient_id uuid not null references public.extra_items(id) on delete cascade,
  qty numeric(10,3) not null check (qty > 0 and qty <= 1000),
  primary key (item_id, ingredient_id),
  check (item_id <> ingredient_id)
);
alter table public.extra_recipes enable row level security;
create policy extra_recipes_read on public.extra_recipes for select to authenticated
  using (exists (select 1 from public.extra_items i where i.id = item_id and public.has_org_role(i.organization_id, array['owner','admin','manager','receptionist','accountant'])));
revoke all on public.extra_recipes from anon;
grant select on public.extra_recipes to authenticated;

-- Enregistrer la recette d'un produit : p_lines = [{"ingredient_id": "...", "qty": 2}, …]
create or replace function public.extra_recipe_set(p_item uuid, p_lines jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare it public.extra_items; x jsonb; g public.extra_items;
begin
  select * into it from public.extra_items where id = p_item;
  if it.id is null or not public.has_org_role(it.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) > 30 then raise exception 'Recette invalide.'; end if;
  delete from public.extra_recipes where item_id = it.id;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into g from public.extra_items where id = (x->>'ingredient_id')::uuid and establishment_id = it.establishment_id;
    if g.id is null or g.id = it.id then raise exception 'Ingrédient invalide.'; end if;
    insert into public.extra_recipes (item_id, ingredient_id, qty) values (it.id, g.id, (x->>'qty')::numeric);
  end loop;
end $$;

-- Sortie des ingrédients d'une vente (le stock d'un ingrédient ne descend jamais sous zéro)
create or replace function public._extra_consume(p_item uuid, p_qty int)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare r record; v_use int; v_new int;
begin
  for r in select rc.qty, g.* from public.extra_recipes rc join public.extra_items g on g.id = rc.ingredient_id where rc.item_id = p_item and g.stock is not null for update of g loop
    v_use := ceil(r.qty * p_qty);
    v_new := greatest(r.stock - v_use, 0);
    update public.extra_items set stock = v_new where id = r.id;
    insert into public.extra_stock_moves (organization_id, establishment_id, item_id, kind, qty, stock_after, note)
    values (r.organization_id, r.establishment_id, r.id, 'use', v_use, v_new, 'Recette');
  end loop;
end $$;
revoke execute on function public._extra_consume(uuid, int) from public, anon, authenticated;

-- Vente : sortie des ingrédients en plus du produit lui-même
create or replace function public.extra_sale_record(p_est uuid, p_items jsonb, p_reservation uuid default null, p_method text default 'cash', p_reference text default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid; v_group uuid := gen_random_uuid(); x jsonb; it public.extra_items; q int; v_total numeric := 0; v_labels text := ''; r public.reservations; v_price numeric;
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if v_org is null or not public.has_org_role(v_org, array['owner','admin','manager','receptionist']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(v_org);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then raise exception 'Panier vide ou trop long.'; end if;
  if p_reservation is not null then
    select * into r from public.reservations where id = p_reservation;
    if r.id is null or r.establishment_id <> p_est then raise exception 'Séjour introuvable.'; end if;
    if r.status not in ('confirmed','checked_in') then raise exception 'La note n''est ouverte que pour un séjour confirmé ou en cours.'; end if;
  end if;
  for x in select * from jsonb_array_elements(p_items) loop
    q := coalesce((x->>'qty')::int, 0);
    if q < 1 or q > 999 then raise exception 'Quantité invalide.'; end if;
    select * into it from public.extra_items where id = (x->>'item_id')::uuid and establishment_id = p_est and is_active for update;
    if it.id is null then raise exception 'Article introuvable.'; end if;
    if it.stock is not null then
      if it.stock < q then raise exception 'Stock insuffisant pour « % » (reste %).', it.label, it.stock; end if;
      update public.extra_items set stock = stock - q where id = it.id;
    end if;
    perform public._extra_consume(it.id, q);
    v_price := public.extra_item_price(it);
    insert into public.extra_sales (organization_id, establishment_id, item_id, label, category, qty, unit_price, total, reservation_id, payment_group, status)
    values (v_org, p_est, it.id, it.label, it.category, q, v_price, v_price * q, p_reservation, v_group, case when p_reservation is null then 'paid' else 'on_note' end);
    v_total := v_total + v_price * q;
    v_labels := v_labels || case when v_labels = '' then '' else ', ' end || q || ' × ' || it.label;
  end loop;
  if p_reservation is null and v_total > 0 then
    insert into public.cash_movements (organization_id, establishment_id, kind, method, amount, label, reference, category, payment_group, created_by)
    values (v_org, p_est, 'income', coalesce(p_method, 'cash'), v_total, left('Ventes annexes : ' || v_labels, 200), nullif(trim(coalesce(p_reference, '')), ''), 'Ventes annexes', v_group, auth.uid());
  end if;
  return v_group;
end $$;

-- Options proposées en ligne pour un établissement (lecture publique, prix appliqué)
create or replace function public.market_options(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare e public.establishments;
begin
  e := public._market_est(p_slug);
  if e.id is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'label', i.label, 'description', i.description, 'price', public.extra_item_price(i), 'per_night', i.online_per_night, 'photo', i.photo_url) order by i.category, i.label)
    from public.extra_items i where i.establishment_id = e.id and i.is_active and i.online and (i.stock is null or i.stock > 0)), '[]'::jsonb);
end $$;

-- Ajout des options choisies juste après une réservation en ligne (référence + téléphone, dans les 30 minutes)
create or replace function public.market_book_options(p_reference text, p_phone text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare r public.reservations; x jsonb; it public.extra_items; q int; v_n int; v_total numeric := 0; v_price numeric; v_group uuid := gen_random_uuid(); v_phone text;
begin
  if public._rate_hit('opt:ip:' || public._client_ip(), 20, interval '1 hour') then return jsonb_build_object('ok', false, 'error', 'Trop de tentatives.'); end if;
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  select * into r from public.reservations where public_reference = p_reference and source = 'naya' and created_at > now() - interval '30 minutes';
  if r.id is null or right(regexp_replace(coalesce(r.guest_phone, ''), '[^0-9]', '', 'g'), 8) <> right(regexp_replace(v_phone, '[^0-9]', '', 'g'), 8) then
    return jsonb_build_object('ok', false, 'error', 'Réservation introuvable.'); end if;
  if r.status not in ('pending','confirmed') then return jsonb_build_object('ok', false, 'error', 'Réservation non modifiable.'); end if;
  if exists (select 1 from public.extra_sales where reservation_id = r.id and label like '% (réservé en ligne)') then
    return jsonb_build_object('ok', false, 'error', 'Options déjà enregistrées.'); end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 10 then return jsonb_build_object('ok', false, 'error', 'Aucune option.'); end if;
  v_n := r.check_out - r.check_in;
  for x in select * from jsonb_array_elements(p_items) loop
    select * into it from public.extra_items where id = (x->>'item_id')::uuid and establishment_id = r.establishment_id and is_active and online;
    if it.id is null then continue; end if;
    q := least(greatest(coalesce((x->>'qty')::int, 1), 1), 10) * case when it.online_per_night then v_n else 1 end;
    v_price := public.extra_item_price(it);
    insert into public.extra_sales (organization_id, establishment_id, item_id, label, category, qty, unit_price, total, reservation_id, payment_group, status, created_by)
    values (r.organization_id, r.establishment_id, it.id, it.label || ' (réservé en ligne)', it.category, q, v_price, v_price * q, r.id, v_group, 'on_note', null);
    v_total := v_total + v_price * q;
  end loop;
  return jsonb_build_object('ok', true, 'total', v_total);
end $$;

revoke execute on function public.extra_recipe_set(uuid, jsonb) from public, anon;
grant execute on function public.extra_recipe_set(uuid, jsonb) to authenticated;
grant execute on function public.market_options(text), public.market_book_options(text, text, jsonb) to anon, authenticated;
