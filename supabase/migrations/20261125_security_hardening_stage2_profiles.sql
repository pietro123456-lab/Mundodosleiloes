-- Etapa 2 de endurecimento — privilégios mínimos em profiles
-- O frontend consulta perfis e altera somente o próprio username.
-- A criação do perfil é feita pelo trigger SECURITY DEFINER em auth.users.

begin;

revoke all privileges on table public.profiles from public, anon, authenticated;

grant select on table public.profiles to authenticated;
grant update (username) on table public.profiles to authenticated;

commit;

-- Diagnóstico: deve mostrar SELECT para authenticated e nenhum privilégio
-- de tabela para anon/PUBLIC. UPDATE(username) é privilégio por coluna e
-- deve ser conferido em information_schema.column_privileges.
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'profiles'
  and grantee in ('anon', 'authenticated', 'PUBLIC')
order by grantee, privilege_type;

select grantee, column_name, privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name = 'profiles'
  and grantee in ('anon', 'authenticated', 'PUBLIC')
order by grantee, column_name, privilege_type;

-- Não altera game_state: a escrita direta do JSON continua sendo um
-- bloqueador de lançamento e será migrada em uma etapa separada.
