# Configuração do backend — Mundo dos Leilões

O frontend continua no GitHub Pages. O backend planejado usa Supabase Free (sem cobrança obrigatória; sujeito aos limites do plano).

## Estado desta entrega
Este repositório agora contém o esquema SQL inicial com RLS. O backend ainda NÃO está ativo e o frontend antigo ainda NÃO foi conectado. Não coloque chaves secretas no GitHub ou no navegador.

## Passos para ativar gratuitamente
1. Crie um projeto no painel do Supabase: https://supabase.com/dashboard (plano Free).
2. Abra SQL Editor, cole e execute o conteúdo de `supabase/schema.sql`.
3. Em Authentication > Providers, habilite Email. Configure confirmação de email conforme preferir.
4. Copie Project URL e a chave publicável/anon (nunca a service_role key).
5. O frontend já está conectado ao Supabase Auth e ao `game_state`; após atualizar o SQL, abra a Área ADM e teste a lista de jogadores.
6. Promova ou remova administradores somente pelo SQL Editor, conferindo o UUID correto. Nunca permita que o próprio usuário altere `profiles.role`.
7. O botão **Dar moedas a um jogador** usa `admin_list_players()` e `admin_grant_coins(...)`. As funções verificam `profiles.role = 'admin'` no banco antes de mostrar contas ou alterar saldo.

## Segurança — situação real antes do lançamento
- RLS limita a leitura do progresso à própria conta, mas a política atual ainda permite que o usuário grave o JSON inteiro da própria linha em `game_state`.
- Isso significa que a economia ainda não está protegida contra alterações feitas pelo console/API do navegador. Não considere moedas, XP, itens ou inventário à prova de fraude.
- A migration `supabase/migrations/20261125_security_hardening_stage1.sql` restringe a edição direta de `profiles` à coluna `username`; `role` e `ranking_hidden` deixam de ser editáveis pelo cliente.
- As funções administrativas e de leilão existentes validam operações no banco, mas não cobrem todas as alterações locais que ainda são salvas no JSON completo.
- **Não revogue INSERT/UPDATE de `game_state` isoladamente:** o frontend atual depende dessa escrita e isso pode interromper o salvamento ou causar perda de progresso.
- Para lançamento público, ainda é obrigatório migrar todas as ações econômicas para RPCs transacionais e só então retirar a escrita direta em `game_state`.
- Nunca coloque uma chave `service_role` no GitHub ou no navegador.

## Limitação
Não é possível criar o projeto Supabase dentro da conta do usuário por este repositório. A criação do projeto e a cópia da URL/chave pública precisam ser feitas no painel do Supabase. Não compartilhe senha ou service_role key no chat.


## Atualização: ranking global e renda AFK

Depois de atualizar o jogo, execute também o bloco SQL abaixo no SQL Editor do Supabase (ou execute novamente o arquivo `supabase/schema.sql` completo):

```sql
create or replace function public.leaderboard_top_players()
returns table(position bigint, user_id uuid, username text, coins bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'É necessário entrar na conta.';
  end if;
  return query
    select ranked.position, ranked.user_id, ranked.username, ranked.coins
    from (
      select row_number() over (
        order by coalesce(nullif(gs.state ->> 'coins', '')::bigint, 1000) desc,
                 lower(p.username)
      ) as position,
      p.id as user_id, p.username,
      coalesce(nullif(gs.state ->> 'coins', '')::bigint, 1000) as coins
      from public.profiles p
      left join public.game_state gs on gs.user_id = p.id
    ) ranked
    order by ranked.position
    limit 100;
end;
$$;
revoke all on function public.leaderboard_top_players() from public;
grant execute on function public.leaderboard_top_players() to authenticated;
```

A renda AFK é calculada pelo próprio jogo ao entrar novamente: soma a produção por segundo dos itens do inventário durante o tempo ausente, limitada a 12 horas. O ranking usa o saldo salvo no Supabase.


## Atualização de segurança — etapa 1
1. No Supabase, abra SQL Editor.
2. Abra o arquivo [security_hardening_stage1.sql](supabase/migrations/20261125_security_hardening_stage1.sql) no GitHub.
3. Copie e execute primeiro o bloco da migration (até `commit;`).
4. Execute separadamente as duas consultas de diagnóstico no final do arquivo e confira os resultados.

Esta etapa protege os campos de perfil, mas **não conclui a segurança da economia**. A próxima etapa deve migrar as operações do jogo para o servidor antes de bloquear a escrita direta em `game_state`.


## Atualização — transações do bônus diário e venda de itens

A migration `supabase/migrations/20261125_core_economy_transactions.sql` adiciona duas operações executadas no servidor:

- `game_claim_daily_bonus()`: concede o bônus uma única vez por dia UTC, com bloqueio da linha do jogador e atualização atômica de moedas/XP.
- `game_sell_item(p_item_id)`: confere se o item pertence ao jogador, calcula 70% do preço armazenado e remove o item e credita as moedas na mesma transação.

**Ação necessária:** execute o arquivo da migration no SQL Editor do Supabase antes de usar a versão atualizada do site. Essas duas ações já foram ligadas ao frontend. Isso é uma etapa parcial: a escrita direta em `game_state` permanece habilitada até migrar todas as demais mecânicas.


## Atualização — compatibilidade com saldos grandes

Execute também [20261125_large_balance_admin_ranking.sql](supabase/migrations/20261125_large_balance_admin_ranking.sql) no SQL Editor. Essa migration atualiza o ranking e a concessão administrativa de moedas para trabalhar com saldos maiores que BIGINT. O ranking retorna o saldo como texto para não perder dígitos no JSON.


## Atualização — recompensas de missões e conquistas

Execute [20261125_server_progress_rewards.sql](supabase/migrations/20261125_server_progress_rewards.sql) no SQL Editor. O resgate de missões e conquistas agora valida os requisitos e concede moedas/XP no servidor, com proteção contra resgate duplicado.


## Renda AFK calculada no servidor

Execute também `supabase/migrations/20261125_server_afk_income.sql` no SQL Editor do Supabase. A função `game_collect_afk_income()` usa o relógio do banco, limita o período acumulado a 12 horas, calcula a renda com base nos itens armazenados e grava o novo saldo de forma transacional. O frontend passa a consultar essa função na entrada e a cada 15 segundos. Sem essa migration, a renda AFK ficará temporariamente indisponível; não tente substituir a função por um saldo calculado no navegador.
