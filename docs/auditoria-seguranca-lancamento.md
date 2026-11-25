# Auditoria de segurança — Mundo dos Leilões

Data da revisão: 25/11/2026

## Escopo revisado
- `index.html` (cliente web)
- `supabase/admin_moderation.sql`
- `supabase/migrations/20261125_admin_player_moderation.sql`

Esta revisão é estática: não houve acesso de execução ao projeto Supabase nem teste em navegador. Portanto, não representa certificação de segurança.

## Pontos positivos observados
- A autenticação usa Supabase Auth.
- A interface consulta o perfil para exibir a área ADM.
- A função `admin_manage_player` valida a permissão ADM no banco, impede auto-moderação e restringe o alvo a contas comuns.
- A tabela de snapshots de moderação tem RLS habilitado e acesso direto revogado para os papéis públicos.
- O ranking usa uma função no servidor e filtra contas ocultadas.
- O cliente não contém uma chave service_role; a chave publishable é apropriada para uso no navegador quando as políticas RLS estão corretas.

## Bloqueador crítico antes do lançamento
O cliente carrega o JSON completo de `game_state`, altera moedas/itens no navegador e grava o estado inteiro com `upsert` diretamente na tabela. Isso significa que, mesmo que a política RLS limite cada pessoa à própria linha, a pessoa ainda pode tentar alterar os próprios valores de jogo por chamadas diretas à API ou pelo console do navegador.

**Conclusão:** a RLS de propriedade da linha, sozinha, não protege a economia do jogo. A autoridade sobre moedas, itens, lances, recompensas e transferências precisa ficar no banco, por meio de funções RPC transacionais que validem cada operação. O cliente não deve poder enviar um JSON arbitrário com o saldo e o inventário finais.

## Próximas correções obrigatórias
1. Revisar as políticas RLS reais de `profiles`, `game_state`, mercado, leilões e tabelas relacionadas.
2. Migrar operações econômicas para RPCs seguras: abrir baú, vender item, receber renda AFK, bônus diário, comprar/anunciar item, dar lance, encerrar leilão e reivindicar recompensas.
3. Revogar escrita direta do cliente em campos/linhas de estado econômico depois que todas as operações estiverem cobertas pelas RPCs.
4. Garantir transações e bloqueios de linha para impedir saldo negativo, gasto duplicado, item duplicado e lances concorrentes.
5. Adicionar limites de frequência e validação de valores no servidor.
6. Testar com duas contas simultâneas, duas sessões da mesma conta, falhas de rede e tentativas de chamadas não autorizadas.
7. Confirmar backup e procedimento de restauração antes de abrir o jogo ao público.

## Não alterar nesta etapa
Não foi aplicada uma restrição nova de escrita em `game_state`, porque isso poderia bloquear o salvamento atual e causar perda de progresso antes de migrar todas as ações para RPCs. A mudança deve ser feita junto com a migração completa da economia, não isoladamente.

## Resultado desta etapa
Auditoria inicial concluída e bloqueador documentado. O jogo ainda não deve ser declarado pronto para lançamento até que a economia seja validada no servidor e as políticas RLS sejam revisadas e testadas.
