-- Corrige a permissao residual identificada na verificacao.
-- Remove SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER
-- e qualquer outro privilegio de tabela de anon/authenticated/PUBLIC.
revoke all privileges on table public.game_state from public, anon, authenticated;
grant select on table public.game_state to authenticated;

select grantee, privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name='game_state'
  and grantee in ('anon','authenticated','PUBLIC')
order by grantee, privilege_type;
