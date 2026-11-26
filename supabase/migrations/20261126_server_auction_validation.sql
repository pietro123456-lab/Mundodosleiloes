
create table if not exists public.game_auctions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 item jsonb not null,
 bot_name text not null,
 bot_balance bigint not null,
 bot_max bigint not null,
 bot_bid bigint not null default 0,
 player_bid bigint not null default 0,
 ends_at timestamptz not null,
 next_bot_at timestamptz not null,
 status text not null default 'active' check(status in ('active','won','lost','passed')),
 created_at timestamptz not null default now()
);
create index if not exists game_auctions_user_active_idx on public.game_auctions(user_id,status);
alter table public.game_auctions enable row level security;
revoke all on public.game_auctions from public,anon,authenticated;
-- Abertura de baús: cobrança, sorteio, mutação e inventário no servidor.
create or replace function public.game_open_chest(p_chest text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 v_uid uuid:=auth.uid(); v_state jsonb; v_now timestamptz:=clock_timestamp();
 v_today text:=to_char(timezone('utc',clock_timestamp())::date,'YYYY-MM-DD');
 v_cost numeric; v_coins numeric; v_luck numeric:=1;
 v_odds jsonb; v_pool jsonb:='[["🪨","Pedra Lisa",5,"Comum"],["🌿","Folha Verde",8,"Comum"],["🦴","Fragmento de Osso",10,"Comum"],["🐚","Concha Pequena",12,"Comum"],["🍂","Folha Seca",14,"Comum"],["🧱","Tijolo Simples",16,"Comum"],["🪵","Galho",18,"Comum"],["🪡","Agulha",20,"Comum"],["🧺","Cesto de Palha",22,"Comum"],["🍯","Pote de Mel",25,"Comum"],["🧻","Papel Velho",28,"Comum"],["🥄","Colher de Madeira",30,"Comum"],["🪙","Ficha de Cobre",32,"Comum"],["🧸","Boneco de Pano",35,"Comum"],["🧷","Broche Simples",38,"Comum"],["🔔","Sino Pequeno",42,"Comum"],["🪢","Corda Curta",45,"Comum"],["🥣","Tigela de Barro",48,"Comum"],["🧰","Kit de Reparos",60,"Incomum"],["🧣","Cachecol de Lã",75,"Incomum"],["🪞","Espelho de Bolso",90,"Incomum"],["🧴","Perfume Básico",110,"Incomum"],["🧸","Urso de Pelúcia",130,"Incomum"],["🧱","Bloco de Cristal",160,"Incomum"],["🪙","Moeda Prateada",190,"Incomum"],["🧢","Boné do Explorador",220,"Incomum"],["🥾","Botas de Viajante",280,"Incomum"],["🎒","Mochila Pequena",320,"Incomum"],["🧵","Tecido Encantado",380,"Incomum"],["🪬","Talismã Simples",420,"Incomum"],["🏹","Arco Élfico",1000,"Raro"],["💠","Safira Lapidada",1200,"Raro"],["🦊","Máscara Kitsune",1500,"Raro"],["🧤","Luvas do Ladrão",1700,"Raro"],["🧿","Olho Místico",2000,"Raro"],["🪶","Pluma Celeste",2400,"Raro"],["🦋","Borboleta de Cristal",2800,"Raro"],["🗿","Ídolo Antigo",3200,"Raro"],["🔮","Orbe Arcano",3500,"Épico"],["⚔️","Lâmina do Eclipse",4500,"Épico"],["🐉","Escama de Dragão",5500,"Épico"],["🌙","Crescente Lunar",7000,"Épico"],["🧝","Relíquia Élfica",9000,"Épico"],["🕰️","Relógio do Tempo",11000,"Épico"],["🪐","Anel Planetário",13000,"Épico"],["👑","Coroa do Reino",15000,"Lendário"],["🔥","Chama Eterna",22000,"Lendário"],["💎","Diamante Real",30000,"Lendário"],["🦄","Unicórnio de Cristal",45000,"Lendário"],["🏆","Troféu Imortal",60000,"Lendário"],["🦚","Pavão Dourado",75000,"Lendário"],["🌌","Fragmento Galáctico",80000,"Mítico"],["🪽","Asas da Eternidade",120000,"Mítico"],["🌠","Estrela Primordial",180000,"Mítico"],["🌑","Lua de Obsidiana",220000,"Mítico"],["🌀","Portal Infinito",260000,"Mítico"],["💫","Núcleo Cósmico",300000,"Divino"],["🌟","Coração Estelar",500000,"Divino"],["👁️","Olho da Criação",800000,"Divino"],["☀️","Sol Eterno",1000000,"Divino"],["🌈","Prisma Celestial",1500000,"Celestial"],["🪷","Lótus das Galáxias",2000000,"Celestial"],["🛸","Nave Primordial",3000000,"Celestial"],["🧬","Código da Existência",5000000,"Celestial"],["🕳️","Singularidade",8000000,"Transcendente"],["♾️","Eternidade Absoluta",15000000,"Transcendente"],["⚜️","Selo dos Criadores",25000000,"Transcendente"],["🔒","Relíquia Secreta",50000000,"Secreto"],["🫧","Essência Impossível",100000000,"Secreto"],["🗝️","Chave do Multiverso",250000000,"Secreto"],["🌠","Núcleo Secreto",500000000,"Secreto"],["🧿","Artefato do Vazio",800000000,"Secreto"],["⏳","Relíquia Eterna",1000000000,"Eterno"],["🪬","Amuleto do Infinito",2500000000,"Eterno"],["🕰️","Cronos Cristalizado",5000000000,"Eterno"],["🎇","Ícone Absoluto",10000000000,"Icônico"],["🪙","Moeda dos Deuses",25000000000,"Icônico"],["🪄","Cetro da Criação",50000000000,"Icônico"],["🌌","Primordial",100000000000,"Primordial"],["🌌","Semente do Universo",250000000000,"Primordial"],["🌀","Origem de Tudo",500000000000,"Primordial"],["♾️","Infinito Vivo",1000000000000,"Infinito"],["💠","Diamante Infinito",2500000000000,"Infinito"],["✨","Última Centelha",5000000000000,"Infinito"]]'::jsonb; v_all_odds jsonb:='{"Leilão gratuito":[78,18,3.7,0.28,0.02,0,0,0,0,0,0,0,0,0],"Baú de Bronze":[60,28,10,1.8,0.18,0.019,0.001,0,0,0,0,0,0,0],"Cofre de Prata":[42,32,18,6.5,1.3,0.19,0.01,0,0,0,0,0,0,0],"Tesouro de Ouro":[27,30,25,13,4.3,0.65,0.05,0.005,0,0,0,0,0,0],"Baú Platina":[18,25,27,18,9,2.7,0.28,0.03,0.002,0,0,0,0,0],"Baú Diamante":[12,20,25,22,14,5.5,1.3,0.18,0.008,0.002,0,0,0,0],"Baú Astral":[8,15,22,23,17,9,4.5,1.2,0.28,0.02,0,0,0,0],"Cofre Celestial":[5,10,18,22,18,12,8,5,1.8,0.2,0,0,0,0],"Câmara Real":[3,8,15,20,20,15,10,6,2.8,0.2,0,0,0,0],"Baú Transcendente":[1,5,10,15,20,18,14,10,6,1,0,0,0,0]}'::jsonb;
 v_rarities text[]:=array['Comum','Incomum','Raro','Épico','Lendário','Mítico','Divino','Celestial','Transcendente','Secreto','Eterno','Icônico','Primordial','Infinito'];
 v_weights numeric[]:='{}'; v_total numeric:=0; v_roll numeric; v_index integer:=1;
 v_rarity text; v_item jsonb; v_candidates jsonb;
 v_mutations jsonb:='[["Normal","Normal",1,0],["Brilhante","Brilhante",2,18],["Dourada","Dourada",5,8],["Glitch","Glitch",15,3],["Arco-íris","Arco-íris",40,1],["Cósmica","Cósmica",150,0.25],["Celestial","Celestial",1000,0.05]]'::jsonb;
 v_auction_id uuid; v_bot_name text; v_mut_roll numeric; v_mutation jsonb:='["Normal","Normal",1,0]'::jsonb; v_result jsonb; i integer;
begin
 if v_uid is null then raise exception 'Entre na sua conta para abrir um baú.'; end if;
 v_cost:=case p_chest when 'Leilão gratuito' then 0 when 'Baú de Bronze' then 5000 when 'Cofre de Prata' then 25000 when 'Tesouro de Ouro' then 50000 when 'Baú Platina' then 250000 when 'Baú Diamante' then 1000000 when 'Baú Astral' then 5000000 when 'Cofre Celestial' then 25000000 when 'Câmara Real' then 100000000 when 'Baú Transcendente' then 500000000 else null end;
 if v_cost is null then raise exception 'Baú inválido.'; end if;
 select coalesce(state,'{}'::jsonb) into v_state from public.game_state where user_id=v_uid for update;
 if not found then raise exception 'Progresso não encontrado.'; end if;
 if jsonb_typeof(v_state->'items') is distinct from 'array' then v_state:=jsonb_set(v_state,'{items}','[]'::jsonb,true); end if;
 v_coins:=coalesce(nullif(v_state->>'coins','')::numeric,0);
 if v_coins<v_cost then raise exception 'Moedas insuficientes!'; end if;
 if p_chest='Leilão gratuito' and v_state->>'dailyDate'=v_today then raise exception 'Seu baú grátis de hoje já foi usado!'; end if;
 if coalesce(v_state#>>'{luck,expires}','') ~ '^[0-9]+([.][0-9]+)?$' and (v_state#>>'{luck,expires}')::numeric>extract(epoch from v_now)*1000 and coalesce(v_state#>>'{luck,multiplier}','') ~ '^[0-9]+([.][0-9]+)?$' then v_luck:=greatest(1,least(20,(v_state#>>'{luck,multiplier}')::numeric)); end if;
 v_odds:=coalesce(v_all_odds->p_chest,v_all_odds->'Leilão gratuito');
 for i in 1..jsonb_array_length(v_odds) loop v_weights:=array_append(v_weights,(v_odds->>(i-1))::numeric*power(v_luck,i-1));v_total:=v_total+(v_odds->>(i-1))::numeric*power(v_luck,i-1);end loop;
 if v_total<=0 then raise exception 'Configuração de probabilidades inválida.'; end if;
 v_roll:=random()*v_total;
 for i in 1..array_length(v_weights,1) loop v_roll:=v_roll-v_weights[i];if v_roll<=0 then v_index:=i;exit;end if;end loop;
 v_rarity:=v_rarities[v_index];
 select coalesce(jsonb_agg(value),'[]'::jsonb) into v_candidates from jsonb_array_elements(v_pool) where value->>3=v_rarity;
 if jsonb_array_length(v_candidates)=0 then select jsonb_agg(value) into v_candidates from jsonb_array_elements(v_pool) where value->>3='Comum';end if;
 v_item:=v_candidates->floor(random()*jsonb_array_length(v_candidates))::integer;
 v_mut_roll:=random()*100;
 for i in 1..jsonb_array_length(v_mutations) loop v_mutation:=v_mutations->(i-1);if v_mut_roll<(v_mutation->>3)::numeric then exit;end if;v_mut_roll:=v_mut_roll-(v_mutation->>3)::numeric;v_mutation:='["Normal","Normal",1,0]'::jsonb;end loop;
 v_result:=jsonb_build_object('id',floor(extract(epoch from v_now)*1000)::bigint,'emoji',v_item->>0,'name',v_item->>1,'price',(v_item->>2)::numeric,'rarity',v_item->>3,'mutation',v_mutation->>0,'mutationMultiplier',(v_mutation->>2)::numeric);
 v_bot_name:=(array['Ana Monteiro','Heitor Lima','Luna Prado','Caio Nunes','Maya Costa'])[1+floor(random()*5)::integer];
 insert into public.game_auctions(user_id,item,bot_name,bot_balance,bot_max,ends_at,next_bot_at)
 values(v_uid,v_result,v_bot_name,greatest(500,floor((v_result->>'price')::numeric*(1.2+random()*2.8))::bigint),
 floor(greatest(500,(v_result->>'price')::numeric*(1.2+random()*2.8))*(0.35+random()*0.45))::bigint,
 v_now+interval '20 seconds',v_now+interval '2 seconds')
 returning id into v_auction_id;
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins-v_cost),true);
 if p_chest='Leilão gratuito' then v_state:=jsonb_set(v_state,'{dailyDate}',to_jsonb(v_today),true);end if;
 v_state:=jsonb_set(v_state,'{history}',jsonb_build_array('Baú aberto: '||p_chest||'. Item sorteado: '||(v_result->>'name')||'.')||coalesce(v_state->'history','[]'::jsonb),true);
 update public.game_state set state=v_state,updated_at=v_now where user_id=v_uid;
 return jsonb_build_object('state',v_state,'item',v_result,'auctionId',v_auction_id,'botName',v_bot_name);
end; $$;
revoke all on function public.game_open_chest(text) from public,anon;
grant execute on function public.game_open_chest(text) to authenticated;

create or replace function public.game_auction_tick(p_auction_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.game_auctions%rowtype; st jsonb; n bigint; old_player_bid bigint; now_at timestamptz:=clock_timestamp();
begin
 select * into a from public.game_auctions where id=p_auction_id and user_id=auth.uid() for update;
 if not found then raise exception 'Leilão não encontrado.'; end if;
 if a.status<>'active' then return jsonb_build_object('auction',to_jsonb(a)); end if;
 if now_at>=a.next_bot_at and now_at<a.ends_at and a.bot_bid<a.bot_max then
   old_player_bid:=a.player_bid;
   n:=least(a.bot_max,greatest(100,a.player_bid,a.bot_bid)+greatest(100,floor(100+random()*greatest(150,(a.item->>'price')::numeric*0.12))::bigint));
   if n>a.bot_bid and n<=a.bot_balance then
     update public.game_auctions set bot_bid=n,player_bid=0,next_bot_at=now_at+make_interval(secs=2+floor(random()*3)::integer) where id=a.id returning * into a;
     if coalesce((select (state->>'coins')::numeric from public.game_state where user_id=a.user_id),0)>=0 then
       select state into st from public.game_state where user_id=a.user_id for update;
       if coalesce((st->>'coins')::numeric,0)>=0 then
         st:=jsonb_set(st,'{coins}',to_jsonb(coalesce((st->>'coins')::numeric,0)+old_player_bid),true);
         update public.game_state set state=st,updated_at=now_at where user_id=a.user_id;
       end if;
     end if;
   else update public.game_auctions set next_bot_at=now_at+interval '2 seconds' where id=a.id returning * into a; end if;
 elsif now_at>=a.next_bot_at then
   update public.game_auctions set next_bot_at=now_at+interval '2 seconds' where id=a.id returning * into a;
 end if;
 return jsonb_build_object('botBid',a.bot_bid,'playerBid',a.player_bid,'botName',a.bot_name,'endsAt',a.ends_at,'status',a.status);
end; $$;

create or replace function public.game_auction_bid(p_auction_id uuid,p_amount bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.game_auctions%rowtype; st jsonb; bal numeric; now_at timestamptz:=clock_timestamp();
begin
 select * into a from public.game_auctions where id=p_auction_id and user_id=auth.uid() for update;
 if not found or a.status<>'active' then raise exception 'Leilão não está ativo.'; end if;
 if now_at>=a.ends_at then raise exception 'O tempo do leilão acabou.'; end if;
 if a.bot_bid<=a.player_bid then raise exception 'Aguarde o bot superar seu lance.'; end if;
 if p_amount is null or p_amount<a.bot_bid+100 then raise exception 'Seu lance deve superar o bot em pelo menos 100 moedas.'; end if;
 select state into st from public.game_state where user_id=auth.uid() for update;
 bal:=coalesce((st->>'coins')::numeric,0);
 if p_amount>bal then raise exception 'Moedas insuficientes.'; end if;
 st:=jsonb_set(st,'{coins}',to_jsonb(bal-p_amount),true);
 update public.game_state set state=st,updated_at=now_at where user_id=auth.uid();
 update public.game_auctions set player_bid=p_amount,next_bot_at=now_at+interval '2 seconds' where id=a.id;
 return jsonb_build_object('playerBid',p_amount,'botBid',a.bot_bid,'coins',bal-p_amount);
end; $$;

create or replace function public.game_auction_finish(p_auction_id uuid,p_force_bot boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.game_auctions%rowtype; st jsonb; won boolean; now_at timestamptz:=clock_timestamp();
begin
 select * into a from public.game_auctions where id=p_auction_id and user_id=auth.uid() for update;
 if not found then raise exception 'Leilão não encontrado.'; end if;
 if a.status<>'active' then raise exception 'Este leilão já foi encerrado.'; end if;
 if not p_force_bot and now_at<a.ends_at then raise exception 'O leilão ainda está acontecendo.'; end if;
 won:=not p_force_bot and a.player_bid>a.bot_bid;
 select state into st from public.game_state where user_id=auth.uid() for update;
 if won then
   st:=jsonb_set(st,'{items}',coalesce(st->'items','[]'::jsonb)||jsonb_build_array(a.item),true);
   st:=jsonb_set(st,'{wins}',to_jsonb(coalesce((st->>'wins')::integer,0)+1),true);
   st:=jsonb_set(st,'{progress,xp}',to_jsonb(coalesce((st#>>'{progress,xp}')::integer,0)+10),true);
   st:=jsonb_set(st,'{level}',to_jsonb(greatest(1,1+floor((coalesce((st#>>'{progress,xp}')::integer,0)+10)/250.0)::integer)),true);
   st:=jsonb_set(st,'{history}',jsonb_build_array('Leilão fictício vencido: '||(a.item->>'name')||' por '||a.player_bid||' moedas.')||coalesce(st->'history','[]'::jsonb),true);
 else
   st:=jsonb_set(st,'{coins}',to_jsonb(coalesce((st->>'coins')::numeric,0)+a.player_bid),true);
   st:=jsonb_set(st,'{history}',jsonb_build_array('Leilão fictício perdido: '||(a.item->>'name')||'.')||coalesce(st->'history','[]'::jsonb),true);
 end if;
 update public.game_state set state=st,updated_at=now_at where user_id=auth.uid();
 update public.game_auctions set status=case when won then 'won' else 'lost' end where id=a.id;
 return jsonb_build_object('state',st,'won',won,'item',a.item,'botName',a.bot_name,'playerBid',a.player_bid,'botBid',a.bot_bid);
end; $$;

revoke all on function public.game_auction_tick(uuid) from public,anon;
revoke all on function public.game_auction_bid(uuid,bigint) from public,anon;
revoke all on function public.game_auction_finish(uuid,boolean) from public,anon;
grant execute on function public.game_auction_tick(uuid) to authenticated;
grant execute on function public.game_auction_bid(uuid,bigint) to authenticated;
grant execute on function public.game_auction_finish(uuid,boolean) to authenticated;
