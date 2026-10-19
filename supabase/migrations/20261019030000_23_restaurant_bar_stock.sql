-- Horus Hotel — Migration 23 : Restaurant & Bar.
-- Produits (photo, prix d'achat fournisseur, prix de vente), stock avec historique, ventes en caisse
-- qui décomptent le stock automatiquement et créent la recette dans la caisse de l'établissement.
-- Le stock et les ventes ne s'écrivent QUE par les fonctions pos_checkout / stock_entry / pos_cancel_sale.

create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  outlet text not null default 'restaurant' check (outlet in ('restaurant','bar')),
  name text not null check (length(trim(name)) between 1 and 80),
  category text check (category is null or length(category) <= 40),
  image_url text check (image_url is null or length(image_url) <= 500),
  purchase_price numeric not null default 0 check (purchase_price >= 0),
  sale_price numeric not null check (sale_price >= 0),
  track_stock boolean not null default true,
  stock_qty numeric not null default 0,
  alert_qty numeric not null default 0 check (alert_qty >= 0),
  unit text not null default 'unité' check (length(unit) <= 20),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_est on public.products (establishment_id, outlet) where is_active;

create table public.pos_sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  number bigint generated always as identity,
  outlet text not null check (outlet in ('restaurant','bar')),
  table_label text check (table_label is null or length(table_label) <= 30),
  total numeric not null check (total >= 0),
  cost_total numeric not null default 0,
  method text not null check (method in ('cash','orange_money','mtn_money','moov_money','wave','card','bank_transfer')),
  reference text,
  status text not null default 'paid' check (status in ('paid','cancelled')),
  cancel_reason text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index pos_sales_est on public.pos_sales (establishment_id, created_at desc);

create table public.pos_sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.pos_sales(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  qty numeric not null check (qty > 0),
  unit_price numeric not null check (unit_price >= 0),
  unit_cost numeric not null default 0
);
create index pos_sale_items_sale on public.pos_sale_items (sale_id);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  kind text not null check (kind in ('purchase','sale','adjust','loss','cancel')),
  qty numeric not null,
  unit_cost numeric,
  supplier text check (supplier is null or length(supplier) <= 80),
  note text check (note is null or length(note) <= 200),
  sale_id uuid references public.pos_sales(id) on delete set null,
  balance_after numeric,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index stock_mv_product on public.stock_movements (product_id, created_at desc);

alter table public.products enable row level security;
alter table public.pos_sales enable row level security;
alter table public.pos_sale_items enable row level security;
alter table public.stock_movements enable row level security;

create policy products_select on public.products for select using (public.is_org_member(organization_id));
create policy products_insert on public.products for insert with check (public.has_org_role(organization_id, array['owner','admin','manager']));
create policy products_update on public.products for update using (public.has_org_role(organization_id, array['owner','admin','manager'])) with check (public.has_org_role(organization_id, array['owner','admin','manager']));
create policy pos_sales_select on public.pos_sales for select using (public.has_org_role(organization_id, array['owner','admin','manager','accountant']) or created_by = auth.uid());
create policy pos_items_select on public.pos_sale_items for select using (exists (select 1 from public.pos_sales s where s.id = sale_id and (public.has_org_role(s.organization_id, array['owner','admin','manager','accountant']) or s.created_by = auth.uid())));
create policy stock_mv_select on public.stock_movements for select using (public.has_org_role(organization_id, array['owner','admin','manager','accountant']));

-- Produits : organisation déduite de l'établissement ; stock modifiable seulement via les fonctions
create or replace function public.prepare_product()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  select organization_id into new.organization_id from public.establishments where id = new.establishment_id;
  if new.organization_id is null then raise exception 'Établissement introuvable.'; end if;
  if tg_op = 'INSERT' then
    if not public.is_service_context() and current_setting('app.pos_stock', true) is distinct from 'on' then new.stock_qty := 0; end if;
  else
    if new.stock_qty is distinct from old.stock_qty and current_setting('app.pos_stock', true) is distinct from 'on' and not public.is_service_context() then
      raise exception 'Le stock se modifie par une entrée de stock ou un inventaire.';
    end if;
    new.organization_id := old.organization_id; new.establishment_id := old.establishment_id;
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke execute on function public.prepare_product() from public, anon, authenticated;
create trigger trg_00_product_prepare before insert or update on public.products for each row execute function public.prepare_product();
create trigger trg_product_writable before insert or update on public.products for each row execute function public.guard_org_writable();
create trigger trg_000_product_feature before insert on public.products for each row execute function public.require_feature('restaurant', 'Le module Restaurant & Bar', 'Pro');

-- Entrée de stock (achat fournisseur), perte ou inventaire
create or replace function public.stock_entry(p_product uuid, p_kind text, p_qty numeric, p_unit_cost numeric default null, p_supplier text default null, p_note text default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare p public.products; v_new numeric; v_delta numeric;
begin
  select * into p from public.products where id = p_product for update;
  if p.id is null then raise exception 'Produit introuvable.'; end if;
  if not public.has_org_role(p.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if not public.org_has_feature(p.organization_id, 'restaurant') then raise exception 'Le module Restaurant & Bar n’est pas disponible dans votre formule.'; end if;
  perform public.assert_org_writable(p.organization_id);
  if p_kind not in ('purchase','loss','adjust') then raise exception 'Type de mouvement invalide.'; end if;
  if p_qty is null or (p_kind <> 'adjust' and p_qty <= 0) or (p_kind = 'adjust' and p_qty < 0) then raise exception 'Quantité invalide.'; end if;
  if p_kind = 'loss' and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'Indiquez la raison de la perte.'; end if;
  v_new := case p_kind when 'purchase' then p.stock_qty + p_qty when 'loss' then p.stock_qty - p_qty else p_qty end;
  v_delta := v_new - p.stock_qty;
  perform set_config('app.pos_stock', 'on', true);
  update public.products set stock_qty = v_new,
         purchase_price = case when p_kind = 'purchase' and p_unit_cost is not null and p_unit_cost >= 0 then p_unit_cost else purchase_price end
   where id = p.id;
  perform set_config('app.pos_stock', 'off', true);
  insert into public.stock_movements (organization_id, establishment_id, product_id, kind, qty, unit_cost, supplier, note, balance_after)
  values (p.organization_id, p.establishment_id, p.id, p_kind, v_delta, coalesce(p_unit_cost, p.purchase_price), nullif(trim(coalesce(p_supplier, '')), ''), nullif(trim(coalesce(p_note, '')), ''), v_new);
  insert into public.audit_log (organization_id, establishment_id, entity, entity_id, action, summary, details, actor_id)
  values (p.organization_id, p.establishment_id, 'stock', p.id, p_kind,
          case p_kind when 'purchase' then 'Entrée de stock' when 'loss' then 'Perte de stock' else 'Inventaire' end || ' : ' || p.name || ' (' || v_delta || ')',
          jsonb_build_object('qty', v_delta, 'balance', v_new, 'note', p_note), auth.uid());
  return v_new;
end $$;

-- Encaissement d'une commande : vérifie le stock, le décompte, enregistre la vente et la recette en caisse
create or replace function public.pos_checkout(p_est uuid, p_outlet text, p_items jsonb, p_method text, p_reference text default null, p_table text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_sale uuid; v_num bigint; v_total numeric := 0; v_cost numeric := 0; it jsonb; p public.products; q numeric; v_short text := '';
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if v_org is null then raise exception 'Établissement introuvable.'; end if;
  if not public.has_org_role(v_org, array['owner','admin','manager','receptionist','accountant','staff']) then raise exception 'Accès refusé.'; end if;
  if not public.org_has_feature(v_org, 'restaurant') then raise exception 'Le module Restaurant & Bar n’est pas disponible dans votre formule. Passez à la formule Pro pour en profiter.'; end if;
  perform public.assert_org_writable(v_org);
  if p_outlet not in ('restaurant','bar') then raise exception 'Point de vente invalide.'; end if;
  if p_method in ('orange_money','mtn_money','moov_money','wave') and length(trim(coalesce(p_reference, ''))) < 4 then raise exception 'Saisissez la référence de la transaction Mobile Money.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'La commande est vide.'; end if;
  -- vérification du stock (verrouillage des produits)
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::numeric;
    if q is null or q <= 0 or q > 999 then raise exception 'Quantité invalide.'; end if;
    select * into p from public.products where id = (it->>'product_id')::uuid and establishment_id = p_est and is_active for update;
    if p.id is null then raise exception 'Un produit de la commande n’existe plus.'; end if;
    if p.track_stock and p.stock_qty < q then v_short := v_short || case when v_short = '' then '' else ', ' end || p.name || ' (reste ' || greatest(p.stock_qty, 0) || ')'; end if;
  end loop;
  if v_short <> '' then raise exception 'Stock insuffisant : %', v_short using hint = 'POS_STOCK'; end if;

  insert into public.pos_sales (organization_id, establishment_id, outlet, table_label, total, method, reference)
  values (v_org, p_est, p_outlet, nullif(trim(coalesce(p_table, '')), ''), 0, p_method, nullif(trim(coalesce(p_reference, '')), ''))
  returning id, number into v_sale, v_num;
  perform set_config('app.pos_stock', 'on', true);
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::numeric;
    select * into p from public.products where id = (it->>'product_id')::uuid;
    insert into public.pos_sale_items (sale_id, product_id, name, qty, unit_price, unit_cost) values (v_sale, p.id, p.name, q, p.sale_price, p.purchase_price);
    v_total := v_total + q * p.sale_price; v_cost := v_cost + q * p.purchase_price;
    if p.track_stock then
      update public.products set stock_qty = stock_qty - q where id = p.id;
      insert into public.stock_movements (organization_id, establishment_id, product_id, kind, qty, unit_cost, sale_id, balance_after)
      values (v_org, p_est, p.id, 'sale', -q, p.purchase_price, v_sale, p.stock_qty - q);
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

-- Annulation d'un ticket (gérant et plus) : remet le stock et enregistre un remboursement en caisse
create or replace function public.pos_cancel_sale(p_sale uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.pos_sales; i record;
begin
  select * into s from public.pos_sales where id = p_sale for update;
  if s.id is null then raise exception 'Ticket introuvable.'; end if;
  if not public.has_org_role(s.organization_id, array['owner','admin','manager']) then raise exception 'Seul un gérant peut annuler un ticket.'; end if;
  if s.status = 'cancelled' then raise exception 'Ce ticket est déjà annulé.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Indiquez la raison de l’annulation.'; end if;
  perform public.assert_org_writable(s.organization_id);
  perform set_config('app.pos_stock', 'on', true);
  for i in select si.*, pr.track_stock from public.pos_sale_items si join public.products pr on pr.id = si.product_id where si.sale_id = s.id loop
    if i.track_stock then
      update public.products set stock_qty = stock_qty + i.qty where id = i.product_id;
      insert into public.stock_movements (organization_id, establishment_id, product_id, kind, qty, unit_cost, sale_id, note, balance_after)
      select s.organization_id, s.establishment_id, i.product_id, 'cancel', i.qty, i.unit_cost, s.id, 'Annulation ticket n° ' || s.number, stock_qty from public.products where id = i.product_id;
    end if;
  end loop;
  perform set_config('app.pos_stock', 'off', true);
  update public.pos_sales set status = 'cancelled', cancel_reason = trim(p_reason) where id = s.id;
  if s.total > 0 then
    insert into public.cash_movements (establishment_id, kind, method, amount, label, category)
    values (s.establishment_id, 'refund', s.method, s.total, 'Annulation ticket n° ' || s.number || ' : ' || trim(p_reason), case s.outlet when 'bar' then 'Bar' else 'Restaurant' end);
  end if;
  insert into public.audit_log (organization_id, establishment_id, entity, entity_id, action, summary, details, actor_id)
  values (s.organization_id, s.establishment_id, 'pos', s.id, 'annulation', 'Ticket n° ' || s.number || ' annulé (' || s.total || ' F) : ' || trim(p_reason), jsonb_build_object('total', s.total), auth.uid());
end $$;

-- Synthèse du jour / de la période : ventes, marge, meilleures ventes, alertes de stock
create or replace function public.pos_summary(p_est uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.establishments where id = p_est;
  if not public.has_org_role(v_org, array['owner','admin','manager','accountant']) then raise exception 'Accès refusé.'; end if;
  return jsonb_build_object(
    'sales', (select coalesce(sum(total), 0) from public.pos_sales where establishment_id = p_est and status = 'paid' and created_at::date between p_from and p_to),
    'cost', (select coalesce(sum(cost_total), 0) from public.pos_sales where establishment_id = p_est and status = 'paid' and created_at::date between p_from and p_to),
    'tickets', (select count(*) from public.pos_sales where establishment_id = p_est and status = 'paid' and created_at::date between p_from and p_to),
    'by_outlet', (select coalesce(jsonb_object_agg(outlet, t), '{}') from (select outlet, sum(total) t from public.pos_sales where establishment_id = p_est and status = 'paid' and created_at::date between p_from and p_to group by outlet) x),
    'top', (select coalesce(jsonb_agg(x order by x.qty desc), '[]') from (select si.name, sum(si.qty) qty, sum(si.qty * si.unit_price) amount, sum(si.qty * (si.unit_price - si.unit_cost)) margin
             from public.pos_sale_items si join public.pos_sales s on s.id = si.sale_id where s.establishment_id = p_est and s.status = 'paid' and s.created_at::date between p_from and p_to group by si.name order by 2 desc limit 8) x),
    'low_stock', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'stock', stock_qty, 'alert', alert_qty, 'unit', unit) order by stock_qty), '[]') from public.products where establishment_id = p_est and is_active and track_stock and stock_qty <= alert_qty),
    'stock_value', (select coalesce(sum(greatest(stock_qty, 0) * purchase_price), 0) from public.products where establishment_id = p_est and is_active and track_stock)
  );
end $$;

revoke execute on function public.stock_entry(uuid, text, numeric, numeric, text, text), public.pos_checkout(uuid, text, jsonb, text, text, text), public.pos_cancel_sale(uuid, text), public.pos_summary(uuid, date, date) from public, anon;
grant execute on function public.stock_entry(uuid, text, numeric, numeric, text, text), public.pos_checkout(uuid, text, jsonb, text, text, text), public.pos_cancel_sale(uuid, text), public.pos_summary(uuid, date, date) to authenticated;
grant select, insert, update on public.products to authenticated;
grant select on public.pos_sales, public.pos_sale_items, public.stock_movements to authenticated;

-- Fonction « restaurant » : Pro et au-dessus, essai inclus
update public.plans set features = features || '["restaurant"]'::jsonb, updated_at = now()
 where slug in ('pro','business','premium','enterprise','essai','standard') and not features ? 'restaurant';
