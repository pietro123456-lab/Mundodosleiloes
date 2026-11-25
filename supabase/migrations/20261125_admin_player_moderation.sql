-- Ferramentas seguras de moderação de jogadores para a Área ADM.
alter table public.profiles
  add column if not exists ranking_hidden boolean not null default false;

create or replace function public.admin_manage_player(
  p_target_user_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_state jsonb;
  target_role text;
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Acesso negado: somente ADM.';
  end if;

  if p_target_user_id is null or p_target_user_id = auth.uid() then
    raise exception 'Selecione outro jogador válido.';
  end if;

  select role into target_role
  from public.profiles
  where id = p_target_user_id;

  if target_role is distinct from 'player' then
    raise exception 'A conta selecionada não é um jogador comum.';
  end if;

  if p_action not in ('reset_coins', 'remove_items', 'hide_ranking') then
    raise exception 'Ação administrativa inválida.';
  end if;

  if p_action = 'hide_ranking' then
    update public.profiles
    set ranking_hidden = true
    where id = p_target_user_id;
    return jsonb_build_object('action', p_action, 'ranking_hidden', true);
  end if;

  select coalesce(state, '{}'::jsonb)
    into current_state
  from public.game_state
  where user_id = p_target_user_id
  for update;

  if not found then
    current_state := jsonb_build_object(
      'coins', 1000,
      'items', '[]'::jsonb,
      'wins', 0,
      'level', 1,
      'history', jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.')
    );
  end if;

  if p_action = 'reset_coins' then
    current_state := jsonb_set(current_state, '{coins}', '0'::jsonb, true);
    current_state := jsonb_set(
      current_state, '{history}',
      jsonb_build_array('A administração zerou o saldo desta conta.') ||
      coalesce(current_state -> 'history', '[]'::jsonb), true
    );
  elsif p_action = 'remove_items' then
    current_state := jsonb_set(current_state, '{items}', '[]'::jsonb, true);
    current_state := jsonb_set(
      current_state, '{history}',
      jsonb_build_array('A administração removeu todos os itens desta conta.') ||
      coalesce(current_state -> 'history', '[]'::jsonb), true
    );
  end if;

  insert into public.game_state(user_id, state, updated_at)
  values (p_target_user_id, current_state, now())
  on conflict (user_id) do update
    set state = excluded.state, updated_at = excluded.updated_at;

  return jsonb_build_object('action', p_action, 'state', current_state);
end;
$$;

revoke all on function public.admin_manage_player(uuid, text) from public;
grant execute on function public.admin_manage_player(uuid, text) to authenticated;

-- Atualiza o ranking para ignorar contas ocultadas pela administração.
create or replace function public.leaderboard_top_players()
returns table("position" bigint, user_id uuid, username text, coins bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'É necessário entrar na conta.';
  end if;

  return query
    select ranked."position", ranked.user_id, ranked.username, ranked.coins
    from (
      select
        row_number() over (
          order by coalesce(nullif(gs.state ->> 'coins', '')::bigint, 1000) desc,
                   lower(p.username)
        ) as position,
        p.id as user_id,
        p.username,
        coalesce(nullif(gs.state ->> 'coins', '')::bigint, 1000) as coins
      from public.profiles p
      left join public.game_state gs on gs.user_id = p.id
      where p.ranking_hidden = false
    ) as ranked
    order by ranked.position
    limit 100;
end;
$$;

revoke all on function public.leaderboard_top_players() from public;
grant execute on function public.leaderboard_top_players() to authenticated;
