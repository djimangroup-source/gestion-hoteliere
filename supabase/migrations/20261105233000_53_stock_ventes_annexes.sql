-- 53 · Gestion de stock des articles de ventes annexes : photo, prix d'achat, seuil d'alerte, mouvements de stock
-- Ajoute des colonnes et une table. Aucune donnée existante n'est modifiée ni supprimée.

alter table public.extra_items add column if not exists photo_url text check (photo_url is null or photo_url ~ '^https://');
alter table public.extra_items add column if not exists unit_cost numeric(14,2) check (unit_cost is null or (unit_cost >= 0 and unit_cost <= 100000000));
alter table public.extra_items add column if not exists alert_qty integer check (alert_qty is null or alert_qty >= 0);

create table if not exists public.extra_stock_moves (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  item_id uuid not null references public.extra_items(id) on delete cascade,
  kind text not null check (kind in ('in','loss','adjust')),
  qty integer not null check (qty between 0 and 100000),
  stock_after integer not null,
  unit_cost numeric(14,2) check (unit_cost is null or unit_cost >= 0),
  note text check (note is null or char_length(note) <= 200),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists extra_stock_moves_item_idx on public.extra_stock_moves (item_id, created_at desc);
alter table public.extra_stock_moves enable row level security;
create policy extra_stock_moves_read on public.extra_stock_moves for select to authenticated
  using (public.has_org_role(organization_id, array['owner','admin','manager','accountant']));
revoke all on public.extra_stock_moves from anon;
grant select on public.extra_stock_moves to authenticated;

-- Entrée (réapprovisionnement), perte (casse, péremption) ou inventaire (stock compté)
create or replace function public.extra_stock_move(p_item uuid, p_kind text, p_qty int, p_unit_cost numeric default null, p_note text default null)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare it public.extra_items; v_new int;
begin
  select * into it from public.extra_items where id = p_item for update;
  if it.id is null or not public.has_org_role(it.organization_id, array['owner','admin','manager']) then raise exception 'Accès refusé.'; end if;
  perform public.assert_org_writable(it.organization_id);
  if p_kind not in ('in','loss','adjust') then raise exception 'Mouvement inconnu.'; end if;
  if p_qty is null or p_qty < 0 or p_qty > 100000 or (p_kind <> 'adjust' and p_qty = 0) then raise exception 'Quantité invalide.'; end if;
  v_new := case p_kind when 'in' then coalesce(it.stock, 0) + p_qty when 'loss' then coalesce(it.stock, 0) - p_qty else p_qty end;
  if v_new < 0 then raise exception 'La perte dépasse le stock disponible (%).', coalesce(it.stock, 0); end if;
  update public.extra_items set stock = v_new, unit_cost = case when p_kind = 'in' and p_unit_cost is not null then p_unit_cost else unit_cost end where id = it.id;
  insert into public.extra_stock_moves (organization_id, establishment_id, item_id, kind, qty, stock_after, unit_cost, note)
  values (it.organization_id, it.establishment_id, it.id, p_kind, p_qty, v_new, p_unit_cost, nullif(trim(coalesce(p_note, '')), ''));
  perform public.write_audit(it.organization_id, it.establishment_id, 'stock', it.id, p_kind,
    case p_kind when 'in' then 'Entrée en stock : ' when 'loss' then 'Perte de stock : ' else 'Inventaire : ' end || p_qty || ' × ' || it.label,
    jsonb_build_object('avant', it.stock, 'apres', v_new));
  return v_new;
end $$;
revoke execute on function public.extra_stock_move(uuid, text, int, numeric, text) from public, anon;
grant execute on function public.extra_stock_move(uuid, text, int, numeric, text) to authenticated;

-- Photos des articles : le gérant peut aussi en déposer (dossier <org>/<établissement>/products/)
create policy media_insert_products_manager on storage.objects for insert to authenticated
  with check (bucket_id = 'public-media' and (storage.foldername(name))[3] = 'products'
              and (select public.has_org_role(((storage.foldername(name))[1])::uuid, array['manager'])));
