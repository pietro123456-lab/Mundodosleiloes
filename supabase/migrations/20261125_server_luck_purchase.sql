-- Compra de multiplicador de sorte processada no servidor.
create or replace function public.game_buy_luck(p_multiplier integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
 v_uid uuid:=auth.uid(); v_state jsonb; v_now timestamptz:=clock_timestamp();
 v_price numeric; v_coins numeric; v_old_expiry numeric:=0; v_expiry numeric;
begin
 if v_uid is null then raise exception 'É necessário entrar na conta.'; end if;
 v_price:=case p_multiplier when 2 then 5000 when 4 then 20000 when 6 then 60000 when 8 then 150000 when 10 then 500000 when 12 then 1500000 when 14 then 5000000 when 16 then 15000000 when 18 then 50000000 when 20 then 150000000 else null end;
 if v_price is null then raise exception 'Multiplicador inválido.'; end if;
 select coalesce(state,'{}'::jsonb) into v_state from public.game_state where user_id=v_uid for update;
 if not found then raise exception 'Progresso não encontrado.'; end if;
 v_coins:=coalesce(nullif(v_state->>'coins','')::numeric,0);
 if v_coins<v_price then raise exception 'Moedas insuficientes.'; end if;
 if coalesce(v_state#>>'{luck,expires}','') ~ '^[0-9]+([.][0-9]+)?$' then
   v_old_expiry:=(v_state#>>'{luck,expires}')::numeric;
 end if;
 v_expiry:=greatest(floor(extract(epoch from v_now)*1000),v_old_expiry)+900000;
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins-v_price),true);
 v_state:=jsonb_set(v_state,'{luck}',jsonb_build_object('multiplier',p_multiplier,'expires',v_expiry),true);
 v_state:=jsonb_set(v_state,'{history}',jsonb_build_array('Comprou sorte '||p_multiplier::text||'x por 15 minutos.')||coalesce(v_state->'history','[]'::jsonb),true);
 update public.game_state set state=v_state,updated_at=v_now where user_id=v_uid;
 return v_state;
end;
$$;
revoke all on function public.game_buy_luck(integer) from public,anon;
grant execute on function public.game_buy_luck(integer) to authenticated;
