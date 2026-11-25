-- Mundo dos Leilões: mercado entre jogadores, leilão mundial e eventos semanais.
-- Execute este arquivo UMA vez no SQL Editor do Supabase.
-- As transações usam exclusivamente moedas fictícias do jogo.

create extension if not exists pgcrypto;

-- MERCADO GLOBAL
create table if not exists public.market_listings (
 id uuid primary key default gen_random_uuid(),
 seller_user_id uuid not null references auth.users(id) on delete cascade,
 item jsonb not null,
 price bigint not null check(price > 0),
 status text not null default 'open' check(status in ('open','sold','cancelled')),
 buyer_user_id uuid references auth.users(id),
 created_at timestamptz not null default now(),
 sold_at timestamptz
);
create index if not exists market_listings_open_created on public.market_listings(status,created_at desc);
alter table public.market_listings enable row level security;

create or replace function public.market_listings_feed()
returns table(id uuid,item jsonb,price bigint,seller_name text,created_at timestamptz)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 return query
 select l.id,l.item,l.price,p.username,l.created_at
 from public.market_listings l join public.profiles p on p.id=l.seller_user_id
 where l.status='open' and l.seller_user_id<>auth.uid()
 order by l.created_at desc limit 100;
end; $$;

create or replace function public.market_my_listings()
returns table(id uuid,item jsonb,price bigint,created_at timestamptz)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 return query select l.id,l.item,l.price,l.created_at
 from public.market_listings l where l.status='open' and l.seller_user_id=auth.uid()
 order by l.created_at desc;
end; $$;

create or replace function public.market_create_listing(p_item_id text,p_price bigint)
returns uuid language plpgsql security definer set search_path=''
as $$
declare st jsonb; picked jsonb; remaining jsonb; listing uuid;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_item_id is null or p_price is null or p_price<1 or p_price>9000000000000000 then
  raise exception 'Item ou preço inválido.';
 end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Seu progresso ainda não foi salvo.'; end if;
 select e.value into picked
 from jsonb_array_elements(coalesce(st->'items','[]'::jsonb)) e(value)
 where e.value->>'id'=p_item_id limit 1;
 if picked is null then raise exception 'Esse item não está mais no seu inventário.'; end if;
 select coalesce(jsonb_agg(e.value order by e.ord),'[]'::jsonb) into remaining
 from jsonb_array_elements(coalesce(st->'items','[]'::jsonb)) with ordinality e(value,ord)
 where e.value->>'id'<>p_item_id;
 st:=jsonb_set(st,'{items}',remaining,true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 insert into public.market_listings(seller_user_id,item,price)
 values(auth.uid(),picked,p_price) returning id into listing;
 return listing;
end; $$;

create or replace function public.market_buy_listing(p_listing_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare l public.market_listings%rowtype; buyer_state jsonb; seller_state jsonb; fee bigint; seller_gain bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select * into l from public.market_listings where id=p_listing_id for update;
 if not found or l.status<>'open' then raise exception 'Este anúncio não está mais disponível.'; end if;
 if l.seller_user_id=auth.uid() then raise exception 'Você não pode comprar seu próprio anúncio.'; end if;
 perform 1 from public.game_state
 where user_id in (auth.uid(),l.seller_user_id) order by user_id for update;
 select state into buyer_state from public.game_state where user_id=auth.uid();
 select state into seller_state from public.game_state where user_id=l.seller_user_id;
 if buyer_state is null or seller_state is null then raise exception 'Não foi possível carregar as contas envolvidas.'; end if;
 if coalesce((buyer_state->>'coins')::bigint,0)<l.price then raise exception 'Moedas insuficientes.'; end if;
 fee:=greatest(1,ceil(l.price*0.05)::bigint);
 seller_gain:=l.price-fee;
 buyer_state:=jsonb_set(buyer_state,'{coins}',to_jsonb(coalesce((buyer_state->>'coins')::bigint,0)-l.price),true);
 buyer_state:=jsonb_set(buyer_state,'{items}',coalesce(buyer_state->'items','[]'::jsonb)||jsonb_build_array(l.item),true);
 buyer_state:=jsonb_set(buyer_state,'{history}',jsonb_build_array('Compra no mercado: '||coalesce(l.item->>'name','Item')||'.')||coalesce(buyer_state->'history','[]'::jsonb),true);
 seller_state:=jsonb_set(seller_state,'{coins}',to_jsonb(coalesce((seller_state->>'coins')::bigint,0)+seller_gain),true);
 seller_state:=jsonb_set(seller_state,'{marketSales}',to_jsonb(coalesce((seller_state->>'marketSales')::integer,0)+1),true);
 seller_state:=jsonb_set(seller_state,'{history}',jsonb_build_array('Venda no mercado: '||coalesce(l.item->>'name','Item')||'.')||coalesce(seller_state->'history','[]'::jsonb),true);
 update public.game_state set state=buyer_state,updated_at=now() where user_id=auth.uid();
 update public.game_state set state=seller_state,updated_at=now() where user_id=l.seller_user_id;
 update public.market_listings set status='sold',buyer_user_id=auth.uid(),sold_at=now() where id=l.id;
 return jsonb_build_object('state',buyer_state,'seller_received',seller_gain);
end; $$;

create or replace function public.market_cancel_listing(p_listing_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare l public.market_listings%rowtype; st jsonb;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select * into l from public.market_listings where id=p_listing_id for update;
 if not found or l.status<>'open' or l.seller_user_id<>auth.uid() then
  raise exception 'Anúncio indisponível ou não pertence a você.';
 end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 st:=jsonb_set(st,'{items}',coalesce(st->'items','[]'::jsonb)||jsonb_build_array(l.item),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 update public.market_listings set status='cancelled' where id=l.id;
 return jsonb_build_object('state',st);
end; $$;

-- LEILÃO MUNDIAL: um item compartilhado por todos os jogadores a cada semana.
create table if not exists public.world_auctions (
 id uuid primary key default gen_random_uuid(),
 week_key text not null unique,
 title text not null,
 item jsonb not null,
 highest_bid bigint not null default 1000,
 highest_bidder uuid references auth.users(id),
 ends_at timestamptz not null,
 claimed boolean not null default false
);
alter table public.world_auctions enable row level security;

drop function if exists public.world_auction_current();
create function public.world_auction_current()
returns table(id uuid,title text,item jsonb,ends_at timestamptz,highest_bid bigint,highest_bidder_name text,my_bid bigint,is_winner boolean,claimed boolean)
language plpgsql security definer set search_path=''
as $$
declare wk text; finish timestamptz; aid uuid;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 wk:=to_char(date_trunc('week',now()),'IYYY-IW');
 finish:=date_trunc('week',now())+interval '1 week';
 insert into public.world_auctions(week_key,title,item,highest_bid,ends_at)
 values(wk,'Relíquia da Semana',jsonb_build_object('id','world-'||wk,'emoji','🌌','name','Relíquia do Leilão Mundial','price',500000,'rarity','Mítico','mutation','Cósmica','mutationMultiplier',150),1000,finish)
 on conflict(week_key) do nothing;
 select w.id into aid from public.world_auctions w
 where w.highest_bidder=auth.uid() and not w.claimed and w.ends_at<=now()
 order by w.ends_at desc limit 1;
 if aid is null then
  select w.id into aid from public.world_auctions w where w.week_key=wk;
 end if;
 return query
 select w.id,w.title,w.item,w.ends_at,w.highest_bid,coalesce(p.username,'Nenhum lance'),
 case when w.highest_bidder=auth.uid() then w.highest_bid else 0 end,
 w.highest_bidder=auth.uid(),w.claimed
 from public.world_auctions w left join public.profiles p on p.id=w.highest_bidder where w.id=aid;
end; $$;

create or replace function public.world_auction_bid(p_amount bigint)
returns bigint language plpgsql security definer set search_path=''
as $$
declare wk text; finish timestamptz; a public.world_auctions%rowtype; st jsonb; oldst jsonb; oldbid bigint;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 if p_amount is null or p_amount<1 then raise exception 'Lance inválido.'; end if;
 wk:=to_char(date_trunc('week',now()),'IYYY-IW');
 finish:=date_trunc('week',now())+interval '1 week';
 insert into public.world_auctions(week_key,title,item,highest_bid,ends_at)
 values(wk,'Relíquia da Semana',jsonb_build_object('id','world-'||wk,'emoji','🌌','name','Relíquia do Leilão Mundial','price',500000,'rarity','Mítico','mutation','Cósmica','mutationMultiplier',150),1000,finish)
 on conflict(week_key) do nothing;
 select * into a from public.world_auctions where week_key=wk for update;
 if now()>=a.ends_at then raise exception 'Este leilão semanal já terminou.'; end if;
 if p_amount<a.highest_bid+100 then raise exception 'O lance precisa superar o atual em pelo menos 100 moedas.'; end if;
 perform 1 from public.game_state where user_id in (auth.uid(),a.highest_bidder) and user_id is not null order by user_id for update;
 select state into st from public.game_state where user_id=auth.uid();
 if st is null then raise exception 'Seu progresso ainda não foi salvo.'; end if;
 oldbid:=case when a.highest_bidder=auth.uid() then a.highest_bid else 0 end;
 if coalesce((st->>'coins')::bigint,0)+oldbid<p_amount then raise exception 'Moedas insuficientes.'; end if;
 if a.highest_bidder is not null and a.highest_bidder<>auth.uid() then
  select state into oldst from public.game_state where user_id=a.highest_bidder;
  if oldst is not null then
   oldst:=jsonb_set(oldst,'{coins}',to_jsonb(coalesce((oldst->>'coins')::bigint,0)+a.highest_bid),true);
   update public.game_state set state=oldst,updated_at=now() where user_id=a.highest_bidder;
  end if;
 end if;
 st:=jsonb_set(st,'{coins}',to_jsonb(coalesce((st->>'coins')::bigint,0)+oldbid-p_amount),true);
 st:=jsonb_set(st,'{history}',jsonb_build_array('Lance no Leilão Mundial: '||p_amount::text||' moedas.')||coalesce(st->'history','[]'::jsonb),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 update public.world_auctions set highest_bid=p_amount,highest_bidder=auth.uid() where id=a.id;
 return p_amount;
end; $$;

create or replace function public.world_auction_claim()
returns jsonb language plpgsql security definer set search_path=''
as $$
declare a public.world_auctions%rowtype; st jsonb;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 select * into a from public.world_auctions
 where highest_bidder=auth.uid() and not claimed and ends_at<=now()
 order by ends_at desc limit 1 for update;
 if not found then raise exception 'Não há recompensa de leilão mundial pendente para sua conta.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Seu progresso não foi encontrado.'; end if;
 st:=jsonb_set(st,'{items}',coalesce(st->'items','[]'::jsonb)||jsonb_build_array(a.item),true);
 st:=jsonb_set(st,'{history}',jsonb_build_array('Vitória no Leilão Mundial: '||coalesce(a.item->>'name','Relíquia')||'.')||coalesce(st->'history','[]'::jsonb),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 update public.world_auctions set claimed=true where id=a.id;
 return jsonb_build_object('state',st,'item',a.item);
end; $$;

-- EVENTOS: a mutação muda automaticamente a cada semana e cada conta resgata uma vez.
create table if not exists public.game_event_claims (
 user_id uuid not null references auth.users(id) on delete cascade,
 week_key text not null,
 claimed_at timestamptz not null default now(),
 primary key(user_id,week_key)
);
alter table public.game_event_claims enable row level security;

create or replace function public.game_event_current()
returns table(week_key text,title text,mutation text,reward_coins bigint,item jsonb,starts_at timestamptz,ends_at timestamptz,claimed boolean)
language plpgsql security definer set search_path=''
as $$
declare wk text; startweek timestamptz; idx integer; mut text; mult numeric; reward jsonb; did_claim boolean;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 startweek:=date_trunc('week',now()); wk:=to_char(startweek,'IYYY-IW');
 idx:=extract(week from startweek)::integer % 6;
 mut:=case idx when 0 then 'Brilhante' when 1 then 'Dourada' when 2 then 'Glitch' when 3 then 'Arco-íris' when 4 then 'Cósmica' else 'Celestial' end;
 mult:=case mut when 'Brilhante' then 2 when 'Dourada' then 5 when 'Glitch' then 15 when 'Arco-íris' then 40 when 'Cósmica' then 150 else 1000 end;
 reward:=jsonb_build_object('id','event-'||wk,'emoji','🎊','name','Relíquia do Festival','price',75000,'rarity','Lendário','mutation',mut,'mutationMultiplier',mult);
 select exists(select 1 from public.game_event_claims c where c.user_id=auth.uid() and c.week_key=wk) into did_claim;
 return query select wk,'Festival das Mutações',mut,25000::bigint,reward,startweek,startweek+interval '1 week',did_claim;
end; $$;

create or replace function public.game_event_claim()
returns jsonb language plpgsql security definer set search_path=''
as $$
declare wk text; startweek timestamptz; idx integer; mut text; mult numeric; st jsonb; reward jsonb; newxp integer;
begin
 if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
 startweek:=date_trunc('week',now()); wk:=to_char(startweek,'IYYY-IW');
 idx:=extract(week from startweek)::integer % 6;
 mut:=case idx when 0 then 'Brilhante' when 1 then 'Dourada' when 2 then 'Glitch' when 3 then 'Arco-íris' when 4 then 'Cósmica' else 'Celestial' end;
 mult:=case mut when 'Brilhante' then 2 when 'Dourada' then 5 when 'Glitch' then 15 when 'Arco-íris' then 40 when 'Cósmica' then 150 else 1000 end;
 reward:=jsonb_build_object('id','event-'||wk,'emoji','🎊','name','Relíquia do Festival','price',75000,'rarity','Lendário','mutation',mut,'mutationMultiplier',mult);
 insert into public.game_event_claims(user_id,week_key) values(auth.uid(),wk) on conflict do nothing;
 if not found then raise exception 'Você já resgatou a recompensa desta semana.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if st is null then raise exception 'Seu progresso ainda não foi salvo.'; end if;
 newxp:=coalesce((st#>>'{progress,xp}')::integer,0)+75;
 st:=jsonb_set(st,'{progress}',coalesce(st->'progress','{}'::jsonb),true);
 st:=jsonb_set(st,'{coins}',to_jsonb(coalesce((st->>'coins')::bigint,0)+25000),true);
 st:=jsonb_set(st,'{items}',coalesce(st->'items','[]'::jsonb)||jsonb_build_array(reward),true);
 st:=jsonb_set(st,'{eventClaims}',to_jsonb(coalesce((st->>'eventClaims')::integer,0)+1),true);
 st:=jsonb_set(st,'{progress,xp}',to_jsonb(newxp),true);
 st:=jsonb_set(st,'{level}',to_jsonb(1+floor(newxp/250.0)::integer),true);
 st:=jsonb_set(st,'{history}',jsonb_build_array('Evento semanal concluído: Festival das Mutações ('||mut||').')||coalesce(st->'history','[]'::jsonb),true);
 update public.game_state set state=st,updated_at=now() where user_id=auth.uid();
 return jsonb_build_object('state',st,'item',reward);
end; $$;

-- Permissões: as tabelas não ficam abertas ao navegador; as RPCs validam auth.uid().
revoke all on function public.market_listings_feed() from public;
revoke all on function public.market_my_listings() from public;
revoke all on function public.market_create_listing(text,bigint) from public;
revoke all on function public.market_buy_listing(uuid) from public;
revoke all on function public.market_cancel_listing(uuid) from public;
revoke all on function public.world_auction_current() from public;
revoke all on function public.world_auction_bid(bigint) from public;
revoke all on function public.world_auction_claim() from public;
revoke all on function public.game_event_current() from public;
revoke all on function public.game_event_claim() from public;
grant execute on function public.market_listings_feed() to authenticated;
grant execute on function public.market_my_listings() to authenticated;
grant execute on function public.market_create_listing(text,bigint) to authenticated;
grant execute on function public.market_buy_listing(uuid) to authenticated;
grant execute on function public.market_cancel_listing(uuid) to authenticated;
grant execute on function public.world_auction_current() to authenticated;
grant execute on function public.world_auction_bid(bigint) to authenticated;
grant execute on function public.world_auction_claim() to authenticated;
grant execute on function public.game_event_current() to authenticated;
grant execute on function public.game_event_claim() to authenticated;
