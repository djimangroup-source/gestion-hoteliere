-- Horus Hotel — Migration 26 : fiche produit complète (façon Kweeli) et caisse enrichie.
-- • produits : 4 photos, code-barres, étiquettes, prix promo, fournisseur, description, temps de préparation, variantes ;
-- • ventes : nom du serveur, variante vendue ;
-- • pos_checkout_v2 : prix promo / prix de variante, serveur (l'ancienne pos_checkout reste disponible).

alter table public.products
  add column if not exists images text[] not null default '{}' check (cardinality(images) <= 4),
  add column if not exists barcode text check (barcode is null or length(barcode) <= 64),
  add column if not exists tags text[] not null default '{}' check (cardinality(tags) <= 8),
  add column if not exists promo_price numeric check (promo_price is null or promo_price >= 0),
  add column if not exists supplier text check (supplier is null or length(supplier) <= 80),
  add column if not exists description text check (description is null or length(description) <= 2000),
  add column if not exists prep_minutes int check (prep_minutes is null or prep_minutes between 0 and 600),
  add column if not exists variants jsonb not null default '[]' check (jsonb_typeof(variants) = 'array' and jsonb_array_length(variants) <= 30);
create index if not exists products_barcode on public.products (establishment_id, barcode) where barcode is not null;
update public.products set images = array[image_url] where image_url is not null and cardinality(images) = 0;

alter table public.pos_sales add column if not exists server_name text check (server_name is null or length(server_name) <= 60);
alter table public.pos_sale_items add column if not exists variant text check (variant is null or length(variant) <= 60);

create or replace function public.pos_checkout_v2(p_est uuid, p_outlet text, p_items jsonb, p_method text, p_reference text default null, p_table text default null, p_server text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_sale uuid; v_num bigint; v_total numeric := 0; v_cost numeric := 0; it jsonb; p public.products; q numeric; v_short text := '';
        v_var text; v_price numeric; v_vp jsonb;
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if v_org is null then raise exception 'Établissement introuvable.'; end if;
  if not public.has_org_role(v_org, array['owner','admin','manager','receptionist','accountant','staff']) then raise exception 'Accès refusé.'; end if;
  if not public.org_has_feature(v_org, 'restaurant') then raise exception 'Le module Restaurant & Bar n’est pas disponible dans votre formule. Passez à la formule Pro pour en profiter.'; end if;
  perform public.assert_org_writable(v_org);
  if p_outlet not in ('restaurant','bar') then raise exception 'Point de vente invalide.'; end if;
  if p_method in ('orange_money','mtn_money','moov_money','wave') and length(trim(coalesce(p_reference, ''))) < 4 then raise exception 'Saisissez la référence de la transaction Mobile Money.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'La commande est vide.'; end if;
  -- vérification du stock (cumul par produit, verrouillage)
  for it in select jsonb_build_object('product_id', x->>'product_id', 'qty', sum((x->>'qty')::numeric)) from jsonb_array_elements(p_items) x group by x->>'product_id' loop
    q := (it->>'qty')::numeric;
    if q is null or q <= 0 or q > 999 then raise exception 'Quantité invalide.'; end if;
    select * into p from public.products where id = (it->>'product_id')::uuid and establishment_id = p_est and is_active for update;
    if p.id is null then raise exception 'Un produit de la commande n’existe plus.'; end if;
    if p.track_stock and p.stock_qty < q then v_short := v_short || case when v_short = '' then '' else ', ' end || p.name || ' (reste ' || greatest(p.stock_qty, 0) || ')'; end if;
  end loop;
  if v_short <> '' then raise exception 'Stock insuffisant : %', v_short using hint = 'POS_STOCK'; end if;

  insert into public.pos_sales (organization_id, establishment_id, outlet, table_label, total, method, reference, server_name)
  values (v_org, p_est, p_outlet, nullif(trim(coalesce(p_table, '')), ''), 0, p_method, nullif(trim(coalesce(p_reference, '')), ''), nullif(left(trim(coalesce(p_server, '')), 60), ''))
  returning id, number into v_sale, v_num;
  perform set_config('app.pos_stock', 'on', true);
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::numeric;
    select * into p from public.products where id = (it->>'product_id')::uuid;
    v_var := nullif(trim(coalesce(it->>'variant', '')), '');
    v_price := case when p.promo_price is not null and p.promo_price > 0 and p.promo_price < p.sale_price then p.promo_price else p.sale_price end;
    if v_var is not null then
      select v into v_vp from jsonb_array_elements(p.variants) v where v->>'name' = v_var limit 1;
      if v_vp is null then raise exception 'Variante « % » introuvable pour %.', v_var, p.name; end if;
      if (v_vp->>'price') is not null and (v_vp->>'price')::numeric >= 0 then v_price := (v_vp->>'price')::numeric; end if;
    end if;
    insert into public.pos_sale_items (sale_id, product_id, name, qty, unit_price, unit_cost, variant)
    values (v_sale, p.id, p.name || coalesce(' · ' || v_var, ''), q, v_price, p.purchase_price, v_var);
    v_total := v_total + q * v_price; v_cost := v_cost + q * p.purchase_price;
    if p.track_stock then
      update public.products set stock_qty = stock_qty - q where id = p.id returning stock_qty into p.stock_qty;
      insert into public.stock_movements (organization_id, establishment_id, product_id, kind, qty, unit_cost, sale_id, balance_after)
      values (v_org, p_est, p.id, 'sale', -q, p.purchase_price, v_sale, p.stock_qty);
    end if;
  end loop;
  perform set_config('app.pos_stock', 'off', true);
  update public.pos_sales set total = v_total, cost_total = v_cost where id = v_sale;
  if v_total > 0 then
    insert into public.cash_movements (establishment_id, kind, method, amount, label, reference, category)
    values (p_est, 'income', p_method, v_total, case p_outlet when 'bar' then 'Bar' else 'Restaurant' end || ' · ticket n° ' || v_num || coalesce(' · ' || nullif(trim(coalesce(p_table, '')), ''), ''),
            nullif(trim(coalesce(p_reference, '')), ''), case p_outlet when 'bar' then 'Bar' else 'Restaurant' end);
  end if;
  return jsonb_build_object('sale_id', v_sale, 'number', v_num, 'total', v_total);
end $$;
revoke execute on function public.pos_checkout_v2(uuid, text, jsonb, text, text, text, text) from public, anon;
grant execute on function public.pos_checkout_v2(uuid, text, jsonb, text, text, text, text) to authenticated;
