-- Horus Hotel — tests de la réservation publique (migration 10)
-- Exécution : SQL Editor Supabase. Le bloc se termine par RAISE EXCEPTION : TOUTES les données de test sont annulées.
-- Le message d'erreur final contient le résultat de chaque test (OK / ECHEC).
do $$
declare u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); o1 uuid; o2 uuid; e1 uuid; e2 uuid; r jsonb; r2 jsonb; msg text; c int; ref1 text;
  v_p text := '07' || lpad((floor(random()*1e8))::bigint::text, 8, '0');
  res text := '';
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select x, '00000000-0000-0000-0000-000000000000','authenticated','authenticated','tmp_'||x||'@exemple.ci', now(), now() from unnest(array[u1,u2]) x;
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role','authenticated')::text, true);
  o1 := public.create_organization('Org Pub 1','Villa Test','Abidjan'); select id into e1 from public.establishments where organization_id = o1;
  insert into public.rooms (establishment_id, number, room_type, base_rate, capacity) values (e1,'1','Suite',40000,2),(e1,'2','Suite',40000,2),(e1,'3','Standard',20000,2),(e1,'4','Standard',0,2);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role','authenticated')::text, true);
  o2 := public.create_organization('Org Pub 2','Autre Hotel','Bouaké'); select id into e2 from public.establishments where organization_id = o2;

  update public.establishments set slug = 'vt-' || substr(u1::text,1,8) where id = e1;
  begin update public.establishments set slug = 'vt-' || substr(u1::text,1,8) where id = e2; msg := 'ECHEC'; exception when unique_violation then msg := 'OK'; end;
  res := res || E'\n01 unicité slug: ' || msg;
  begin update public.establishments set slug = 'admin' where id = e2; msg := 'ECHEC'; exception when others then msg := 'OK'; end;
  res := res || E'\n02 slug réservé: ' || msg;
  res := res || E'\n03 non publiée invisible: ' || case when public.public_get_establishment('vt-' || substr(u1::text,1,8)) is null then 'OK' else 'ECHEC' end;
  update public.establishments set public_enabled = true, public_phone = '0102030405', address = 'ADRESSE PRIVEE', phone = 'TEL PRIVE' where id = e1;
  r := public.public_get_establishment('vt-' || substr(u1::text,1,8));
  res := res || E'\n04 publiée sans données privées: ' || case when r is not null and r::text not like '%PRIVE%' and jsonb_array_length(r->'room_types') = 2 then 'OK' else 'ECHEC' end;
  res := res || E'\n05 slug inexistant: ' || case when public.public_get_establishment('inconnu-xyz') is null then 'OK' else 'ECHEC' end;
  r := public.public_quote('vt-' || substr(u1::text,1,8), 'Suite', current_date + 2, current_date + 5, 2);
  res := res || E'\n06 calcul 3 nuits x 40000: ' || case when (r->>'total')::numeric = 120000 then 'OK' else 'ECHEC' end;
  r := public.public_quote('vt-' || substr(u1::text,1,8), 'Suite', current_date + 5, current_date + 2, 2);
  r2 := public.public_quote('vt-' || substr(u1::text,1,8), 'Suite', current_date - 3, current_date + 1, 2);
  res := res || E'\n07 dates invalides: ' || case when not (r->>'ok')::bool and not (r2->>'ok')::bool then 'OK' else 'ECHEC' end;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  r := public.public_create_booking('vt-' || substr(u1::text,1,8),'Suite', current_date + 10, current_date + 12, 2, 'Awa Koné', v_p, 'awa@exemple.ci', 'Arrivée tard');
  ref1 := r->>'reference';
  res := res || E'\n08 demande anonyme en attente: ' || case when (r->>'ok')::bool and r->>'status' = 'pending' then 'OK' else 'ECHEC' end;
  r := public.public_create_booking('vt-' || substr(u1::text,1,8),'Suite', current_date + 11, current_date + 13, 2, 'Bakary T', '0505050505');
  r2 := public.public_create_booking('vt-' || substr(u1::text,1,8),'Suite', current_date + 11, current_date + 13, 2, 'Chantal D', '0606060606');
  res := res || E'\n09 pas de double réservation: ' || case when (r->>'ok')::bool and not (r2->>'ok')::bool then 'OK' else 'ECHEC' end;
  perform public.public_create_booking('vt-' || substr(u1::text,1,8),'Standard', current_date + 20, current_date + 21, 1, 'Awa Koné', v_p);
  perform public.public_create_booking('vt-' || substr(u1::text,1,8),'Standard', current_date + 22, current_date + 23, 1, 'Awa Koné', v_p);
  r := public.public_create_booking('vt-' || substr(u1::text,1,8),'Standard', current_date + 25, current_date + 26, 1, 'Awa Koné', v_p);
  res := res || E'\n10 4e demande même numéro refusée: ' || case when not (r->>'ok')::bool then 'OK' else 'ECHEC' end;
  select count(*) into c from public.reservations;
  res := res || E'\n11 anonyme ne lit aucune réservation: ' || case when c = 0 then 'OK' else 'ECHEC' end;
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role','authenticated')::text, true);
  set local role authenticated;
  select count(*) into c from public.reservations where establishment_id = e1;
  reset role;
  res := res || E'\n12 isolation organisations: ' || case when c = 0 then 'OK' else 'ECHEC' end;

  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role','authenticated')::text, true);
  select count(*) into c from public.reservation_balances where establishment_id = e1 and source = 'en_ligne' and status = 'pending';
  res := res || E'\n13 demandes dans le planning: ' || case when c = 4 then 'OK' else 'ECHEC (' || c || ')' end;
  update public.reservations set status = 'confirmed' where public_reference = ref1;
  update public.reservations set status = 'cancelled' where public_reference = ref1;
  r := public.public_quote('vt-' || substr(u1::text,1,8),'Suite', current_date + 10, current_date + 11, 2);
  res := res || E'\n14 annulation libère la chambre: ' || case when (r->>'ok')::bool then 'OK' else 'ECHEC' end;
  update public.establishments set slug = 'vt2-' || substr(u1::text,1,8) where id = e1;
  res := res || E'\n15 ancien slug redirigé: ' || case when public.public_get_establishment('vt-' || substr(u1::text,1,8))->>'slug' = 'vt2-' || substr(u1::text,1,8) then 'OK' else 'ECHEC' end;
  update public.establishments set public_enabled = false where id = e1;
  r := public.public_create_booking('vt2-' || substr(u1::text,1,8),'Suite', current_date + 40, current_date + 41, 1, 'Test', '0808080808');
  res := res || E'\n16 page dépubliée bloque: ' || case when not (r->>'ok')::bool then 'OK' else 'ECHEC' end;
  update public.establishments set public_enabled = true where id = e1;
  update public.subscriptions set trial_end_at = now() - interval '1 minute' where organization_id = o1;
  res := res || E'\n17 abonnement expiré = hors ligne: ' || case when public.public_get_establishment('vt2-' || substr(u1::text,1,8)) is null then 'OK' else 'ECHEC' end;

  raise exception 'RESULTATS (données annulées) :%', res;
end $$;
