-- 52 · La page « Restaurant et bar » peut aussi être accordée ou retirée à un employé
create or replace function public.set_member_access(p_member uuid, p_overrides jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare m public.organization_members; v_pages jsonb; v_actions jsonb; k text;
  allowed_pages text[] := array['dashboard','reservations','planning','naya','passes','clients','chambres','inventaire','pointage','caisse','resto','depenses','factures','rapports','controle','mapage'];
begin
  select * into m from public.organization_members where id = p_member;
  if m.id is null or not public.has_org_role(m.organization_id, array['owner','admin']) then raise exception 'Accès refusé.'; end if;
  if m.role = 'owner' then raise exception 'Les accès du propriétaire ne se règlent pas.'; end if;
  if m.role = 'admin' and not public.has_org_role(m.organization_id, array['owner']) then raise exception 'Seul le propriétaire règle les accès d''un administrateur.'; end if;
  v_pages := coalesce(p_overrides -> 'pages', '{}'::jsonb);
  v_actions := coalesce(p_overrides -> 'actions', '{}'::jsonb);
  for k in select jsonb_array_elements_text(coalesce(v_pages -> 'add', '[]'::jsonb) || coalesce(v_pages -> 'remove', '[]'::jsonb)) loop
    if not (k = any(allowed_pages)) then raise exception 'Page inconnue : %', k; end if;
  end loop;
  for k in select jsonb_object_keys(v_actions) loop
    if k not in ('discount','cancel_payment') then raise exception 'Action inconnue : %', k; end if;
  end loop;
  update public.organization_members
     set access_overrides = jsonb_build_object('pages', jsonb_build_object('add', coalesce(v_pages -> 'add', '[]'::jsonb), 'remove', coalesce(v_pages -> 'remove', '[]'::jsonb)), 'actions', v_actions)
   where id = p_member;
  perform public.write_audit(m.organization_id, null, 'equipe', m.id, 'acces', 'Accès d''un employé modifiés', jsonb_build_object('acces', p_overrides));
end $$;
revoke execute on function public.set_member_access(uuid, jsonb) from public, anon;
grant execute on function public.set_member_access(uuid, jsonb) to authenticated;
