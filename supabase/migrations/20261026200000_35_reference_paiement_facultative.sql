-- 35 · Référence de paiement facultative (demande du propriétaire de la plateforme)
-- Le numéro de transaction Mobile Money n'est plus exigé à l'encaissement (caisse, réservation, restaurant).
-- Il reste enregistrable s'il est saisi. Aucune donnée n'est modifiée.

alter table public.cash_movements drop constraint if exists cash_movements_momo_ref;

do $$
declare f text; d text;
  rule constant text := '  if p_method in (''orange_money'',''mtn_money'',''moov_money'',''wave'') and length(trim(coalesce(p_reference, ''''))) < 4 then raise exception ''Saisissez la référence de la transaction Mobile Money.''; end if;';
begin
  foreach f in array array['public.pos_checkout_v2', 'public.pos_checkout'] loop
    for d in select pg_get_functiondef(p.oid) from pg_proc p where p.oid::regprocedure::text like replace(f, 'public.', '') || '(%' and p.pronamespace = 'public'::regnamespace loop
      if position(rule in d) > 0 then execute replace(d, rule, ''); end if;
    end loop;
  end loop;
end $$;
