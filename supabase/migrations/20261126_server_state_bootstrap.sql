-- Cria/carrega o estado inicial sem permitir INSERT direto pelo navegador.
create or replace function public.game_get_or_create_state()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
begin
  if v_uid is null then
    raise exception 'É necessário entrar na conta.';
  end if;

  insert into public.game_state(user_id, state, updated_at)
  values (
    v_uid,
    jsonb_build_object(
      'coins', 1000,
      'items', '[]'::jsonb,
      'wins', 0,
      'level', 1,
      'marketSales', 0,
      'eventClaims', 0,
      'progress', jsonb_build_object(
        'xp', 0,
        'claimedMissions', '[]'::jsonb,
        'claimedAchievements', '[]'::jsonb,
        'missionDate', to_char(timezone('utc', now())::date, 'YYYY-MM-DD')
      ),
      'history', jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.'),
      'dailyDate', '',
      'dailyBonus', '',
      'luck', null
    ),
    now()
  )
  on conflict (user_id) do nothing;

  select state into v_state
  from public.game_state
  where user_id = v_uid;

  return v_state;
end;
$$;

revoke all on function public.game_get_or_create_state() from public, anon;
grant execute on function public.game_get_or_create_state() to authenticated;
