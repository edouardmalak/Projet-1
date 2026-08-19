-- =====================================================================
-- Companion helper for rls-adversarial-audit.mjs
-- Returns the authoritative live list of base tables in `public`, so the
-- audit builds its matrix from the running schema (never from memory).
-- EXECUTE-only for service_role; anon/authenticated get nothing.
-- Idempotent. Run once in Supabase > SQL Editor before the audit.
-- =====================================================================
create or replace function public.list_public_tables()
returns table(table_name text)
language sql
security definer
set search_path = public
as $$
  select c.relname::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
   order by c.relname;
$$;

revoke all on function public.list_public_tables() from public, anon, authenticated;
grant execute on function public.list_public_tables() to service_role;
