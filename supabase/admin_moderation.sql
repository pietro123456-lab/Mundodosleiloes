-- Migração independente: moderação administrativa de jogadores.
-- Execute este arquivo inteiro no Supabase SQL Editor.
-- Backup e restauração das ações de moderação da Área ADM.
alter table public.profiles
  add column if not exists ranking_hidden boolean not null default false;

create table if not exists public.admin_player_moderation_snapshots (
  id bigint generated always as identity primary key,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action in ('reset_coins','remove_items','hide_ranking')),
  snapshot_value jsonb not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  restored_at timestamptz
);
alter table public.admin_player_moderation_snapshots enable row level security;
revoke all on public.admin_player_moderation_snapshots from public, anon, authenticated;

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
  saved_value jsonb;
  snapshot_id bigint;
  hidden_before boolean;
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

  select role, ranking_hidden into target_role, hidden_before
  from public.profiles
  where id = p_target_user_id
  for update;

  if target_role is distinct from 'player' then
    raise exception 'A conta selecionada não é um jogador comum.';
  end if;

  if p_action not in ('reset_coins','remove_items','hide_ranking','restore_coins','restore_items','restore_ranking') then
    raise exception 'Ação administrativa inválida.';
  end if;

  if p_action = 'hide_ranking' then
    if not hidden_before and not exists (
      select 1 from public.admin_player_moderation_snapshots
      where target_user_id = p_target_user_id and action = 'hide_ranking' and restored_at is null
    ) then
      insert into public.admin_player_moderation_snapshots(target_user_id,action,snapshot_value,created_by)
      values (p_target_user_id,'hide_ranking',to_jsonb(hidden_before),auth.uid());
    end if;
    update public.profiles set ranking_hidden = true where id = p_target_user_id;
    return jsonb_build_object('action',p_action,'ranking_hidden',true);
  end if;

  if p_action = 'restore_ranking' then
    select id,snapshot_value into snapshot_id,saved_value
    from public.admin_player_moderation_snapshots
    where target_user_id=p_target_user_id and action='hide_ranking' and restored_at is null
    order by created_at desc,id desc limit 1 for update;
    if snapshot_id is null then raise exception 'Não existe backup de ranking para restaurar.'; end if;
    update public.profiles set ranking_hidden=(saved_value #>> '{}')::boolean where id=p_target_user_id;
    update public.admin_player_moderation_snapshots set restored_at=now() where id=snapshot_id;
    return jsonb_build_object('action',p_action,'ranking_hidden',(saved_value #>> '{}')::boolean);
  end if;

  select coalesce(state,'{}'::jsonb) into current_state
  from public.game_state where user_id=p_target_user_id for update;
  if not found then
    current_state:=jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history',jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.'));
  end if;

  if p_action = 'reset_coins' then
    if not exists (select 1 from public.admin_player_moderation_snapshots where target_user_id=p_target_user_id and action='reset_coins' and restored_at is null) then
      insert into public.admin_player_moderation_snapshots(target_user_id,action,snapshot_value,created_by)
      values(p_target_user_id,'reset_coins',coalesce(current_state->'coins','1000'::jsonb),auth.uid());
    end if;
    current_state:=jsonb_set(current_state,'{coins}','0'::jsonb,true);
    current_state:=jsonb_set(current_state,'{history}',jsonb_build_array('A administração zerou o saldo desta conta.')||coalesce(current_state->'history','[]'::jsonb),true);
  elsif p_action = 'remove_items' then
    if not exists (select 1 from public.admin_player_moderation_snapshots where target_user_id=p_target_user_id and action='remove_items' and restored_at is null) then
      insert into public.admin_player_moderation_snapshots(target_user_id,action,snapshot_value,created_by)
      values(p_target_user_id,'remove_items',coalesce(current_state->'items','[]'::jsonb),auth.uid());
    end if;
    current_state:=jsonb_set(current_state,'{items}','[]'::jsonb,true);
    current_state:=jsonb_set(current_state,'{history}',jsonb_build_array('A administração removeu todos os itens desta conta.')||coalesce(current_state->'history','[]'::jsonb),true);
  elsif p_action = 'restore_coins' then
    select id,snapshot_value into snapshot_id,saved_value
    from public.admin_player_moderation_snapshots
    where target_user_id=p_target_user_id and action='reset_coins' and restored_at is null
    order by created_at desc,id desc limit 1 for update;
    if snapshot_id is null then raise exception 'Não existe backup de dinheiro para restaurar.'; end if;
    current_state:=jsonb_set(current_state,'{coins}',saved_value,true);
    current_state:=jsonb_set(current_state,'{history}',jsonb_build_array('A administração restaurou o saldo anterior.')||coalesce(current_state->'history','[]'::jsonb),true);
    update public.admin_player_moderation_snapshots set restored_at=now() where id=snapshot_id;
  elsif p_action = 'restore_items' then
    select id,snapshot_value into snapshot_id,saved_value
    from public.admin_player_moderation_snapshots
    where target_user_id=p_target_user_id and action='remove_items' and restored_at is null
    order by created_at desc,id desc limit 1 for update;
    if snapshot_id is null then raise exception 'Não existe backup de itens para restaurar.'; end if;
    current_state:=jsonb_set(current_state,'{items}',saved_value,true);
    current_state:=jsonb_set(current_state,'{history}',jsonb_build_array('A administração restaurou os itens anteriores.')||coalesce(current_state->'history','[]'::jsonb),true);
    update public.admin_player_moderation_snapshots set restored_at=now() where id=snapshot_id;
  end if;

  insert into public.game_state(user_id,state,updated_at)
  values(p_target_user_id,current_state,now())
  on conflict(user_id) do update set state=excluded.state,updated_at=excluded.updated_at;

  return jsonb_build_object('action',p_action,'state',current_state);
end;
$$;

revoke all on function public.admin_manage_player(uuid,text) from public;
grant execute on function public.admin_manage_player(uuid,text) to authenticated;

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
