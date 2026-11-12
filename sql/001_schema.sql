-- Condomínio – Porteiro · schema v1 (schema isolado "portaria" no Supabase da Isa; nada da Isa é tocado)
create schema if not exists portaria;
set search_path = portaria, extensions, public;
create extension if not exists pgcrypto with schema extensions;
create table condominios (id uuid primary key default gen_random_uuid(), nome text not null, criado_em timestamptz default now());
create table blocos (id uuid primary key default gen_random_uuid(), condominio_id uuid not null references condominios on delete cascade, nome text not null, unique(condominio_id,nome));
create table unidades (id uuid primary key default gen_random_uuid(), bloco_id uuid not null references blocos on delete cascade, numero text not null, unique(bloco_id,numero));
create table moradores (
  id uuid primary key default gen_random_uuid(),
  unidade_id uuid not null references unidades on delete cascade,
  nome text not null, whatsapp text not null,
  principal boolean not null default false, ativo boolean not null default true
);
create unique index um_principal_por_unidade on moradores(unidade_id) where principal and ativo;

create table usuarios (  -- síndico e porteiros
  id uuid primary key default gen_random_uuid(),
  condominio_id uuid not null references condominios on delete cascade,
  papel text not null check (papel in ('sindico','porteiro')),
  nome text not null, email text unique, senha_hash text,
  pin_hash text, ativo boolean not null default true,
  tentativas_pin int not null default 0, bloqueado_ate timestamptz
);
create table escala (  -- turnos previstos
  id uuid primary key default gen_random_uuid(),
  porteiro_id uuid not null references usuarios on delete cascade,
  dias_semana int[] not null default '{1,2,3,4,5,6,0}', inicio time not null, fim time not null
);
create table sessoes (
  token uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios on delete cascade,
  aparelho text, criada_em timestamptz default now(), encerrada_em timestamptz
);
create table turnos (  -- quem realmente assumiu
  id uuid primary key default gen_random_uuid(),
  porteiro_id uuid not null references usuarios, aparelho text,
  inicio timestamptz not null default now(), fim timestamptz,
  previsto boolean not null default true  -- false = cobrindo colega / fora da escala
);

create table encomendas (
  id uuid primary key default gen_random_uuid(),
  condominio_id uuid not null references condominios,
  unidade_id uuid not null references unidades,
  morador_id uuid references moradores,           -- destinatário
  destinatario_texto text, foto_path text, etiqueta_ocr jsonb,
  local_guarda text not null,
  status text not null default 'aguardando' check (status in ('aguardando','retirada')),
  recebida_em timestamptz not null default now(),
  recebida_por uuid not null references usuarios,
  codigo uuid not null default gen_random_uuid() unique,  -- conteúdo do QR
  -- baixa
  retirada_em timestamptz, retirada_por_morador_id uuid references moradores,
  retirada_por_nome text, terceiro boolean, baixa_manual boolean, motivo_baixa text,
  entregue_por uuid references usuarios
);
create index on encomendas(condominio_id,status);

create table eventos (  -- histórico imutável
  id bigserial primary key, encomenda_id uuid not null references encomendas on delete cascade,
  tipo text not null, usuario_id uuid references usuarios, dados jsonb, em timestamptz default now()
);
create table notificacoes (
  id uuid primary key default gen_random_uuid(),
  encomenda_id uuid not null references encomendas on delete cascade,
  tipo text not null check (tipo in ('aviso','retirada')),
  whatsapp text not null, mensagem text not null,
  status text not null default 'pendente' check (status in ('pendente','enviado','falhou')),
  erro text, tentativas int default 0, criada_em timestamptz default now(), enviada_em timestamptz
);

-- tudo travado: acesso só pelas funções (security definer)
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='portaria' loop
    execute format('alter table %I enable row level security', t);
  end loop; end $$;
