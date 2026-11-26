-- Impede transformar itens personalizados em moedas por venda.
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
  v_coins numeric;
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

  if coalesce(v_item->>'rarity','') = 'Personalizado' then
    raise exception 'Itens personalizados não podem ser vendidos por moedas.';
  end if;

  if coalesce(v_item->>'price','') !~ '^[0-9]+([.][0-9]+)?
    raise exception 'O preço deste item é inválido.';
  end if;
  v_price := (v_item->>'price')::numeric;
  if v_price < 0 or v_price > 9000000000000000 then raise exception 'Preço fora do limite.'; end if;
  v_gain := floor(v_price * 0.7)::bigint;

  select coalesce(jsonb_agg(e.value),'[]'::jsonb) into v_remaining
  from jsonb_array_elements(v_items) e(value)
  where e.value->>'id' <> p_item_id;

  v_coins := greatest(0,coalesce(nullif(v_state->>'coins','')::numeric,1000)) + v_gain;
  if v_coins > 999999999999999999999999999999 then raise exception 'Saldo máximo excedido.'; end if;

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
 then
    raise exception 'O preço deste item é inválido.';
  end if;
  v_price := (v_item->>'price')::numeric;
  if v_price < 0 or v_price > 9000000000000000 then raise exception 'Preço fora do limite.'; end if;
  v_gain := floor(v_price * 0.7)::bigint;

  select coalesce(jsonb_agg(e.value),'[]'::jsonb) into v_remaining
  from jsonb_array_elements(v_items) e(value)
  where e.value->>'id' <> p_item_id;

  v_coins := greatest(0,coalesce(nullif(v_state->>'coins','')::numeric,1000)) + v_gain;
  if v_coins > 999999999999999999999999999999 then raise exception 'Saldo máximo excedido.'; end if;

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
