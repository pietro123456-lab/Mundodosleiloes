# Servidor central — Mundo dos Leilões (base inicial)

Este é um **backend separado** da página estática do GitHub Pages. A criação dos arquivos não significa que esteja hospedado, configurado ou conectado ao jogo.

## Stack
- Node.js + Express
- PostgreSQL
- JWT (sessões)
- bcrypt (hash de senha)

## Configuração
1. Crie um PostgreSQL gerenciado (por exemplo, Supabase/Neon) e copie a connection string.
2. Execute `sql/schema.sql` no banco.
3. Copie `.env.example` para `.env`, configure `DATABASE_URL` e gere `JWT_SECRET` aleatório de pelo menos 32 caracteres. Nunca publique `.env`.
4. Configure o primeiro administrador no banco de forma segura (não há bootstrap automático de admin nesta versão).
5. Instale dependências: `npm install`.
6. Execute: `npm start`.
7. Configure `CORS_ORIGIN` para o endereço do jogo antes de expor o servidor.

## Endpoints iniciais
- `GET /health`
- `POST /auth/register` {username,password}
- `POST /auth/login` {username,password}
- `GET /me` (Bearer token)
- `GET /inventory`
- `POST /luck/buy` {multiplier}
- `POST /chests/open` {cost}
- `POST /admin/luck/player` {playerId,multiplier,minutes}
- `POST /admin/luck/global` {multiplier,minutes}
- `POST /admin/coins` {playerId,amount}
- `GET /auctions`
- `POST /auctions` {itemName,rarity,startingBid,durationMinutes}
- `POST /auctions/:id/bid` {amount}

## Estado e limitações desta primeira base
- A API usa PostgreSQL central, mas ainda precisa ser hospedada e configurada.
- O frontend atual de `index.html` **não está integrado** a esta API.
- A abertura de baús usa uma tabela simplificada de itens e custos recebidos; integre com a economia e catálogo real do jogo antes do lançamento.
- O sistema de leilões é uma base de lances; ainda falta liquidação/entrega do item quando o leilão encerra.
- Não disponibilize o banco diretamente ao navegador. A API deve ser o único caminho de escrita.
