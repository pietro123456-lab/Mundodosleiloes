-- Recompensas de missões e conquistas calculadas no servidor.
create or replace function public.game_claim_progress_reward(p_kind text,p_reward_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_progress jsonb;
  v_items jsonb;
  v_claimed jsonb;
  v_today text := to_char(timezone('utc',now())::date,'YYYY-MM-DD');
  v_coins numeric;
  v_xp numeric;
  v_reward numeric;
  v_reward_xp numeric;
  v_label text;
  v_metric numeric := 0;
  v_required numeric;
begin
  if v_uid is null then raise exception 'É necessário entrar na conta.'; end if;
  if p_kind not in ('mission','achievement') then raise exception 'Tipo de recompensa inválido.'; end if;

  select state into v_state from public.game_state where user_id=v_uid for update;
  if not found then raise exception 'Progresso não encontrado.'; end if;

  v_progress:=coalesce(v_state->'progress','{}'::jsonb);
  v_items:=coalesce(v_state->'items','[]'::jsonb);
  if jsonb_typeof(v_items)<>'array' then raise exception 'Inventário inválido.'; end if;

  if p_kind='mission' then
    if coalesce(v_progress->>'missionDate','')<>v_today then
      v_progress:=jsonb_set(v_progress,'{missionDate}',to_jsonb(v_today),true);
      v_progress:=jsonb_set(v_progress,'{claimedMissions}','[]'::jsonb,true);
    end if;
    v_claimed:=coalesce(v_progress->'claimedMissions','[]'::jsonb);
    case p_reward_id
      when 'open' then v_reward:=350;v_reward_xp:=25;v_required:=1;v_metric:=coalesce(nullif(v_state->>'wins','')::numeric,0);v_label:='Missão concluída: Explorador';
      when 'collect' then v_reward:=250;v_reward_xp:=20;v_required:=3;v_metric:=jsonb_array_length(v_items);v_label:='Missão concluída: Colecionador';
      when 'rare' then v_reward:=500;v_reward_xp:=35;v_required:=1;
        select count(*) into v_metric from jsonb_array_elements(v_items) x where coalesce(x->>'rarity','') in ('Raro','Épico','Lendário','Mítico','Divino','Celestial','Transcendente','Secreto','Eterno','Icônico','Primordial','Infinito');
        v_label:='Missão concluída: Olho para raridades';
      else raise exception 'Missão desconhecida.';
    end case;
  else
    v_claimed:=coalesce(v_progress->'claimedAchievements','[]'::jsonb);
    case p_reward_id
      when 'first_win' then v_reward:=300;v_reward_xp:=20;v_required:=1;v_metric:=coalesce(nullif(v_state->>'wins','')::numeric,0);v_label:='Conquista: Primeiro martelo';
      when 'wins_10' then v_reward:=2500;v_reward_xp:=100;v_required:=10;v_metric:=coalesce(nullif(v_state->>'wins','')::numeric,0);v_label:='Conquista: Leiloeiro experiente';
      when 'items_10' then v_reward:=1200;v_reward_xp:=60;v_required:=10;v_metric:=jsonb_array_length(v_items);v_label:='Conquista: Coleção em crescimento';
      when 'items_50' then v_reward:=8000;v_reward_xp:=250;v_required:=50;v_metric:=jsonb_array_length(v_items);v_label:='Conquista: Grande colecionador';
      when 'mutations_3' then v_reward:=3000;v_reward_xp:=120;v_required:=3;
        select count(distinct coalesce(x->>'mutation','Normal')) into v_metric from jsonb_array_elements(v_items) x;
        v_label:='Conquista: Caçador de mutações';
      when 'rarity_divine' then v_reward:=5000;v_reward_xp:=180;v_required:=1;
        select count(*) into v_metric from jsonb_array_elements(v_items) x where coalesce(x->>'rarity','') in ('Divino','Celestial','Transcendente','Secreto','Eterno','Icônico','Primordial','Infinito');
        v_label:='Conquista: Toque divino';
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
  if p_kind='mission' then v_progress:=jsonb_set(v_progress,'{claimedMissions}',v_claimed,true);
  else v_progress:=jsonb_set(v_progress,'{claimedAchievements}',v_claimed,true); end if;
  v_progress:=jsonb_set(v_progress,'{xp}',to_jsonb(v_xp),true);

  v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins),true);
  v_state:=jsonb_set(v_state,'{progress}',v_progress,true);
  v_state:=jsonb_set(v_state,'{level}',to_jsonb(greatest(1,1+floor(v_xp/250)::bigint)),true);
  v_state:=jsonb_set(v_state,'{history}',jsonb_build_array(v_label||' · +'||v_reward::text||' moedas · +'||v_reward_xp::text||' XP')||coalesce(v_state->'history','[]'::jsonb),true);

  update public.game_state set state=v_state,updated_at=now() where user_id=v_uid;
  return v_state;
end;
$$;
revoke all on function public.game_claim_progress_reward(text,text) from public,anon;
grant execute on function public.game_claim_progress_reward(text,text) to authenticated;
