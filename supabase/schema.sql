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
-- Permite ao jogador alterar somente o próprio nome; campos de função e moderação
-- não podem ser alterados diretamente pelo cliente autenticado.
revoke update on table public.profiles from public, anon, authenticated;
grant update (username) on table public.profiles to authenticated;
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
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_state jsonb;
  new_balance numeric;
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

  new_balance := coalesce(nullif(current_state ->> 'coins','')::numeric, 1000) + p_amount;
  if new_balance > 999999999999999999999999999999 then
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

  return new_balance::text;
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
    select ranked."position", ranked.user_id, ranked.username, ranked.coins
    from (
      select
        row_number() over (
          order by coalesce(nullif(gs.state ->> 'coins', '')::numeric, 1000) desc,
                   lower(p.username)
        ) as position,
        p.id as user_id,
        p.username,
        coalesce(nullif(gs.state ->> 'coins', '')::numeric, 1000)::text as coins
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
    select ranked."position", ranked.user_id, ranked.username, ranked.coins
    from (
      select
        row_number() over (
          order by coalesce(nullif(gs.state ->> 'coins', '')::numeric, 1000) desc,
                   lower(p.username)
        ) as position,
        p.id as user_id,
        p.username,
        coalesce(nullif(gs.state ->> 'coins', '')::numeric, 1000)::text as coins
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


-- Recompensas e vendas executadas no servidor, com bloqueio transacional por jogador.
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
  v_coins numeric;
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

  v_coins := greatest(0, coalesce(nullif(v_state->>'coins','')::numeric,1000)) + 250;
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

  if coalesce(v_item->>'price','') !~ '^[0-9]+([.][0-9]+)?$' then
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



-- Recompensas de missões e conquistas calculadas no servidor.
create or replace function public.game_claim_progress_reward(p_kind text,p_reward_id text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_uid uuid:=auth.uid(); v_state jsonb; v_progress jsonb; v_items jsonb; v_claimed jsonb;
 v_today text:=to_char(timezone('utc',now())::date,'YYYY-MM-DD');
 v_coins numeric; v_xp numeric; v_reward numeric; v_reward_xp numeric; v_label text; v_metric numeric:=0; v_required numeric;
begin
 if v_uid is null then raise exception 'É necessário entrar na conta.'; end if;
 if p_kind not in ('mission','achievement') then raise exception 'Tipo de recompensa inválido.'; end if;
 select state into v_state from public.game_state where user_id=v_uid for update;
 if not found then raise exception 'Progresso não encontrado.'; end if;
 v_progress:=coalesce(v_state->'progress','{}'::jsonb); v_items:=coalesce(v_state->'items','[]'::jsonb);
 if jsonb_typeof(v_items)<>'array' then raise exception 'Inventário inválido.'; end if;
 if p_kind='mission' then
  if coalesce(v_progress->>'missionDate','')<>v_today then v_progress:=jsonb_set(v_progress,'{missionDate}',to_jsonb(v_today),true); v_progress:=jsonb_set(v_progress,'{claimedMissions}','[]'::jsonb,true); end if;
  v_claimed:=coalesce(v_progress->'claimedMissions','[]'::jsonb);
  case p_reward_id
   when 'open' then v_reward:=350;v_reward_xp:=25;v_required:=1;v_metric:=coalesce(nullif(v_state->>'wins','')::numeric,0);v_label:='Missão concluída: Explorador';
   when 'collect' then v_reward:=250;v_reward_xp:=20;v_required:=3;v_metric:=jsonb_array_length(v_items);v_label:='Missão concluída: Colecionador';
   when 'rare' then v_reward:=500;v_reward_xp:=35;v_required:=1;select count(*) into v_metric from jsonb_array_elements(v_items) x where coalesce(x->>'rarity','') in ('Raro','Épico','Lendário','Mítico','Divino','Celestial','Transcendente','Secreto','Eterno','Icônico','Primordial','Infinito');v_label:='Missão concluída: Olho para raridades';
   else raise exception 'Missão desconhecida.';
  end case;
 else
  v_claimed:=coalesce(v_progress->'claimedAchievements','[]'::jsonb);
  case p_reward_id
   when 'first_win' then v_reward:=300;v_reward_xp:=20;v_required:=1;v_metric:=coalesce(nullif(v_state->>'wins','')::numeric,0);v_label:='Conquista: Primeiro martelo';
   when 'wins_10' then v_reward:=2500;v_reward_xp:=100;v_required:=10;v_metric:=coalesce(nullif(v_state->>'wins','')::numeric,0);v_label:='Conquista: Leiloeiro experiente';
   when 'items_10' then v_reward:=1200;v_reward_xp:=60;v_required:=10;v_metric:=jsonb_array_length(v_items);v_label:='Conquista: Coleção em crescimento';
   when 'items_50' then v_reward:=8000;v_reward_xp:=250;v_required:=50;v_metric:=jsonb_array_length(v_items);v_label:='Conquista: Grande colecionador';
   when 'mutations_3' then v_reward:=3000;v_reward_xp:=120;v_required:=3;select count(distinct coalesce(x->>'mutation','Normal')) into v_metric from jsonb_array_elements(v_items) x;v_label:='Conquista: Caçador de mutações';
   when 'rarity_divine' then v_reward:=5000;v_reward_xp:=180;v_required:=1;select count(*) into v_metric from jsonb_array_elements(v_items) x where coalesce(x->>'rarity','') in ('Divino','Celestial','Transcendente','Secreto','Eterno','Icônico','Primordial','Infinito');v_label:='Conquista: Toque divino';
   when 'market_sale' then v_reward:=1200;v_reward_xp:=60;v_required:=1;v_metric:=coalesce(nullif(v_state->>'marketSales','')::numeric,0);v_label:='Conquista: Mercador do Reino';
   when 'event_claim' then v_reward:=1500;v_reward_xp:=70;v_required:=1;v_metric:=coalesce(nullif(v_state->>'eventClaims','')::numeric,0);v_label:='Conquista: Presença no Festival';
   when 'level_10' then v_reward:=10000;v_reward_xp:=300;v_required:=10;v_metric:=coalesce(nullif(v_state->>'level','')::numeric,1);v_label:='Conquista: Lenda do Reino';
   else raise exception 'Conquista desconhecida.';
  end case;
 end if;
 if v_claimed @> jsonb_build_array(p_reward_id) then raise exception 'Esta recompensa já foi resgatada.'; end if;
 if v_metric<v_required then raise exception 'Você ainda não concluiu este objetivo.'; end if;
 v_coins:=coalesce(nullif(v_state->>'coins','')::numeric,1000)+v_reward;
 if v_coins>999999999999999999999999999999 then raise exception 'Saldo máximo excedido.'; end if;
 v_xp:=coalesce(nullif(v_progress->>'xp','')::numeric,0)+v_reward_xp;
 v_claimed:=v_claimed||jsonb_build_array(p_reward_id);
 if p_kind='mission' then v_progress:=jsonb_set(v_progress,'{claimedMissions}',v_claimed,true); else v_progress:=jsonb_set(v_progress,'{claimedAchievements}',v_claimed,true); end if;
 v_progress:=jsonb_set(v_progress,'{xp}',to_jsonb(v_xp),true);
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins),true);v_state:=jsonb_set(v_state,'{progress}',v_progress,true);
 v_state:=jsonb_set(v_state,'{level}',to_jsonb(greatest(1,1+floor(v_xp/250)::bigint)),true);
 v_state:=jsonb_set(v_state,'{history}',jsonb_build_array(v_label||' · +'||v_reward::text||' moedas · +'||v_reward_xp::text||' XP')||coalesce(v_state->'history','[]'::jsonb),true);
 update public.game_state set state=v_state,updated_at=now() where user_id=v_uid; return v_state;
end; $$;
revoke all on function public.game_claim_progress_reward(text,text) from public,anon;
grant execute on function public.game_claim_progress_reward(text,text) to authenticated;


-- Renda AFK calculada pelo relógio do servidor.
create or replace function public.game_collect_afk_income()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_state jsonb; v_now timestamptz := clock_timestamp();
  v_last_ms numeric; v_elapsed numeric := 0; v_rate numeric := 0; v_earned numeric := 0;
  v_item jsonb; v_rarity text; v_multiplier numeric;
begin
  if v_uid is null then raise exception 'É necessário entrar na conta.'; end if;
  select coalesce(state,'{}'::jsonb) into v_state from public.game_state where user_id=v_uid for update;
  if not found then v_state:=jsonb_build_object('coins',1000,'items','[]'::jsonb,'wins',0,'level',1,'history',jsonb_build_array('Bem-vindo! Você recebeu 1.000 moedas iniciais.')); end if;
  if coalesce(jsonb_typeof(v_state->'items'),'')<>'array' then v_state:=jsonb_set(v_state,'{items}','[]'::jsonb,true); end if;
  if coalesce(v_state->>'lastIncomeAt','') ~ '^[0-9]+([.][0-9]+)?$' then
    v_last_ms:=(v_state->>'lastIncomeAt')::numeric;
    v_elapsed:=greatest(0,least(43200,extract(epoch from v_now)-(v_last_ms/1000)));
  end if;
  for v_item in select value from jsonb_array_elements(v_state->'items') loop
    v_rarity:=coalesce(v_item->>'rarity','Comum');
    v_multiplier:=case when coalesce(v_item->>'mutationMultiplier','') ~ '^[0-9]+([.][0-9]+)?$' then greatest(1,least(100000,(v_item->>'mutationMultiplier')::numeric)) else 1 end;
    v_rate:=v_rate+(case v_rarity when 'Comum' then 2 when 'Incomum' then 8 when 'Raro' then 35 when 'Épico' then 120 when 'Lendário' then 500 when 'Mítico' then 1800 when 'Divino' then 6500 when 'Celestial' then 25000 when 'Transcendente' then 100000 when 'Secreto' then 500000 when 'Eterno' then 2500000 when 'Icônico' then 12000000 when 'Primordial' then 60000000 when 'Infinito' then 300000000 else 0 end)*v_multiplier;
  end loop;
  v_earned:=floor(v_rate*v_elapsed);
  v_state:=jsonb_set(v_state,'{coins}',to_jsonb(coalesce(nullif(v_state->>'coins','')::numeric,1000)+v_earned),true);
  v_state:=jsonb_set(v_state,'{lastIncomeAt}',to_jsonb(floor(extract(epoch from v_now)*1000)),true);
  if v_earned>0 then v_state:=jsonb_set(v_state,'{history}',jsonb_build_array('Renda AFK: +'||v_earned::text||' moedas.')||coalesce(v_state->'history','[]'::jsonb),true); end if;
  insert into public.game_state(user_id,state,updated_at) values(v_uid,v_state,v_now) on conflict(user_id) do update set state=excluded.state,updated_at=excluded.updated_at;
  return jsonb_build_object('state',v_state,'earned',v_earned::text);
end; $$;
revoke all on function public.game_collect_afk_income() from public,anon;
grant execute on function public.game_collect_afk_income() to authenticated;
