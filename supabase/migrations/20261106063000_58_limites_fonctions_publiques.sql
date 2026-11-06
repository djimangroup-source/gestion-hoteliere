-- 58 · Sécurité : plafond de requêtes sur les fonctions publiques qui n'en avaient pas encore
-- (recherche de lieux, options d'un hôtel, dépôt d'un avis). Aucune donnée modifiée.
-- La réservation, les options de réservation, la recherche d'hôtels et la fiche hôtel étaient déjà plafonnées.
do $mig$
declare f record; d text;
begin
  for f in select * from (values
      ('public.locality_search(text,integer)', 'read:ip:', 120, '1 minute', 'raise exception ''Trop de requêtes : patientez une minute.'';'),
      ('public.market_options(text)', 'read:ip:', 120, '1 minute', 'return ''[]''::jsonb;'),
      ('public.public_review_submit(uuid,integer,text)', 'review:ip:', 10, '1 hour', 'return jsonb_build_object(''ok'', false, ''error'', ''Trop de tentatives. Réessayez plus tard.'');')
    ) as t(sig, bucket, lim, win, on_hit)
  loop
    d := pg_get_functiondef(f.sig::regprocedure);
    if position('_rate_hit' in d) > 0 then continue; end if;
    d := replace(d, E'\n STABLE ', E'\n ');
    d := regexp_replace(d, E'\\nbegin\\n', E'\nbegin\n  if public._rate_hit(''' || f.bucket || ''' || public._client_ip(), ' || f.lim || ', interval ''' || f.win || ''') then ' || f.on_hit || E' end if;\n');
    execute d;
  end loop;
end $mig$;
