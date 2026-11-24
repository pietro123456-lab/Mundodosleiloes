-- Mundo dos Leiloes: schema inicial para Supabase (PostgreSQL)
-- Execute no SQL Editor do Supabase depois de criar o projeto.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  role text not null default 'player' check (role in ('player','admin')),
  created_at timestamptz not null default now()
);
create table if not exists public.game_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
alter table public.game_state enable row level security;
drop policy if exists "profile read own" on public.profiles;
create policy "profile read own" on public.profiles for select to authenticated using (auth.uid() = id);
drop policy if exists "profile update own username only" on public.profiles;
create policy "profile update own username only" on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id and role = 'player');
drop policy if exists "state read own" on public.game_state;
create policy "state read own" on public.game_state for select to authenticated using (auth.uid() = user_id);
drop policy if exists "state insert own" on public.game_state;
create policy "state insert own" on public.game_state for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "state update own" on public.game_state;
create policy "state update own" on public.game_state for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- Não há política de escrita de role: jogador não pode se promover a admin.

-- Cria automaticamente um perfil quando uma conta é cadastrada.
-- O sufixo do ID torna o username único mesmo quando duas pessoas
-- escolhem o mesmo nome de jogador.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_username text;
  final_username text;
begin
  base_username := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Jogador'
  );
  base_username := left(regexp_replace(base_username, '[^a-zA-Z0-9_-]', '', 'g'), 32);
  if base_username = '' then
    base_username := 'Jogador';
  end if;
  final_username := base_username || '-' || left(replace(new.id::text, '-', ''), 8);

  insert into public.profiles (id, username, role)
  values (new.id, final_username, 'player')
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- RPCs administrativos: a permissão é verificada no banco, não no navegador.
-- O frontend nunca recebe permissão para alterar o saldo de outras contas diretamente.
create or replace function public.admin_list_players()
returns table(user_id uuid, username text, email text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Acesso negado: somente ADM.';
  end if;

  return query
    select u.id,
           coalesce(p.username, split_part(coalesce(u.email, ''), '@', 1), 'Jogador')::text,
           coalesce(u.email, '')::text
    from auth.users u
    left join public.profiles p on p.id = u.id
    order by lower(coalesce(p.username, u.email, ''));
end;
$$;

create or replace function public.admin_grant_coins(p_target_user_id uuid, p_amount bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_state jsonb;
  new_balance bigint;
  target_name text;
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

  new_balance := coalesce((current_state ->> 'coins')::bigint, 1000) + p_amount;
  if new_balance > 9000000000000000 then
    raise exception 'O saldo ultrapassaria o limite permitido.';
  end if;

  select coalesce(username, 'Jogador') into target_name
    from public.profiles where id = p_target_user_id;
  current_state := jsonb_set(current_state, '{coins}', to_jsonb(new_balance), true);
  current_state := jsonb_set(
    current_state,
    '{history}',
    jsonb_build_array('ADM adicionou ' || p_amount::text || ' moedas à conta.') ||
      coalesce(current_state -> 'history', '[]'::jsonb),
    true
  );

  insert into public.game_state(user_id, state, updated_at)
  values (p_target_user_id, current_state, now())
  on conflict (user_id) do update
    set state = excluded.state, updated_at = excluded.updated_at;

  return new_balance;
end;
$$;

revoke all on function public.admin_list_players() from public;
revoke all on function public.admin_grant_coins(uuid, bigint) from public;
grant execute on function public.admin_list_players() to authenticated;
grant execute on function public.admin_grant_coins(uuid, bigint) to authenticated;

