-- 55 · Produits (fiche complète, promotions datées, prix happy hour), inventaires guidés, réceptions fournisseurs
-- Ajoute des colonnes, des tables et des fonctions. Aucune donnée existante n'est modifiée ni supprimée.

alter table public.extra_items add column if not exists description text check (description is null or char_length(description) <= 300);
alter table public.extra_items add column if not exists barcode text check (barcode is null or char_length(barcode) <= 40);
alter table public.extra_items add column if not exists subcategory text check (subcategory is null or char_length(subcategory) <= 40);
alter table public.extra_items add column if not exists promo_price numeric(14,2) check (promo_price is null or promo_price >= 0);
alter table public.extra_items add column if not exists promo_from date;
alter table public.extra_items add column if not exists promo_to date;
alter table public.extra_items add column if not exists happy_price numeric(14,2) check (happy_price is null or happy_price >= 0);
alter table public.extra_items add column if not exists happy_start time;
alter table public.extra_items add column if not exists happy_end time;
alter table public.extra_items add column if not exists sell_pos boolean not null default true;
alter table public.extra_items add column if not exists in_minibar boolean not null default false;
alter table public.extra_items add column if not exists online boolean not null default false;

-- Prix appliqué maintenant : promotion datée, sinon happy hour, sinon prix normal (heure d'Abidjan)
create or replace function public.extra_item_price(it public.extra_items)
returns numeric
language sql
stable
set search_path to ''
as $$
  select case
    when it.promo_price is not null and (it.promo_from is null or (now() at time zone 'Africa/Abidjan')::date >= it.promo_from)
         and (it.promo_to is null or (now() at time zone 'Africa/Abidjan')::date <= it.promo_to) and (it.promo_from is not null or it.promo_to is not null) then it.promo_price
    when it.happy_price is not null and it.happy_start is not null and it.happy_end is not null and (
         case when it.happy_start <= it.happy_end then (now() at time zone 'Africa/Abidjan')::time between it.happy_start and it.happy_end
              else (now() at time zone 'Africa/Abidjan')::time >= it.happy_start or (now() at time zone 'Africa/Abidjan')::time <= it.happy_end end) then it.happy_price
    else it.price end;
$$;

-- La vente utilise désormais le prix appliqué (promotion ou happy hour)
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

-- Entrée en stock : le prix d'achat devient le coût moyen pondéré
create or replace function public.extra_stock_move(p_item uuid, p_kind text, p_qty int, p_unit_cost numeric default null, p_note text default null)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare it public.extra_items; v_new int; v_cost numeric;
begin
  select * into it from public.extra_items where id = p_item for update;
  if it.id is null or not public.has_org_role(it.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(it.organization_id);
  if p_kind not in ('in','loss','adjust') then raise exception 'Mouvement inconnu.'; end if;
  if p_qty is null or p_qty < 0 or p_qty > 100000 or (p_kind <> 'adjust' and p_qty = 0) then raise exception 'Quantité invalide.'; end if;
  v_new := case p_kind when 'in' then coalesce(it.stock, 0) + p_qty when 'loss' then coalesce(it.stock, 0) - p_qty else p_qty end;
  if v_new < 0 then raise exception 'La perte dépasse le stock disponible (%).', coalesce(it.stock, 0); end if;
  v_cost := it.unit_cost;
  if p_kind = 'in' and p_unit_cost is not null then
    v_cost := case when it.unit_cost is null or coalesce(it.stock, 0) <= 0 then p_unit_cost
                   else round((it.stock * it.unit_cost + p_qty * p_unit_cost) / (it.stock + p_qty), 2) end;
  end if;
  update public.extra_items set stock = v_new, unit_cost = v_cost where id = it.id;
  insert into public.extra_stock_moves (organization_id, establishment_id, item_id, kind, qty, stock_after, unit_cost, note)
  values (it.organization_id, it.establishment_id, it.id, p_kind, p_qty, v_new, p_unit_cost, nullif(trim(coalesce(p_note, '')), ''));
  perform public.write_audit(it.organization_id, it.establishment_id, 'stock', it.id, p_kind,
    case p_kind when 'in' then 'Entrée en stock : ' when 'loss' then 'Perte de stock : ' else 'Inventaire : ' end || p_qty || ' × ' || it.label,
    jsonb_build_object('avant', it.stock, 'apres', v_new));
  return v_new;
end $$;

-- Inventaires guidés (comptage article par article, reprise possible, écarts valorisés)
create table if not exists public.extra_counts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  label text not null,
  status text not null default 'open' check (status in ('open','closed','cancelled')),
  loss_value numeric(14,2),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create table if not exists public.extra_count_lines (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.extra_counts(id) on delete cascade,
  item_id uuid not null references public.extra_items(id) on delete cascade,
  expected integer not null,
  counted integer check (counted is null or counted between 0 and 100000),
  unit_cost numeric(14,2),
  unique (count_id, item_id)
);
alter table public.extra_counts enable row level security;
alter table public.extra_count_lines enable row level security;
create policy extra_counts_read on public.extra_counts for select to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager','accountant']));
create policy extra_count_lines_read on public.extra_count_lines for select to authenticated
  using (exists (select 1 from public.extra_counts c where c.id = count_id and public.has_org_role(c.organization_id, array['owner','admin','manager','accountant'])));
revoke all on public.extra_counts, public.extra_count_lines from anon;
grant select on public.extra_counts, public.extra_count_lines to authenticated;

create or replace function public.extra_count_start(p_est uuid, p_category text default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid; v_id uuid;
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if v_org is null or not public.has_org_role(v_org, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(v_org);
  insert into public.extra_counts (organization_id, establishment_id, label)
  values (v_org, p_est, 'Inventaire' || case when p_category is null then '' else ' · ' || p_category end || ' du ' || to_char(now() at time zone 'Africa/Abidjan', 'DD/MM/YYYY'))
  returning id into v_id;
  insert into public.extra_count_lines (count_id, item_id, expected, unit_cost)
  select v_id, i.id, i.stock, i.unit_cost from public.extra_items i
  where i.establishment_id = p_est and i.is_active and i.stock is not null and (p_category is null or i.category = p_category);
  if not found then raise exception 'Aucun article suivi en stock dans cette sélection.'; end if;
  return v_id;
end $$;

create or replace function public.extra_count_set(p_line uuid, p_counted int)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare c public.extra_counts;
begin
  select c2.* into c from public.extra_counts c2 join public.extra_count_lines l on l.count_id = c2.id where l.id = p_line;
  if c.id is null or not public.has_org_role(c.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if c.status <> 'open' then raise exception 'Cet inventaire est clôturé.'; end if;
  if p_counted is not null and (p_counted < 0 or p_counted > 100000) then raise exception 'Quantité invalide.'; end if;
  update public.extra_count_lines set counted = p_counted where id = p_line;
end $$;

-- Clôture : le stock prend la quantité comptée (les ventes faites pendant le comptage sont prises en compte)
create or replace function public.extra_count_close(p_count uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare c public.extra_counts; l record; v_loss numeric := 0; v_gain numeric := 0; v_n int := 0; v_sold int; v_new int;
begin
  select * into c from public.extra_counts where id = p_count for update;
  if c.id is null or not public.has_org_role(c.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if c.status <> 'open' then raise exception 'Cet inventaire est déjà clôturé.'; end if;
  for l in select cl.*, i.label, i.stock cur_stock from public.extra_count_lines cl join public.extra_items i on i.id = cl.item_id where cl.count_id = c.id and cl.counted is not null loop
    -- ventes enregistrées depuis le début du comptage : déjà sorties du stock
    v_sold := greatest(l.expected - coalesce(l.cur_stock, 0), 0);
    v_new := greatest(l.counted - v_sold, 0);
    if l.counted <> l.expected then
      v_n := v_n + 1;
      if l.counted < l.expected then v_loss := v_loss + (l.expected - l.counted) * coalesce(l.unit_cost, 0);
      else v_gain := v_gain + (l.counted - l.expected) * coalesce(l.unit_cost, 0); end if;
    end if;
    if v_new is distinct from l.cur_stock then
      update public.extra_items set stock = v_new where id = l.item_id;
      insert into public.extra_stock_moves (organization_id, establishment_id, item_id, kind, qty, stock_after, note)
      values (c.organization_id, c.establishment_id, l.item_id, 'adjust', v_new, v_new, left(c.label || ' · écart ' || (l.counted - l.expected), 200));
    end if;
  end loop;
  update public.extra_counts set status = 'closed', closed_at = now(), loss_value = v_loss - v_gain where id = c.id;
  perform public.write_audit(c.organization_id, c.establishment_id, 'stock', c.id, 'inventaire', c.label || ' clôturé : ' || v_n || ' écart(s)', jsonb_build_object('perte', v_loss, 'surplus', v_gain));
  if v_loss - v_gain > 0 then
    perform public.raise_owner_alert(c.organization_id, c.establishment_id, case when v_loss - v_gain >= 20000 then 'critical' else 'warning' end, 'stock_gap',
      c.label || ' : démarque de ' || round(v_loss - v_gain) || ' F au prix d''achat.', 'stock', c.id);
  end if;
  return jsonb_build_object('gaps', v_n, 'loss', v_loss, 'gain', v_gain);
end $$;

create or replace function public.extra_count_cancel(p_count uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare c public.extra_counts;
begin
  select * into c from public.extra_counts where id = p_count;
  if c.id is null or not public.has_org_role(c.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if c.status <> 'open' then raise exception 'Cet inventaire est déjà clôturé.'; end if;
  update public.extra_counts set status = 'cancelled', closed_at = now() where id = c.id;
end $$;

-- Réceptions fournisseurs (plusieurs articles à la fois)
create table if not exists public.extra_receptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  supplier text check (supplier is null or char_length(supplier) <= 80),
  reference text check (reference is null or char_length(reference) <= 60),
  total numeric(14,2) not null default 0,
  lines jsonb not null default '[]'::jsonb,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.extra_receptions enable row level security;
create policy extra_receptions_read on public.extra_receptions for select to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager','accountant']));
revoke all on public.extra_receptions from anon;
grant select on public.extra_receptions to authenticated;

create or replace function public.extra_reception(p_est uuid, p_supplier text, p_reference text, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid; v_id uuid; x jsonb; it public.extra_items; q int; c numeric; v_total numeric := 0; v_lines jsonb := '[]'::jsonb;
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if v_org is null or not public.has_org_role(v_org, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(v_org);
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 or jsonb_array_length(p_lines) > 100 then raise exception 'Bon de réception vide ou trop long.'; end if;
  insert into public.extra_receptions (organization_id, establishment_id, supplier, reference)
  values (v_org, p_est, nullif(trim(coalesce(p_supplier, '')), ''), nullif(trim(coalesce(p_reference, '')), '')) returning id into v_id;
  for x in select * from jsonb_array_elements(p_lines) loop
    q := coalesce((x->>'qty')::int, 0); c := nullif(x->>'unit_cost', '')::numeric;
    select * into it from public.extra_items where id = (x->>'item_id')::uuid and establishment_id = p_est;
    if it.id is null then raise exception 'Article introuvable.'; end if;
    if q < 1 or q > 100000 or (c is not null and c < 0) then raise exception 'Ligne invalide pour « % ».', it.label; end if;
    perform public.extra_stock_move(it.id, 'in', q, c, 'Réception' || coalesce(' · ' || nullif(trim(coalesce(p_supplier, '')), ''), ''));
    v_total := v_total + q * coalesce(c, 0);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'label', it.label, 'qty', q, 'unit_cost', c));
  end loop;
  update public.extra_receptions set total = v_total, lines = v_lines where id = v_id;
  return v_id;
end $$;

revoke execute on function public.extra_count_start(uuid, text), public.extra_count_set(uuid, int), public.extra_count_close(uuid), public.extra_count_cancel(uuid), public.extra_reception(uuid, text, text, jsonb) from public, anon;
grant execute on function public.extra_count_start(uuid, text), public.extra_count_set(uuid, int), public.extra_count_close(uuid), public.extra_count_cancel(uuid), public.extra_reception(uuid, text, text, jsonb) to authenticated;
