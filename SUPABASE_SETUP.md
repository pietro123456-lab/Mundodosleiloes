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

## Segurança
- RLS limita leitura e escrita do progresso ao usuário autenticado.
- Não existe política para o jogador alterar `role`.
- As operações de concessão de moedas verificam a função ADM no próprio banco por funções `SECURITY DEFINER`; o navegador não pode escolher livremente o saldo de outra conta.
- A senha ADM antiga em localStorage não é autenticação segura e deve ser desativada na migração.

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
