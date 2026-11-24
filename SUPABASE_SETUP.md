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
