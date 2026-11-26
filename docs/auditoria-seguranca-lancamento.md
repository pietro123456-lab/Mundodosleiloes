# Auditoria de segurança — Mundo dos Leilões

Data da revisão: 25/11/2026

## Resultado geral

<ins>Não está pronto para lançamento público.</ins> A revisão estática encontrou um bloqueador na economia: o frontend ainda salva o JSON completo do jogador diretamente em `public.game_state`. RLS limita a linha à própria conta, mas não impede que o próprio usuário envie um saldo ou inventário adulterado.

Esta revisão foi feita lendo o código e os SQLs do repositório. Não houve acesso ao painel Supabase, execução de consultas no projeto real, teste de navegador ou teste de concorrência. Portanto, não é certificação nem prova de que a configuração ativa corresponde aos arquivos versionados.

## Melhorias aplicadas no repositório

1. `supabase/schema.sql`: restringe a permissão de UPDATE em `profiles` à coluna `username` para usuários autenticados.
2. `supabase/migrations/20261125_security_hardening_stage1.sql`: migration segura e idempotente para aplicar a mesma restrição no projeto existente, além de consultas de diagnóstico.
3. `SUPABASE_SETUP.md`: atualiza as instruções e deixa explícito o bloqueador restante.
4. `index.html`: evita que uma atualização recebida pelo Realtime substitua alterações locais que ainda estão aguardando sincronização.

A migration da etapa 1 não altera saldos, inventários, contas ou linhas de `game_state`.

## Proteções já presentes no código

- Supabase Auth identifica a conta.
- A tabela `profiles` possui RLS.
- As funções administrativas verificam `profiles.role = 'admin'` no banco.
- A função de moderação impede que um ADM modifique a própria conta e restringe o alvo a jogadores comuns.
- A tabela de snapshots de moderação tem RLS habilitado e acesso direto revogado para os papéis públicos.
- Funções de mercado e leilões fazem operações no banco e usam bloqueios de linha em partes importantes do fluxo.
- A chave encontrada no frontend é publishable, não uma chave `service_role`.

## Bloqueador crítico ainda aberto

O cliente executa `upsert` direto em `game_state` com o objeto completo `data`. A política de UPDATE permite que cada usuário atualize sua própria linha. Assim, uma chamada autenticada direta pode tentar mudar moedas, itens, nível, XP e outros campos, sem passar pelas regras de negócio do jogo.

**Não é seguro simplesmente revogar INSERT/UPDATE em `game_state` agora.** O frontend atual depende dessa gravação para persistir várias mecânicas; revogar sem substituir todas elas pode interromper o jogo e causar perda de progresso.

## Trabalho obrigatório para concluir a Parte 1

- [ ] Mapear cada ação que altera estado: abertura de baús, renda AFK, bônus diário, missões, conquistas, XP, inventário, venda, cofre, mascotes, eventos, baú global, leilões e ações ADM.
- [ ] Criar RPC transacional no banco para cada ação econômica, calculando o resultado no servidor; não aceitar do cliente o saldo ou inventário final.
- [ ] Migrar o frontend para chamar essas RPCs e atualizar a interface com o estado retornado.
- [ ] Adicionar validação de limites, propriedade de item, preços, duração, saldo, idempotência e concorrência.
- [ ] Só depois revogar INSERT/UPDATE direto em `game_state`.
- [ ] Auditar grants e RLS de todas as tabelas adicionais.
- [ ] Testar duas contas simultâneas, múltiplas sessões, repetição de requisições, falhas de rede e chamadas sem autorização.
- [ ] Confirmar backup e procedimento de restauração antes de abrir o jogo ao público.

## O que falta executar no Supabase

A migration da etapa 1 foi adicionada ao GitHub, mas não foi executada no projeto Supabase porque não tenho acesso ao painel da conta. O responsável pelo projeto deve executá-la no SQL Editor e conferir as consultas de diagnóstico no próprio arquivo.

## Critério de conclusão

A Parte 1 só poderá ser marcada como concluída quando as operações econômicas estiverem validadas no servidor, a escrita arbitrária em `game_state` estiver bloqueada sem quebrar funcionalidades, as policies/grants tiverem sido auditadas no projeto ativo e os testes de abuso/concorrência tiverem passado.


## Atualização da revisão — 25/11/2026

Foi adicionada a migration `20261125_core_economy_transactions.sql` e o frontend passou a chamar RPCs transacionais para bônus diário e venda de itens. O schema completo também inclui essas funções.

Isso reduz a confiança no cliente para essas duas operações, mas **não fecha o bloqueador crítico**: outras mecânicas ainda alteram o JSON local e o `syncNow()` ainda faz `upsert` direto da linha inteira de `game_state`. Portanto, a auditoria continua com resultado **não pronto para lançamento público**. A migration precisa ser executada no Supabase e as demais ações econômicas ainda precisam ser migradas e testadas antes de revogar escrita direta.


## Atualização — saldos grandes no ranking e ADM

Foi criada a migration `20261125_large_balance_admin_ranking.sql`. Ela troca os casts de saldo do ranking para NUMERIC e devolve o saldo como texto, evitando overflow de BIGINT e preservando os dígitos no retorno JSON. A função administrativa de concessão de moedas também passa a calcular com NUMERIC e retornar texto. O frontend formata o saldo do ranking com BigInt.

A migration ainda precisa ser executada no projeto Supabase. Esta alteração não elimina a vulnerabilidade de escrita direta em `game_state`; a auditoria geral continua **não pronta para lançamento público**.


## Atualização — recompensas de missões e conquistas

Foi adicionada a RPC `game_claim_progress_reward(p_kind,p_reward_id)` na migration `20261125_server_progress_rewards.sql`. Ela calcula os requisitos usando o estado armazenado, fixa valores de recompensa no servidor, bloqueia a linha do jogador e impede resgates duplicados. O frontend agora chama essa RPC para missões e conquistas.

A migration precisa ser executada no Supabase. O progresso geral ainda depende de gravação direta do JSON em `game_state`; portanto a economia como um todo continua sem proteção completa contra adulteração e não está pronta para lançamento público.


## Atualização — renda AFK

Foi adicionada a RPC `game_collect_afk_income()` na migration `20261125_server_afk_income.sql`. O cálculo do tempo usa o relógio do banco, limita o acúmulo a 12 horas, calcula a taxa com base nos itens da linha bloqueada e grava o resultado em uma transação. O frontend chama a RPC ao entrar e a cada 15 segundos, em vez de creditar moedas pelo relógio local. A migration ainda precisa ser executada no Supabase. Como a escrita direta em `game_state` continua liberada para o cliente e outras operações (especialmente abertura de baús/leilões contra bots e compras de sorte) ainda são locais, isso não fecha o bloqueador de adulteração nem autoriza lançamento público.


## Atualização — compra de sorte
A compra de multiplicadores agora usa `game_buy_luck(integer)`, que valida a lista permitida, determina o preço no servidor, bloqueia a linha do jogador e atualiza saldo e expiração em uma transação. Isso remove a confiança no preço e no relógio enviados pelo navegador para essa operação. A proteção geral ainda está incompleta enquanto `game_state` aceitar gravação direta e outras ações locais não forem migradas.


## Atualização — venda de itens personalizados
A RPC `game_sell_item` agora rejeita itens com raridade `Personalizado`, impedindo que o preço escolhido pelo cliente para itens criados localmente seja convertido em moedas pelo servidor. Isso reduz uma via direta de inflação, mas não substitui a migração de criação de itens e o bloqueio de escrita direta em `game_state`.


## Atualização — abertura de baús
A RPC `game_open_chest(text)` valida baú/preço/saldo, controla a abertura grátis diária por data UTC, aplica o multiplicador de sorte ativo e sorteia item/raridade/mutação no banco, atualizando o estado sob bloqueio de linha. A interface inicia a simulação do leilão com o item retornado. O encerramento do leilão fictício e os lances contra bots ainda são processados no navegador, e `game_state` ainda aceita gravação direta; portanto, esta etapa não elimina a possibilidade de adulteração dessas partes.


## Atualização — validação de leilões de baús
A migration `20261126_server_auction_validation.sql` cria `game_auctions` sem acesso direto do cliente e adiciona RPCs autenticadas para atualizar o relógio/lances do bot, registrar lance do jogador e encerrar a disputa. O banco verifica propriedade, estado, prazo, liderança do bot, incremento mínimo e saldo; reserva o lance, reembolsa quando o bot supera e só entrega item/XP no encerramento validado. A UI apenas apresenta os dados retornados pelo servidor. Observação: a tabela `game_state` ainda permite escrita direta, então outras partes do jogo continuam exigindo migração antes de uma declaração de segurança global.


## Atualização — bloqueio de gravações diretas em game_state
Foi adicionada a migration `20261126_lock_client_game_state_writes.sql`. Ela revoga INSERT/UPDATE de `authenticated` em `game_state` e inclui trigger de defesa em profundidade que impede alteração do estado por sessões autenticadas. As funções `SECURITY DEFINER` do jogo continuam sendo o caminho de escrita. O frontend foi ajustado para não fazer mais upsert do JSON completo. A migration ainda precisa ser executada no Supabase e os fluxos do jogo precisam ser testados após a mudança; não há certificação de lançamento neste momento.


## Correção adicional de privilégios residuais
A primeira consulta pós-migration mostrou que permaneciam privilégios DELETE, REFERENCES, TRIGGER e TRUNCATE em `game_state`. Foi publicada a migration corretiva `20261126_revoke_all_game_state_client_privileges.sql`, que executa REVOKE ALL PRIVILEGES para PUBLIC, anon e authenticated, e concede apenas SELECT a authenticated. A verificação esperada é uma única linha: authenticated / SELECT. A correção ainda precisa ser executada e conferida no banco real.


## Atualização — estado inicial e recarga autoritativa
Foi adicionada a RPC `game_get_or_create_state()` para inicializar o estado padrão dentro do Supabase, sem INSERT direto pelo navegador. O frontend não usa mais o estado econômico do localStorage como fallback de login e a ação de sincronizar consulta o servidor. O cache local é apenas visual. A migration precisa ser executada no projeto Supabase e o fluxo de login/primeira conta/conta existente deve ser testado.
