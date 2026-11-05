-- 50 · Ventes annexes (boissons, petit-déjeuner, blanchisserie, transport…)
-- Nouveau catalogue + lignes de vente. Une vente est encaissée tout de suite (entrée de caisse)
-- ou portée sur la note d'un séjour (elle s'ajoute alors au solde et à la facture).
-- Aucune donnée existante n'est modifiée ni supprimée.

create table if not exists public.extra_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  label text not null check (char_length(label) between 1 and 60),
  category text not null default 'autre' check (category in ('boissons','petit_dejeuner','blanchisserie','transport','autre')),
  price numeric(14,2) not null check (price >= 0 and price <= 100000000),
  stock integer check (stock is null or stock >= 0),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists extra_items_est_idx on public.extra_items (establishment_id, is_active);

create table if not exists public.extra_sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  item_id uuid references public.extra_items(id) on delete set null,
  label text not null,
  category text not null,
  qty integer not null check (qty between 1 and 999),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  total numeric(14,2) not null check (total >= 0),
  reservation_id uuid references public.reservations(id) on delete set null,
  payment_group uuid,
  status text not null default 'paid' check (status in ('paid','on_note','cancelled')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists extra_sales_resa_idx on public.extra_sales (reservation_id) where reservation_id is not null;
create index if not exists extra_sales_est_idx on public.extra_sales (establishment_id, created_at);

alter table public.extra_items enable row level security;
alter table public.extra_sales enable row level security;

create policy extra_items_read on public.extra_items for select to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager','receptionist','accountant']));
create policy extra_items_insert on public.extra_items for insert to authenticated
  with check (public.has_org_role(organization_id, array['owner','admin','manager'])
              and exists (select 1 from public.establishments e where e.id = establishment_id and e.organization_id = extra_items.organization_id));
create policy extra_items_update on public.extra_items for update to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager']))
  with check (public.has_org_role(organization_id, array['owner','admin','manager'])
              and exists (select 1 from public.establishments e where e.id = establishment_id and e.organization_id = extra_items.organization_id));
create policy extra_sales_read on public.extra_sales for select to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager','receptionist','accountant']));

revoke all on public.extra_items, public.extra_sales from anon;
grant select, insert, update on public.extra_items to authenticated;
grant select on public.extra_sales to authenticated;

-- Enregistrer une vente : p_items = [{"item_id": "...", "qty": 2}, …]
create or replace function public.extra_sale_record(p_est uuid, p_items jsonb, p_reservation uuid default null, p_method text default 'cash', p_reference text default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid; v_group uuid := gen_random_uuid(); x jsonb; it public.extra_items; q int; v_total numeric := 0; v_labels text := ''; r public.reservations;
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
    insert into public.extra_sales (organization_id, establishment_id, item_id, label, category, qty, unit_price, total, reservation_id, payment_group, status)
    values (v_org, p_est, it.id, it.label, it.category, q, it.price, it.price * q, p_reservation, v_group, case when p_reservation is null then 'paid' else 'on_note' end);
    v_total := v_total + it.price * q;
    v_labels := v_labels || case when v_labels = '' then '' else ', ' end || q || ' × ' || it.label;
  end loop;
  if p_reservation is null and v_total > 0 then
    insert into public.cash_movements (organization_id, establishment_id, kind, method, amount, label, reference, category, payment_group, created_by)
    values (v_org, p_est, 'income', coalesce(p_method, 'cash'), v_total, left('Ventes annexes : ' || v_labels, 200), nullif(trim(coalesce(p_reference, '')), ''), 'Ventes annexes', v_group, auth.uid());
  end if;
  return v_group;
end $$;

-- Retirer une ligne portée sur la note (erreur de saisie) : remet le stock
create or replace function public.extra_sale_cancel(p_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare s public.extra_sales;
begin
  select * into s from public.extra_sales where id = p_id for update;
  if s.id is null or not public.has_org_role(s.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  if s.status <> 'on_note' then raise exception 'Seule une ligne portée sur une note peut être retirée.'; end if;
  update public.extra_sales set status = 'cancelled' where id = p_id;
  update public.extra_items set stock = stock + s.qty where id = s.item_id and stock is not null;
end $$;

revoke execute on function public.extra_sale_record(uuid, jsonb, uuid, text, text), public.extra_sale_cancel(uuid) from public, anon;
grant execute on function public.extra_sale_record(uuid, jsonb, uuid, text, text), public.extra_sale_cancel(uuid) to authenticated;

-- Le solde d'un séjour comprend désormais les ventes annexes portées sur sa note (colonne « extras » ajoutée à la fin).
create or replace view public.reservation_balances with (security_invoker = true) as
 SELECT r.id, r.organization_id, r.establishment_id, r.room_id, rm.number AS room_number, r.guest_id, r.guest_name, r.guest_phone,
    r.check_in, r.check_out, r.check_out - r.check_in AS nights, r.status, r.source, r.adults, r.nightly_rate, r.discount, r.total_amount, r.notes,
    COALESCE(sum(m.amount) FILTER (WHERE m.kind = 'payment'::text), 0::numeric) - COALESCE(sum(m.amount) FILTER (WHERE m.kind = 'refund'::text), 0::numeric) AS paid,
    r.total_amount + COALESCE((select sum(x.total) from public.extra_sales x where x.reservation_id = r.id and x.status = 'on_note'), 0::numeric)
      - (COALESCE(sum(m.amount) FILTER (WHERE m.kind = 'payment'::text), 0::numeric) - COALESCE(sum(m.amount) FILTER (WHERE m.kind = 'refund'::text), 0::numeric)) AS balance,
    r.created_at,
    COALESCE((select sum(x.total) from public.extra_sales x where x.reservation_id = r.id and x.status = 'on_note'), 0::numeric) AS extras
   FROM public.reservations r
     JOIN public.rooms rm ON rm.id = r.room_id
     LEFT JOIN public.cash_movements m ON m.reservation_id = r.id
  GROUP BY r.id, rm.number;

-- Facture client : lignes de ventes annexes ajoutées
create or replace function public.issue_guest_invoice(p_reservation uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare r public.reservations; v_paid numeric; v_refund numeric; v_n bigint; v_id uuid; v_nights int; e public.establishments; v_extras numeric; v_lines jsonb;
begin
  select * into r from public.reservations where id = p_reservation;
  if not found or not public.has_org_role(r.organization_id, array['owner','admin','manager','receptionist','accountant']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(r.organization_id);
  select * into e from public.establishments where id = r.establishment_id;
  select coalesce(sum(amount) filter (where kind = 'payment'),0), coalesce(sum(amount) filter (where kind = 'refund'),0)
    into v_paid, v_refund from public.cash_movements where reservation_id = r.id;
  select coalesce(sum(total), 0) into v_extras from public.extra_sales where reservation_id = r.id and status = 'on_note';
  v_nights := r.check_out - r.check_in;
  v_lines := jsonb_build_array(
      jsonb_build_object('label', format('Hébergement chambre %s du %s au %s', (select number from public.rooms where id = r.room_id), to_char(r.check_in,'DD/MM/YYYY'), to_char(r.check_out,'DD/MM/YYYY')), 'qty', v_nights, 'unit', r.nightly_rate, 'amount', v_nights * r.nightly_rate))
    || case when r.discount > 0 then jsonb_build_array(jsonb_build_object('label','Remise','qty',1,'unit',-r.discount,'amount',-r.discount)) else '[]'::jsonb end
    || coalesce((select jsonb_agg(jsonb_build_object('label', x.label, 'qty', x.qty, 'unit', x.unit_price, 'amount', x.total) order by x.created_at)
                 from public.extra_sales x where x.reservation_id = r.id and x.status = 'on_note'), '[]'::jsonb);
  insert into public.org_counters (organization_id, name, value) values (r.organization_id, 'invoice', 1)
    on conflict (organization_id, name) do update set value = public.org_counters.value + 1 returning value into v_n;
  insert into public.guest_invoices (organization_id, establishment_id, reservation_id, number, guest_name, lines, total, paid, balance, issued_by)
  values (r.organization_id, r.establishment_id, r.id, 'F' || to_char(now(),'YYYY') || '-' || lpad(v_n::text, 5, '0'), r.guest_name,
    v_lines, r.total_amount + v_extras, v_paid - v_refund, r.total_amount + v_extras - (v_paid - v_refund), auth.uid())
  returning id into v_id;
  return v_id;
end $$;
