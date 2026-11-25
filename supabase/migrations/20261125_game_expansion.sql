-- Sistemas adicionais do Mundo dos Leilões
-- Execute uma vez no SQL Editor do Supabase.

create extension if not exists pgcrypto;

-- Cofre: saldo separado das moedas disponíveis.
create table if not exists public.player_vaults(
 user_id uuid primary key references auth.users(id) on delete cascade,
 balance bigint not null default 0 check(balance>=0),
 updated_at timestamptz not null default now()
);
alter table public.player_vaults enable row level security;

create or replace function public.vault_state()
returns bigint language plpgsql security definer set search_path=''
as $$
declare v bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 insert into public.player_vaults(user_id) values(auth.uid()) on conflict do nothing;
 select balance into v from public.player_vaults where user_id=auth.uid();
 return v;
end; $$;

create or replace function public.vault_move(p_amount bigint,p_deposit boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare st jsonb; v bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_amount is null or p_amount<1 then raise exception 'Quantidade inválida.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Estado do jogador não encontrado.'; end if;
 insert into public.player_vaults(user_id) values(auth.uid()) on conflict do nothing;
 select balance into v from public.player_vaults where user_id=auth.uid() for update;
 if p_deposit then
  if coalesce((st->>'coins')::bigint,0)<p_amount then raise exception 'Moedas insuficientes.'; end if;
  st:=jsonb_set(st,'{coins}',to_jsonb((st->>'coins')::bigint-p_amount),true); v:=v+p_amount;
 else
  if v<p_amount then raise exception 'Saldo insuficiente no cofre.'; end if;
  st:=jsonb_set(st,'{coins}',to_jsonb(coalesce((st->>'coins')::bigint,0)+p_amount),true); v:=v-p_amount;
 end if;
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 update public.player_vaults set balance=v,updated_at=now() where user_id=auth.uid();
 return jsonb_build_object('state',st,'vault_balance',v);
end; $$;

-- Mascotes colecionáveis guardados no estado de jogo.
create or replace function public.pet_adopt(p_pet_id text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare st jsonb; pet jsonb; price bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select case p_pet_id when 'fox' then 10000 when 'robot' then 50000 when 'unicorn' then 250000 when 'dragon' then 1000000 else null end into price;
 if price is null then raise exception 'Mascote inválido.'; end if;
 pet:=case p_pet_id when 'fox' then jsonb_build_object('id','fox','name','Raposa','emoji','🦊','bonus',1) when 'robot' then jsonb_build_object('id','robot','name','Robô','emoji','🤖','bonus',2) when 'unicorn' then jsonb_build_object('id','unicorn','name','Unicórnio','emoji','🦄','bonus',3) else jsonb_build_object('id','dragon','name','Dragão','emoji','🐉','bonus',5) end;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null or coalesce((st->>'coins')::bigint,0)<price then raise exception 'Moedas insuficientes.'; end if;
 if exists(select 1 from jsonb_array_elements(coalesce(st->'pets','[]'::jsonb)) x where x->>'id'=p_pet_id) then raise exception 'Você já possui esse mascote.'; end if;
 st:=jsonb_set(st,'{coins}',to_jsonb((st->>'coins')::bigint-price),true);
 st:=jsonb_set(st,'{pets}',coalesce(st->'pets','[]'::jsonb)||jsonb_build_array(pet),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 return st;
end; $$;

create or replace function public.pet_equip(p_pet_id text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare st jsonb;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if not exists(select 1 from jsonb_array_elements(coalesce(st->'pets','[]'::jsonb)) x where x->>'id'=p_pet_id) then raise exception 'Mascote não encontrado.'; end if;
 st:=jsonb_set(st,'{equippedPet}',to_jsonb(p_pet_id),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 return st;
end; $$;

-- Clãs e associação de jogadores.
create table if not exists public.game_guilds(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 owner_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);
create table if not exists public.game_guild_members(
 guild_id uuid not null references public.game_guilds(id) on delete cascade,
 user_id uuid primary key references auth.users(id) on delete cascade,
 joined_at timestamptz not null default now()
);
alter table public.game_guilds enable row level security;
alter table public.game_guild_members enable row level security;

create or replace function public.guild_feed()
returns table(id uuid,name text,member_count bigint,owner_name text,is_mine boolean)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 return query select g.id,g.name,count(m.user_id),p.username,
 exists(select 1 from public.game_guild_members z where z.guild_id=g.id and z.user_id=auth.uid())
 from public.game_guilds g join public.profiles p on p.id=g.owner_id
 left join public.game_guild_members m on m.guild_id=g.id
 group by g.id,p.username order by count(m.user_id) desc,g.created_at limit 100;
end; $$;

create or replace function public.guild_create(p_name text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare gid uuid;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if length(trim(coalesce(p_name,'')))<3 or length(p_name)>24 then raise exception 'Nome deve ter de 3 a 24 caracteres.'; end if;
 if exists(select 1 from public.game_guild_members where user_id=auth.uid()) then raise exception 'Você já está em um clã.'; end if;
 insert into public.game_guilds(name,owner_id) values(trim(p_name),auth.uid()) returning id into gid;
 insert into public.game_guild_members(guild_id,user_id) values(gid,auth.uid());
 return gid;
end; $$;

create or replace function public.guild_join(p_guild_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if exists(select 1 from public.game_guild_members where user_id=auth.uid()) then raise exception 'Saia do clã atual antes de entrar em outro.'; end if;
 insert into public.game_guild_members(guild_id,user_id) values(p_guild_id,auth.uid());
end; $$;

create or replace function public.guild_leave()
returns void language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if exists(select 1 from public.game_guilds where owner_id=auth.uid()) then raise exception 'O líder não pode sair sem transferir a liderança.'; end if;
 delete from public.game_guild_members where user_id=auth.uid();
end; $$;

-- Baú cooperativo mundial.
create table if not exists public.global_chests(
 chest_key text primary key, target_amount bigint not null, contributed bigint not null default 0,
 unlocked_at timestamptz
);
create table if not exists public.global_chest_contributions(
 chest_key text not null references public.global_chests(chest_key),
 user_id uuid not null references auth.users(id), amount bigint not null check(amount>0),
 primary key(chest_key,user_id)
);
alter table public.global_chests enable row level security;
alter table public.global_chest_contributions enable row level security;

create or replace function public.global_chest_state()
returns table(target_amount bigint,contributed bigint,unlocked_at timestamptz,my_contribution bigint)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 insert into public.global_chests(chest_key,target_amount) values('reliquia-global-01',10000000) on conflict do nothing;
 return query select c.target_amount,c.contributed,c.unlocked_at,coalesce(x.amount,0)
 from public.global_chests c left join public.global_chest_contributions x on x.chest_key=c.chest_key and x.user_id=auth.uid()
 where c.chest_key='reliquia-global-01';
end; $$;

create or replace function public.global_chest_contribute(p_amount bigint)
returns bigint language plpgsql security definer set search_path=''
as $$
declare st jsonb; c public.global_chests%rowtype; total bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_amount is null or p_amount<1 then raise exception 'Contribuição inválida.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 insert into public.global_chests(chest_key,target_amount) values('reliquia-global-01',10000000) on conflict do nothing;
 select * into c from public.global_chests where chest_key='reliquia-global-01' for update;
 if c.unlocked_at is not null then raise exception 'O baú já foi desbloqueado.'; end if;
 if coalesce((st->>'coins')::bigint,0)<p_amount then raise exception 'Moedas insuficientes.'; end if;
 st:=jsonb_set(st,'{coins}',to_jsonb((st->>'coins')::bigint-p_amount),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 insert into public.global_chest_contributions(chest_key,user_id,amount) values(c.chest_key,auth.uid(),p_amount)
 on conflict(chest_key,user_id) do update set amount=public.global_chest_contributions.amount+excluded.amount;
 total:=c.contributed+p_amount;
 update public.global_chests set contributed=total,unlocked_at=case when total>=target_amount then now() else null end where chest_key=c.chest_key;
 return total;
end; $$;

-- Histórico de preços de itens vendidos no mercado.
create or replace function public.market_price_history(p_item_name text)
returns table(sale_count bigint,average_price numeric,lowest_price bigint,highest_price bigint,last_sale timestamptz)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 return query select count(*)::bigint,coalesce(avg(l.price),0),coalesce(min(l.price),0),coalesce(max(l.price),0),max(l.sold_at)
 from public.market_listings l where l.status='sold' and lower(l.item->>'name')=lower(p_item_name);
end; $$;

revoke all on function public.vault_state() from public;
revoke all on function public.vault_move(bigint,boolean) from public;
revoke all on function public.pet_adopt(text) from public;
revoke all on function public.pet_equip(text) from public;
revoke all on function public.guild_feed() from public;
revoke all on function public.guild_create(text) from public;
revoke all on function public.guild_join(uuid) from public;
revoke all on function public.guild_leave() from public;
revoke all on function public.global_chest_state() from public;
revoke all on function public.global_chest_contribute(bigint) from public;
revoke all on function public.market_price_history(text) from public;

grant execute on function public.vault_state() to authenticated;
grant execute on function public.vault_move(bigint,boolean) to authenticated;
grant execute on function public.pet_adopt(text) to authenticated;
grant execute on function public.pet_equip(text) to authenticated;
grant execute on function public.guild_feed() to authenticated;
grant execute on function public.guild_create(text) to authenticated;
grant execute on function public.guild_join(uuid) to authenticated;
grant execute on function public.guild_leave() to authenticated;
grant execute on function public.global_chest_state() to authenticated;
grant execute on function public.global_chest_contribute(bigint) to authenticated;
grant execute on function public.market_price_history(text) to authenticated;
