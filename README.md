# Mundo dos Leilões

Jogo de leilões fictícios feito em HTML, CSS e JavaScript.

## Como jogar
- Abra `index.html` no navegador.
- Use moedas virtuais para arrematar itens.
- Veja sua coleção, venda itens de volta por moedas virtuais e crie novos leilões.
- O progresso fica salvo no armazenamento local do navegador.

> Simulação: não há dinheiro real, pagamentos ou compras.


## Atualização: economia social

A interface agora inclui:
- Mercado entre jogadores, com anúncios, compra e retirada de itens.
- Leilão mundial semanal, compartilhado entre contas.
- Eventos semanais com mutações em destaque e recompensa resgatável.
- Barra de XP e conquistas adicionais.

### Ativar os recursos no Supabase

1. Abra o SQL Editor do projeto Supabase.
2. Abra o arquivo `supabase/migrations/20261125_social_economy.sql` deste repositório.
3. Copie todo o conteúdo e execute uma vez no SQL Editor.
4. Aguarde a mensagem de sucesso e recarregue o jogo.

Todos os valores são moedas fictícias. O mercado aplica uma taxa de 5% sobre as vendas.
