-- Horus Hotel — Migration 22b : code hôtel généré automatiquement à la création d'une organisation.
create or replace function public.default_staff_code()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare base text; c text; i int := 1;
begin
  if new.staff_code is not null then return new; end if;
  base := left(regexp_replace(lower(translate(coalesce(new.name, ''), 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', 'aaaeeeeiioouuucaaaeeeeiioouuuc')), '[^a-z0-9]', '', 'g'), 16);
  if length(base) < 3 then base := 'hotel'; end if;
  c := base;
  while exists (select 1 from public.organizations where staff_code = c) loop i := i + 1; c := base || i; end loop;
  new.staff_code := c;
  return new;
end $function$;
revoke execute on function public.default_staff_code() from public, anon, authenticated;
drop trigger if exists trg_org_staff_code on public.organizations;
create trigger trg_org_staff_code before insert on public.organizations for each row execute function public.default_staff_code();
