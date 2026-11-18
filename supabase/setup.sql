-- Quadro de melhorias: status em tempo real
-- Rode este script inteiro no SQL Editor do Supabase (botão "Run").
-- ANTES DE RODAR: troque TROQUE-ESTE-CODIGO (linha marcada abaixo) pelo código de edição do time.
-- Use um código longo, por exemplo quatro palavras: "agulha-linha-tesoura-botao".

create extension if not exists pgcrypto with schema extensions;

-- Status atual de cada tarefa (M-01 a M-25)
create table if not exists public.quadro_status (
  task_id    text primary key,
  status     text not null default 'todo' check (status in ('todo', 'doing', 'done')),
  updated_at timestamptz not null default now()
);

-- Histórico de mudanças
create table if not exists public.quadro_historico (
  id         bigserial primary key,
  task_id    text not null,
  status     text not null,
  changed_at timestamptz not null default now()
);

-- Dependências: task_id só começa quando depends_on estiver 'done'
create table if not exists public.quadro_deps (
  task_id    text not null,
  depends_on text not null,
  primary key (task_id, depends_on)
);

-- Código de edição (guardado só como hash) e controle de tentativas erradas
create table if not exists public.quadro_config (
  id             int primary key default 1 check (id = 1),
  edit_code_hash text not null
);
create table if not exists public.quadro_falhas (
  at timestamptz not null default now()
);

insert into public.quadro_status (task_id)
select 'M-' || lpad(g::text, 2, '0') from generate_series(1, 25) g
on conflict (task_id) do nothing;

insert into public.quadro_deps (task_id, depends_on) values
  ('M-04', 'M-01'), ('M-04', 'M-03'),
  ('M-02', 'M-01'), ('M-02', 'M-05'),
  ('M-06', 'M-05'), ('M-06', 'M-20'),
  ('M-09', 'M-03'),
  ('M-14', 'M-11'),
  ('M-15', 'M-16'), ('M-15', 'M-18'),
  ('M-17', 'M-15'),
  ('M-19', 'M-24'),
  ('M-23', 'M-03')
on conflict do nothing;

-- >>> TROQUE O CÓDIGO NA LINHA ABAIXO <<<
insert into public.quadro_config (id, edit_code_hash)
values (1, extensions.crypt('TROQUE-ESTE-CODIGO', extensions.gen_salt('bf')))
on conflict (id) do update set edit_code_hash = excluded.edit_code_hash;

-- Segurança: todos podem LER o status; ninguém escreve direto nas tabelas
alter table public.quadro_status    enable row level security;
alter table public.quadro_historico enable row level security;
alter table public.quadro_deps      enable row level security;
alter table public.quadro_config    enable row level security;
alter table public.quadro_falhas    enable row level security;

drop policy if exists "ler status" on public.quadro_status;
create policy "ler status" on public.quadro_status for select to anon, authenticated using (true);
drop policy if exists "ler historico" on public.quadro_historico;
create policy "ler historico" on public.quadro_historico for select to anon, authenticated using (true);
drop policy if exists "ler dependencias" on public.quadro_deps;
create policy "ler dependencias" on public.quadro_deps for select to anon, authenticated using (true);
-- quadro_config e quadro_falhas ficam sem política: invisíveis para o site.

-- Confere o código (com limite de 30 tentativas erradas a cada 10 minutos)
create or replace function public.quadro_code_ok(p_code text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  delete from quadro_falhas where at < now() - interval '1 hour';
  if (select count(*) from quadro_falhas where at > now() - interval '10 minutes') >= 30 then
    return 'muitas_tentativas';
  end if;
  select edit_code_hash into v_hash from quadro_config where id = 1;
  if v_hash is null or p_code is null or crypt(p_code, v_hash) <> v_hash then
    insert into quadro_falhas default values;
    return 'codigo_invalido';
  end if;
  return 'ok';
end $$;
revoke all on function public.quadro_code_ok(text) from public, anon, authenticated;

create or replace function public.quadro_check_code(p_code text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v text;
begin
  v := quadro_code_ok(p_code);
  if v = 'ok' then return json_build_object('ok', true); end if;
  return json_build_object('ok', false, 'erro', v);
end $$;

-- Muda o status de uma tarefa (confere código e dependências no servidor)
create or replace function public.quadro_set_status(p_task text, p_status text, p_code text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v text; v_pend text[];
begin
  v := quadro_code_ok(p_code);
  if v <> 'ok' then return json_build_object('ok', false, 'erro', v); end if;
  if p_status not in ('todo', 'doing', 'done') then
    return json_build_object('ok', false, 'erro', 'status_invalido');
  end if;
  if p_status <> 'todo' then
    select array_agg(d.depends_on order by d.depends_on) into v_pend
    from quadro_deps d join quadro_status s on s.task_id = d.depends_on
    where d.task_id = p_task and s.status <> 'done';
    if v_pend is not null then
      return json_build_object('ok', false, 'erro', 'bloqueada:' || array_to_string(v_pend, ','));
    end if;
  end if;
  update quadro_status set status = p_status, updated_at = now()
  where task_id = p_task and status <> p_status;
  if found then
    insert into quadro_historico (task_id, status) values (p_task, p_status);
  end if;
  return json_build_object('ok', true);
end $$;

-- Volta todas as tarefas para "A fazer"
create or replace function public.quadro_reset(p_code text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v text;
begin
  v := quadro_code_ok(p_code);
  if v <> 'ok' then return json_build_object('ok', false, 'erro', v); end if;
  insert into quadro_historico (task_id, status)
  select task_id, 'todo' from quadro_status where status <> 'todo';
  update quadro_status set status = 'todo', updated_at = now() where status <> 'todo';
  return json_build_object('ok', true);
end $$;

grant execute on function public.quadro_check_code(text) to anon, authenticated;
grant execute on function public.quadro_set_status(text, text, text) to anon, authenticated;
grant execute on function public.quadro_reset(text) to anon, authenticated;

-- Tempo real: avisa os navegadores quando um status muda
do $$
begin
  alter publication supabase_realtime add table public.quadro_status;
exception when duplicate_object then null;
end $$;
