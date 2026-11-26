-- Renda AFK calculada pelo relógio do servidor.
-- Não aceita moedas/tempo calculados pelo navegador.
create or replace function public.game_collect_afk_income()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_now timestamptz := clock_timestamp();
  v_last_ms numeric;
  v_elapsed numeric := 0;
  v_rate numeric := 0;
  v_earned numeric := 0;
  v_item jsonb;
  v_rarity text;
  v_multiplier numeric;
begin
  if v_uid is null then
    raise exception 'É necessário entrar na conta.';
  end if;

  select coalesce(state, '{}'::jsonb)
    into v_state
    from public.game_state
    where user_id = v_uid
    for update;

  if not found then
    v_state := jsonb_build_object(
      'coins', 1000, 'items', '[]'::jsonb, 'wins', 0, 'level', 1,
      'history', jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.')
    );
  end if;

  if coalesce(jsonb_typeof(v_state->'items'), '') <> 'array' then
    v_state := jsonb_set(v_state, '{items}', '[]'::jsonb, true);
  end if;

  if coalesce(v_state->>'lastIncomeAt', '') ~ '^[0-9]+([.][0-9]+)?$' then
    v_last_ms := (v_state->>'lastIncomeAt')::numeric;
    v_elapsed := greatest(0, least(43200, extract(epoch from v_now) - (v_last_ms / 1000)));
  end if;

  for v_item in select value from jsonb_array_elements(v_state->'items')
  loop
    v_rarity := coalesce(v_item->>'rarity', 'Comum');
    v_multiplier := case
      when coalesce(v_item->>'mutationMultiplier','') ~ '^[0-9]+([.][0-9]+)?$'
        then greatest(1, least(100000, (v_item->>'mutationMultiplier')::numeric))
      else 1
    end;
    v_rate := v_rate + (case v_rarity
      when 'Comum' then 2
      when 'Incomum' then 8
      when 'Raro' then 35
      when 'Épico' then 120
      when 'Lendário' then 500
      when 'Mítico' then 1800
      when 'Divino' then 6500
      when 'Celestial' then 25000
      when 'Transcendente' then 100000
      when 'Secreto' then 500000
      when 'Eterno' then 2500000
      when 'Icônico' then 12000000
      when 'Primordial' then 60000000
      when 'Infinito' then 300000000
      else 0
    end) * v_multiplier;
  end loop;

  v_earned := floor(v_rate * v_elapsed);
  v_state := jsonb_set(v_state, '{coins}',
    to_jsonb(coalesce(nullif(v_state->>'coins','')::numeric, 1000) + v_earned), true);
  v_state := jsonb_set(v_state, '{lastIncomeAt}',
    to_jsonb(floor(extract(epoch from v_now) * 1000)), true);

  if v_earned > 0 then
    v_state := jsonb_set(v_state, '{history}',
      jsonb_build_array('Renda AFK: +' || v_earned::text || ' moedas.') ||
      coalesce(v_state->'history', '[]'::jsonb), true);
  end if;

  insert into public.game_state(user_id, state, updated_at)
  values (v_uid, v_state, v_now)
  on conflict (user_id) do update
    set state = excluded.state, updated_at = excluded.updated_at;

  return jsonb_build_object('state', v_state, 'earned', v_earned::text);
end;
$$;

revoke all on function public.game_collect_afk_income() from public, anon;
grant execute on function public.game_collect_afk_income() to authenticated;
