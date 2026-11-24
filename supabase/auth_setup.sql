-- Mundo dos Leilões: garantir salvamento individual no Supabase.
-- Pode executar mais de uma vez sem erro por políticas já existentes.
create table if not exists public.game_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.game_state enable row level security;
drop policy if exists "state read own" on public.game_state;
create policy "state read own" on public.game_state
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists "state insert own" on public.game_state;
create policy "state insert own" on public.game_state
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "state update own" on public.game_state;
create policy "state update own" on public.game_state
  for update to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
