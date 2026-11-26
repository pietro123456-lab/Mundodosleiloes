-- Suporta saldos grandes nas ferramentas administrativas e no ranking.
-- O saldo é lido como NUMERIC e o ranking devolve texto para preservar todos os dígitos no JSON.

drop function if exists public.admin_grant_coins(uuid,bigint);
create function public.admin_grant_coins(p_target_user_id uuid, p_amount bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_state jsonb;
  new_balance numeric;
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Acesso negado: somente ADM.';
  end if;

  if p_target_user_id is null or p_amount is null or p_amount < 1 or p_amount > 1000000000000 then
    raise exception 'Jogador ou quantidade inválida.';
  end if;

  select coalesce(state, '{}'::jsonb) into current_state
  from public.game_state where user_id = p_target_user_id for update;

  if not found then
    current_state := jsonb_build_object(
      'coins', 1000, 'items', '[]'::jsonb, 'wins', 0, 'level', 1,
      'history', jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.')
    );
  end if;

  new_balance := coalesce(nullif(current_state ->> 'coins','')::numeric,1000) + p_amount;
  if new_balance > 999999999999999999999999999999 then
    raise exception 'O saldo ultrapassaria o limite permitido.';
  end if;

  current_state := jsonb_set(current_state, '{coins}', to_jsonb(new_balance), true);
  current_state := jsonb_set(
    current_state, '{history}',
    jsonb_build_array('ADM adicionou ' || p_amount::text || ' moedas à conta.') ||
      coalesce(current_state -> 'history', '[]'::jsonb), true
  );

  insert into public.game_state(user_id,state,updated_at)
  values(p_target_user_id,current_state,now())
  on conflict(user_id) do update set state=excluded.state,updated_at=excluded.updated_at;

  return new_balance::text;
end;
$$;
revoke all on function public.admin_grant_coins(uuid,bigint) from public, anon;
grant execute on function public.admin_grant_coins(uuid,bigint) to authenticated;

drop function if exists public.leaderboard_top_players();
create function public.leaderboard_top_players()
returns table("position" bigint, user_id uuid, username text, coins text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'É necessário entrar na conta.';
  end if;

  return query
  select ranked."position",ranked.user_id,ranked.username,ranked.coins
  from (
    select row_number() over (
      order by coalesce(nullif(gs.state->>'coins','')::numeric,1000) desc,
               lower(p.username)
    ) as "position",
    p.id as user_id,p.username,
    coalesce(nullif(gs.state->>'coins','')::numeric,1000)::text as coins
    from public.profiles p
    left join public.game_state gs on gs.user_id=p.id
    where p.ranking_hidden=false
  ) ranked
  order by ranked."position"
  limit 100;
end;
$$;
revoke all on function public.leaderboard_top_players() from public, anon;
grant execute on function public.leaderboard_top_players() to authenticated;
