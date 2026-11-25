create table if not exists public.player_auctions (
 id uuid primary key default gen_random_uuid(),
 seller_user_id uuid not null references auth.users(id) on delete cascade,
 item jsonb not null, starting_bid bigint not null check(starting_bid>0),
 highest_bid bigint not null, highest_bidder uuid references auth.users(id),
 ends_at timestamptz not null,
 status text not null default 'open' check(status in ('open','sold','returned')),
 created_at timestamptz not null default now(), settled_at timestamptz
);
create index if not exists player_auctions_open_ends on public.player_auctions(status,ends_at);
alter table public.player_auctions enable row level security;

create or replace function public._settle_player_auctions()
returns void language plpgsql security definer set search_path=''
as $$
declare a public.player_auctions%rowtype; ss jsonb; bs jsonb; fee bigint;
begin
 for a in select * from public.player_auctions where status='open' and ends_at<=now() order by ends_at for update skip locked loop
  if a.highest_bidder is null then
   select state into ss from public.game_state where user_id=a.seller_user_id for update;
   if ss is not null then
    ss:=jsonb_set(ss,'{items}',coalesce(ss->'items','[]'::jsonb)||jsonb_build_array(a.item),true);
    update public.game_state set state=ss,updated_at=now() where user_id=a.seller_user_id;
   end if;
   update public.player_auctions set status='returned',settled_at=now() where id=a.id;
  else
   perform 1 from public.game_state where user_id in (a.seller_user_id,a.highest_bidder) order by user_id for update;
   select state into ss from public.game_state where user_id=a.seller_user_id;
   select state into bs from public.game_state where user_id=a.highest_bidder;
   if ss is null or bs is null then raise exception 'Conta de jogador não encontrada para liquidar o leilão.'; end if;
   fee:=greatest(1,ceil(a.highest_bid*0.05)::bigint);
   ss:=jsonb_set(ss,'{coins}',to_jsonb(coalesce((ss->>'coins')::bigint,0)+a.highest_bid-fee),true);
   ss:=jsonb_set(ss,'{marketSales}',to_jsonb(coalesce((ss->>'marketSales')::integer,0)+1),true);
   bs:=jsonb_set(bs,'{items}',coalesce(bs->'items','[]'::jsonb)||jsonb_build_array(a.item),true);
   update public.game_state set state=ss,updated_at=now() where user_id=a.seller_user_id;
   update public.game_state set state=bs,updated_at=now() where user_id=a.highest_bidder;
   update public.player_auctions set status='sold',settled_at=now() where id=a.id;
  end if;
 end loop;
end; $$;

create or replace function public.player_auction_create(p_item_id text,p_starting_bid bigint,p_duration_hours integer)
returns uuid language plpgsql security definer set search_path=''
as $$
declare st jsonb; picked jsonb; remain jsonb; aid uuid;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_starting_bid is null or p_starting_bid<1 or p_duration_hours not in (1,6,12,24,72,168) then raise exception 'Lance inicial ou duração inválida.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Progresso não encontrado.'; end if;
 select value into picked from jsonb_array_elements(coalesce(st->'items','[]'::jsonb)) where value->>'id'=p_item_id limit 1;
 if picked is null then raise exception 'Item não encontrado no inventário.'; end if;
 select coalesce(jsonb_agg(value order by ord),'[]'::jsonb) into remain from jsonb_array_elements(coalesce(st->'items','[]'::jsonb)) with ordinality as x(value,ord) where value->>'id'<>p_item_id;
 st:=jsonb_set(st,'{items}',remain,true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 insert into public.player_auctions(seller_user_id,item,starting_bid,highest_bid,ends_at)
 values(auth.uid(),picked,p_starting_bid,p_starting_bid,now()+make_interval(hours=>p_duration_hours)) returning id into aid;
 return aid;
end; $$;

create or replace function public.player_auction_feed()
returns table(id uuid,item jsonb,seller_name text,starting_bid bigint,highest_bid bigint,highest_bidder_name text,ends_at timestamptz,status text,is_owner boolean)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 perform public._settle_player_auctions();
 return query select a.id,a.item,p.username,a.starting_bid,a.highest_bid,coalesce(bp.username,'Nenhum lance'),a.ends_at,a.status,a.seller_user_id=auth.uid()
 from public.player_auctions a join public.profiles p on p.id=a.seller_user_id left join public.profiles bp on bp.id=a.highest_bidder
 where a.status='open' order by a.ends_at asc limit 150;
end; $$;

create or replace function public.player_auction_bid(p_auction_id uuid,p_amount bigint)
returns bigint language plpgsql security definer set search_path=''
as $$
declare a public.player_auctions%rowtype; bs jsonb; ps jsonb; previous_bid bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 perform public._settle_player_auctions();
 select * into a from public.player_auctions where id=p_auction_id for update;
 if not found or a.status<>'open' or a.ends_at<=now() then raise exception 'Leilão encerrado.'; end if;
 if a.seller_user_id=auth.uid() then raise exception 'Você não pode dar lances no próprio item.'; end if;
 if p_amount is null or p_amount<a.highest_bid+greatest(1,ceil(a.highest_bid*0.05)::bigint) then raise exception 'O lance precisa superar o atual em pelo menos 5%%.'; end if;
 perform 1 from public.game_state where user_id in (auth.uid(),a.highest_bidder) and user_id is not null order by user_id for update;
 select state into bs from public.game_state where user_id=auth.uid();
 if bs is null then raise exception 'Progresso não encontrado.'; end if;
 previous_bid:=case when a.highest_bidder=auth.uid() then a.highest_bid else 0 end;
 if coalesce((bs->>'coins')::bigint,0)+previous_bid<p_amount then raise exception 'Moedas insuficientes.'; end if;
 if a.highest_bidder is not null and a.highest_bidder<>auth.uid() then
  select state into ps from public.game_state where user_id=a.highest_bidder;
  if ps is not null then ps:=jsonb_set(ps,'{coins}',to_jsonb(coalesce((ps->>'coins')::bigint,0)+a.highest_bid),true); update public.game_state set state=ps,updated_at=now() where user_id=a.highest_bidder; end if;
 end if;
 bs:=jsonb_set(bs,'{coins}',to_jsonb(coalesce((bs->>'coins')::bigint,0)+previous_bid-p_amount),true);
 update public.game_state set state=bs,updated_at=now() where user_id=auth.uid();
 update public.player_auctions set highest_bid=p_amount,highest_bidder=auth.uid() where id=a.id;
 return p_amount;
end; $$;

create or replace function public.player_auction_end(p_auction_id uuid)
returns text language plpgsql security definer set search_path=''
as $$
declare a public.player_auctions%rowtype;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select * into a from public.player_auctions where id=p_auction_id for update;
 if not found or a.seller_user_id<>auth.uid() or a.status<>'open' then raise exception 'Leilão não pertence a você ou já terminou.'; end if;
 update public.player_auctions set ends_at=now() where id=a.id;
 perform public._settle_player_auctions();
 return case when a.highest_bidder is null then 'returned' else 'sold' end;
end; $$;

revoke all on function public._settle_player_auctions() from public;
revoke all on function public.player_auction_create(text,bigint,integer) from public;
revoke all on function public.player_auction_feed() from public;
revoke all on function public.player_auction_bid(uuid,bigint) from public;
revoke all on function public.player_auction_end(uuid) from public;
grant execute on function public.player_auction_create(text,bigint,integer) to authenticated;
grant execute on function public.player_auction_feed() to authenticated;
grant execute on function public.player_auction_bid(uuid,bigint) to authenticated;
grant execute on function public.player_auction_end(uuid) to authenticated;