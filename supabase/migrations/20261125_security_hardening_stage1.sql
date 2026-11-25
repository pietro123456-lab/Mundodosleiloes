-- Etapa 1 de endurecimento de segurança — Mundo dos Leilões
-- Seguro para aplicar sem interromper o salvamento atual do jogo.
-- Esta migration NÃO fecha game_state: o frontend ainda depende da escrita direta
-- e revogá-la agora quebraria o progresso. Isso será feito somente após migrar
-- todas as ações do cliente para RPCs transacionais no servidor.

begin;

-- Jogadores podem editar somente o próprio username.
-- role e ranking_hidden ficam fora do alcance de UPDATE direto pelo cliente.
revoke update on table public.profiles from public, anon, authenticated;
grant update (username) on table public.profiles to authenticated;

-- Reforça RLS caso o projeto tenha sido criado com uma configuração parcial.
alter table public.profiles enable row level security;
alter table public.game_state enable row level security;

commit;

-- DIAGNÓSTICO (execute separadamente depois da migration):
-- 1) Deve retornar apenas username para authenticated em profiles.
select grantee, privilege_type, column_name
from information_schema.column_privileges
where table_schema='public'
  and table_name='profiles'
  and grantee in ('anon','authenticated','PUBLIC')
order by grantee, column_name, privilege_type;

-- 2) Mostra as policies ativas; confira especialmente state insert own/state update own.
select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname='public'
  and tablename in ('profiles','game_state')
order by tablename, policyname;

-- IMPORTANTE:
-- game_state ainda permite que o próprio usuário grave o JSON inteiro.
-- Isso é um bloqueador de lançamento: moedas, itens, XP e inventário precisam
-- ser alterados por RPCs validadas no banco antes de revogar INSERT/UPDATE.
