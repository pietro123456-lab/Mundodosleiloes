-- Correção para saldos de moedas acima do limite BIGINT.
-- Execute uma vez no SQL Editor do Supabase.

create or replace function public.pet_adopt(p_pet_id text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 st jsonb;
 pet jsonb;
 price bigint;
 coin_balance numeric;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;

 select case p_pet_id
  when 'fox' then 10000
  when 'robot' then 50000
  when 'unicorn' then 250000
  when 'dragon' then 1000000
  else null
 end into price;

 if price is null then raise exception 'Mascote inválido.'; end if;

 pet:=case p_pet_id
  when 'fox' then jsonb_build_object('id','fox','name','Raposa','emoji','🦊','bonus',1)
  when 'robot' then jsonb_build_object('id','robot','name','Robô','emoji','🤖','bonus',2)
  when 'unicorn' then jsonb_build_object('id','unicorn','name','Unicórnio','emoji','🦄','bonus',3)
  else jsonb_build_object('id','dragon','name','Dragão','emoji','🐉','bonus',5)
 end;

 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Estado do jogador não encontrado.'; end if;

 coin_balance:=coalesce(nullif(st->>'coins','')::numeric,0);
 if coin_balance<price then raise exception 'Moedas insuficientes.'; end if;

 if exists(
  select 1 from jsonb_array_elements(coalesce(st->'pets','[]'::jsonb)) x
  where x->>'id'=p_pet_id
 ) then raise exception 'Você já possui esse mascote.'; end if;

 st:=jsonb_set(st,'{coins}',to_jsonb(coin_balance-price),true);
 st:=jsonb_set(st,'{pets}',coalesce(st->'pets','[]'::jsonb)||jsonb_build_array(pet),true);

 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 return st;
end; $$;

create or replace function public.global_chest_contribute(p_amount bigint)
returns bigint language plpgsql security definer set search_path=''
as $$
declare
 st jsonb;
 c public.global_chests%rowtype;
 coin_balance numeric;
 total bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_amount is null or p_amount<1 then raise exception 'Contribuição inválida.'; end if;

 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Estado do jogador não encontrado.'; end if;

 insert into public.global_chests(chest_key,target_amount)
 values('reliquia-global-01',10000000) on conflict do nothing;

 select * into c from public.global_chests
 where chest_key='reliquia-global-01' for update;

 if c.unlocked_at is not null then raise exception 'O baú já foi desbloqueado.'; end if;

 coin_balance:=coalesce(nullif(st->>'coins','')::numeric,0);
 if coin_balance<p_amount then raise exception 'Moedas insuficientes.'; end if;

 st:=jsonb_set(st,'{coins}',to_jsonb(coin_balance-p_amount),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();

 insert into public.global_chest_contributions(chest_key,user_id,amount)
 values(c.chest_key,auth.uid(),p_amount)
 on conflict(chest_key,user_id) do update
 set amount=public.global_chest_contributions.amount+excluded.amount;

 total:=c.contributed+p_amount;
 update public.global_chests
 set contributed=total,
     unlocked_at=case when total>=target_amount then now() else null end
 where chest_key=c.chest_key;

 return total;
end; $$;

-- O cofre também consulta o saldo do jogador: usar NUMERIC evita falhas
-- quando o saldo total ultrapassa BIGINT. O saldo guardado continua BIGINT.
create or replace function public.vault_move(p_amount bigint,p_deposit boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 st jsonb;
 v bigint;
 coin_balance numeric;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_amount is null or p_amount<1 then raise exception 'Quantidade inválida.'; end if;

 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Estado do jogador não encontrado.'; end if;

 insert into public.player_vaults(user_id) values(auth.uid()) on conflict do nothing;
 select balance into v from public.player_vaults where user_id=auth.uid() for update;
 coin_balance:=coalesce(nullif(st->>'coins','')::numeric,0);

 if p_deposit then
  if coin_balance<p_amount then raise exception 'Moedas insuficientes.'; end if;
  st:=jsonb_set(st,'{coins}',to_jsonb(coin_balance-p_amount),true);
  v:=v+p_amount;
 else
  if v<p_amount then raise exception 'Saldo insuficiente no cofre.'; end if;
  st:=jsonb_set(st,'{coins}',to_jsonb(coin_balance+p_amount),true);
  v:=v-p_amount;
 end if;

 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 update public.player_vaults set balance=v,updated_at=now() where user_id=auth.uid();

 return jsonb_build_object('state',st,'vault_balance',v);
end; $$;

revoke all on function public.pet_adopt(text) from public;
revoke all on function public.global_chest_contribute(bigint) from public;
revoke all on function public.vault_move(bigint,boolean) from public;
grant execute on function public.pet_adopt(text) to authenticated;
grant execute on function public.global_chest_contribute(bigint) to authenticated;
grant execute on function public.vault_move(bigint,boolean) to authenticated;
