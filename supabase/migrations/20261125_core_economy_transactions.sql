-- Recompensas e vendas executadas no servidor, com bloqueio transacional por jogador.
create or replace function public.game_claim_daily_bonus()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_today text := to_char(timezone('utc', now())::date, 'YYYY-MM-DD');
  v_coins bigint;
  v_xp bigint;
begin
  if v_uid is null then raise exception 'É necessário entrar na conta.'; end if;

  insert into public.game_state(user_id, state, updated_at)
  values (v_uid, jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history','[]'::jsonb), now())
  on conflict (user_id) do nothing;

  select coalesce(state, '{}'::jsonb) into v_state
  from public.game_state where user_id=v_uid for update;

  if v_state->>'dailyBonus' = v_today then
    raise exception 'Bônus diário já coletado!';
  end if;

  v_coins := greatest(0, coalesce(nullif(v_state->>'coins','')::bigint,1000)) + 250;
  v_xp := greatest(0, coalesce(nullif(v_state#>>'{progress,xp}','')::bigint,0)) + 10;

  v_state := jsonb_set(v_state,'{coins}',to_jsonb(v_coins),true);
  v_state := jsonb_set(v_state,'{dailyBonus}',to_jsonb(v_today),true);
  v_state := jsonb_set(v_state,'{progress}',jsonb_set(coalesce(v_state->'progress','{}'::jsonb),'{xp}',to_jsonb(v_xp),true),true);
  v_state := jsonb_set(v_state,'{level}',to_jsonb(greatest(1,1+(v_xp/250)::bigint)),true);
  v_state := jsonb_set(v_state,'{history}',jsonb_build_array('Bônus diário: +250 moedas e +10 XP.') || coalesce(v_state->'history','[]'::jsonb),true);

  update public.game_state set state=v_state, updated_at=now() where user_id=v_uid;
  return v_state;
end;
$$;

create or replace function public.game_sell_item(p_item_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_items jsonb;
  v_item jsonb;
  v_remaining jsonb;
  v_price numeric;
  v_gain bigint;
  v_coins bigint;
begin
  if v_uid is null then raise exception 'É necessário entrar na conta.'; end if;
  if p_item_id is null or length(p_item_id)>100 then raise exception 'Item inválido.'; end if;

  select state into v_state from public.game_state
  where user_id=v_uid for update;
  if not found then raise exception 'Progresso não encontrado.'; end if;

  v_items := coalesce(v_state->'items','[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' then raise exception 'Inventário inválido.'; end if;

  select e.value into v_item
  from jsonb_array_elements(v_items) e(value)
  where e.value->>'id'=p_item_id
  limit 1;
  if v_item is null then raise exception 'Esse item não está mais no inventário.'; end if;

  if coalesce(v_item->>'price','') !~ '^[0-9]+([.][0-9]+)?$' then
    raise exception 'O preço deste item é inválido.';
  end if;
  v_price := (v_item->>'price')::numeric;
  if v_price < 0 or v_price > 9000000000000000 then raise exception 'Preço fora do limite.'; end if;
  v_gain := floor(v_price * 0.7)::bigint;

  select coalesce(jsonb_agg(e.value),'[]'::jsonb) into v_remaining
  from jsonb_array_elements(v_items) e(value)
  where e.value->>'id' <> p_item_id;

  v_coins := greatest(0,coalesce(nullif(v_state->>'coins','')::bigint,1000)) + v_gain;
  if v_coins > 9000000000000000 then raise exception 'Saldo máximo excedido.'; end if;

  v_state := jsonb_set(v_state,'{items}',v_remaining,true);
  v_state := jsonb_set(v_state,'{coins}',to_jsonb(v_coins),true);
  v_state := jsonb_set(v_state,'{history}',jsonb_build_array('Vendeu '||coalesce(v_item->>'name','Item')||' por '||v_gain::text||' moedas.') || coalesce(v_state->'history','[]'::jsonb),true);

  update public.game_state set state=v_state, updated_at=now() where user_id=v_uid;
  return v_state;
end;
$$;

revoke all on function public.game_claim_daily_bonus() from public, anon;
revoke all on function public.game_sell_item(text) from public, anon;
grant execute on function public.game_claim_daily_bonus() to authenticated;
grant execute on function public.game_sell_item(text) to authenticated;
