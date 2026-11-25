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



-- Ferramentas de transferência de itens da Área ADM.
create or replace function public.admin_list_player_items(p_target_user_id uuid)
returns table(item_id text, item_name text, item_emoji text, item_price bigint, item_rarity text)
language plpgsql
security definer
set search_path = ''
as $$
declare st jsonb;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Acesso negado: somente ADM.';
  end if;
  select coalesce(state, '{}'::jsonb) into st from public.game_state where user_id = p_target_user_id;
  return query
    select e.value ->> 'id',
           coalesce(e.value ->> 'name','Item'),
           coalesce(e.value ->> 'emoji','🎁'),
           coalesce(nullif(e.value ->> 'price','')::bigint,0),
           coalesce(e.value ->> 'rarity','Comum')
    from jsonb_array_elements(coalesce(st -> 'items','[]'::jsonb)) e(value);
end;
$$;

drop function if exists public.admin_give_catalog_item(uuid,text,text,bigint,text);
create function public.admin_give_catalog_item(
  p_target_user_id uuid, p_item_name text, p_item_emoji text, p_item_price bigint, p_item_rarity text,
  p_mutation text default 'Normal', p_mutation_multiplier numeric default 1
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare st jsonb; new_item jsonb; item_id bigint;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Acesso negado: somente ADM.';
  end if;
  if p_target_user_id is null or p_item_name is null or length(trim(p_item_name))=0
     or p_item_price is null or p_item_price < 0 or p_item_price > 9000000000000000
     or p_mutation not in ('Normal','Brilhante','Dourada','Glitch','Arco-íris','Cósmica','Celestial','ADM')
     or p_mutation_multiplier is null or p_mutation_multiplier < 1 or p_mutation_multiplier > 100000 then
    raise exception 'Jogador, item ou mutação inválida.';
  end if;
  perform 1 from public.game_state where user_id=p_target_user_id for update;
  select coalesce(state, jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history','[]'::jsonb))
    into st from public.game_state where user_id=p_target_user_id;
  if st is null then st:=jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history','[]'::jsonb); end if;
  item_id := (extract(epoch from clock_timestamp())*1000000)::bigint + floor(random()*1000)::bigint;
  new_item := jsonb_build_object('id',item_id,'name',p_item_name,'emoji',coalesce(nullif(p_item_emoji,''),'🎁'),
    'price',p_item_price,'rarity',coalesce(nullif(p_item_rarity,''),'Comum'),'mutation',p_mutation,'mutationMultiplier',p_mutation_multiplier);
  st := jsonb_set(st,'{items}',coalesce(st->'items','[]'::jsonb)||jsonb_build_array(new_item),true);
  st := jsonb_set(st,'{history}',jsonb_build_array('ADM enviou o item '||p_item_name||' ('||p_mutation||') para sua coleção.')||coalesce(st->'history','[]'::jsonb),true);
  insert into public.game_state(user_id,state,updated_at) values(p_target_user_id,st,now())
  on conflict(user_id) do update set state=excluded.state,updated_at=excluded.updated_at;
  return st;
end;
$$;
grant execute on function public.admin_give_catalog_item(uuid,text,text,bigint,text,text,numeric) to authenticated;

drop function if exists public.admin_collect_player_item(uuid,text);
create function public.admin_collect_player_item(p_target_user_id uuid,p_item_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare source_state jsonb; admin_state jsonb; picked jsonb; remaining jsonb; admin_id uuid;
begin
  admin_id:=auth.uid();
  if not exists(select 1 from public.profiles where id=admin_id and role='admin') then
    raise exception 'Acesso negado: somente ADM.';
  end if;
  if p_target_user_id is null or p_target_user_id=admin_id or p_item_id is null then
    raise exception 'Jogador ou item inválido.';
  end if;
  perform 1 from public.game_state where user_id in (p_target_user_id,admin_id) order by user_id for update;
  select coalesce(state,jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history','[]'::jsonb))
    into source_state from public.game_state where user_id=p_target_user_id;
  if source_state is null then raise exception 'O jogador ainda não tem progresso salvo.'; end if;
  select e.value into picked from jsonb_array_elements(coalesce(source_state->'items','[]'::jsonb)) as e(value)
    where e.value->>'id'=p_item_id limit 1;
  if picked is null then raise exception 'Esse item não está mais no inventário do jogador.'; end if;
  select coalesce(jsonb_agg(e.value),'[]'::jsonb) into remaining
    from jsonb_array_elements(coalesce(source_state->'items','[]'::jsonb)) as e(value)
    where e.value->>'id'<>p_item_id;
  source_state:=jsonb_set(source_state,'{items}',remaining,true);
  source_state:=jsonb_set(source_state,'{history}',jsonb_build_array('O item '||coalesce(picked->>'name','Item')||' foi transferido para o ADM.')||coalesce(source_state->'history','[]'::jsonb),true);
  select coalesce(state,jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history','[]'::jsonb))
    into admin_state from public.game_state where user_id=admin_id;
  if admin_state is null then admin_state:=jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history','[]'::jsonb); end if;
  admin_state:=jsonb_set(admin_state,'{items}',coalesce(admin_state->'items','[]'::jsonb)||jsonb_build_array(picked),true);
  admin_state:=jsonb_set(admin_state,'{history}',jsonb_build_array('Você recebeu o item '||coalesce(picked->>'name','Item')||' de um jogador.')||coalesce(admin_state->'history','[]'::jsonb),true);
  insert into public.game_state(user_id,state,updated_at) values(p_target_user_id,source_state,now())
  on conflict(user_id) do update set state=excluded.state,updated_at=excluded.updated_at;
  insert into public.game_state(user_id,state,updated_at) values(admin_id,admin_state,now())
  on conflict(user_id) do update set state=excluded.state,updated_at=excluded.updated_at;
  return jsonb_build_object('item_name',coalesce(picked->>'name','Item'),'state',admin_state);
end;
$$;

revoke all on function public.admin_list_player_items(uuid) from public;
revoke all on function public.admin_give_catalog_item(uuid,text,text,bigint,text) from public;
revoke all on function public.admin_collect_player_item(uuid,text) from public;
grant execute on function public.admin_list_player_items(uuid) to authenticated;
grant execute on function public.admin_give_catalog_item(uuid,text,text,bigint,text) to authenticated;
grant execute on function public.admin_collect_player_item(uuid,text) to authenticated;


-- Ranking global: somente usuários autenticados podem consultar.
-- A função lê os estados de todos os jogadores sem abrir acesso direto às tabelas.
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
    ) as ranked
    order by ranked.position
    limit 100;
end;
$$;

revoke all on function public.leaderboard_top_players() from public;
grant execute on function public.leaderboard_top_players() to authenticated;


-- Ferramentas de moderação de jogadores para a Área ADM.
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
