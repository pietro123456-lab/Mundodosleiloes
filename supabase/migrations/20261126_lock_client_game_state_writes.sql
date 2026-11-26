-- Bloqueia gravacoes diretas do JSON de progresso pelo navegador.
-- Apenas RPCs SECURITY DEFINER podem alterar o estado autoritativo.
create or replace function public.guard_game_state_client_writes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' then
    if tg_op = 'INSERT' then
      new.state := jsonb_build_object(
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
          'missionDate', ''
        ),
        'history', jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.'),
        'dailyDate', '',
        'dailyBonus', '',
        'luck', null
      );
    else
      new.state := old.state;
      new.updated_at := old.updated_at;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists game_state_client_write_guard on public.game_state;
create trigger game_state_client_write_guard
before insert or update on public.game_state
for each row execute function public.guard_game_state_client_writes();

revoke all on function public.guard_game_state_client_writes() from public, anon, authenticated;
revoke all privileges on table public.game_state from public, anon, authenticated;
grant select on table public.game_state to authenticated;

-- Verificação dos privilégios efetivos:
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema='public' and table_name='game_state'
  and grantee in ('anon','authenticated','PUBLIC')
order by grantee, privilege_type;
