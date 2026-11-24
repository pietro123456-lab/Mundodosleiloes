# Configuração do backend — Mundo dos Leilões

O frontend continua no GitHub Pages. O backend planejado usa Supabase Free (sem cobrança obrigatória; sujeito aos limites do plano).

## Estado desta entrega
Este repositório agora contém o esquema SQL inicial com RLS. O backend ainda NÃO está ativo e o frontend antigo ainda NÃO foi conectado. Não coloque chaves secretas no GitHub ou no navegador.

## Passos para ativar gratuitamente
1. Crie um projeto no painel do Supabase: https://supabase.com/dashboard (plano Free).
2. Abra SQL Editor, cole e execute o conteúdo de `supabase/schema.sql`.
3. Em Authentication > Providers, habilite Email. Configure confirmação de email conforme preferir.
4. Copie Project URL e a chave publicável/anon (nunca a service_role key).
5. Integre o frontend com Supabase Auth e migre o salvamento do jogo para `game_state`.
6. Promova o primeiro administrador somente por operação administrativa protegida no servidor/SQL Editor, conferindo o UUID do usuário correto. Nunca permita que o próprio usuário altere `profiles.role`.

## Segurança
- RLS limita leitura e escrita do progresso ao usuário autenticado.
- Não existe política para o jogador alterar `role`.
- A área ADM não deve ser considerada segura até que as Edge Functions/admin endpoints validem JWT e role no servidor.
- A senha ADM antiga em localStorage não é autenticação segura e deve ser desativada na migração.

## Limitação
Não é possível criar o projeto Supabase dentro da conta do usuário por este repositório. A criação do projeto e a cópia da URL/chave pública precisam ser feitas no painel do Supabase. Não compartilhe senha ou service_role key no chat.
