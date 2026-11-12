-- permissões do service_role (usado só pela Edge Function) + bucket privado de fotos
grant usage on schema portaria to service_role;
grant all on all tables in schema portaria to service_role;
grant all on all sequences in schema portaria to service_role;
insert into storage.buckets(id,name,public) values('portaria-fotos','portaria-fotos',false) on conflict do nothing;
