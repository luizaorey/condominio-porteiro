set search_path = portaria, extensions, public;-- Condomínio – Porteiro · funções (API). Todas security definer; anon só chama estas.
create or replace function _sess(p_token uuid, p_papel text default null) returns usuarios
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin
  select us.* into u from sessoes s join usuarios us on us.id=s.usuario_id
   where s.token=p_token and s.encerrada_em is null and us.ativo;
  if not found then raise exception 'sessao_invalida' using errcode='28000'; end if;
  if p_papel is not null and u.papel<>p_papel then raise exception 'sem_permissao' using errcode='42501'; end if;
  return u;
end $$;

-- ===== login =====
create or replace function login_sindico(p_email text, p_senha text) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; t uuid;
begin
  select * into u from usuarios where email=lower(p_email) and papel='sindico' and ativo;
  if not found or u.senha_hash <> crypt(p_senha,u.senha_hash) then raise exception 'credenciais_invalidas'; end if;
  insert into sessoes(usuario_id,aparelho) values(u.id,'painel') returning token into t;
  return jsonb_build_object('token',t,'nome',u.nome,'condominio_id',u.condominio_id);
end $$;

-- lista de porteiros para a tela "quem é você?" (sem segredo). Precisa de um código do aparelho (condomínio).
create or replace function porteiros_do_condominio(p_condominio uuid) returns jsonb
language sql security definer set search_path=portaria,extensions,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'nome',u.nome) order by u.nome),'[]')
  from usuarios u where u.condominio_id=p_condominio and u.papel='porteiro' and u.ativo $$;

create or replace function login_pin(p_porteiro uuid, p_pin text, p_aparelho text default null) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; t uuid; prev boolean; agora time := (now() at time zone 'America/Sao_Paulo')::time;
        dow int := extract(dow from now() at time zone 'America/Sao_Paulo');
begin
  select * into u from usuarios where id=p_porteiro and papel='porteiro' and ativo for update;
  if not found then raise exception 'credenciais_invalidas'; end if;
  if u.bloqueado_ate is not null and u.bloqueado_ate>now() then raise exception 'pin_bloqueado'; end if;
  if u.pin_hash is null or u.pin_hash <> crypt(p_pin,u.pin_hash) then
    update usuarios set tentativas_pin=tentativas_pin+1,
      bloqueado_ate=case when tentativas_pin+1>=5 then now()+interval '5 minutes' end,
      tentativas_pin=case when tentativas_pin+1>=5 then 0 else tentativas_pin+1 end where id=u.id;
    raise exception 'credenciais_invalidas';
  end if;
  update usuarios set tentativas_pin=0,bloqueado_ate=null where id=u.id;
  -- previsto na escala? (suporta turno que vira a noite)
  select exists(select 1 from escala e where e.porteiro_id=u.id and (
     (e.inicio<=e.fim and dow=any(e.dias_semana) and agora between e.inicio and e.fim) or
     (e.inicio>e.fim and ((dow=any(e.dias_semana) and agora>=e.inicio) or
        (((dow+6)%7)=any(e.dias_semana) and agora<=e.fim))))) into prev;
  -- encerra turno aberto do mesmo aparelho (troca de porteiro) e sessão anterior
  update turnos set fim=now() where aparelho is not distinct from p_aparelho and fim is null;
  update sessoes set encerrada_em=now() where aparelho is not distinct from p_aparelho and encerrada_em is null and usuario_id<>u.id;
  insert into turnos(porteiro_id,aparelho,previsto) values(u.id,p_aparelho,prev);
  insert into sessoes(usuario_id,aparelho) values(u.id,p_aparelho) returning token into t;
  return jsonb_build_object('token',t,'nome',u.nome,'condominio_id',u.condominio_id,'previsto',prev);
end $$;

create or replace function logout(p_token uuid) returns void
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare ap text;
begin
  update sessoes set encerrada_em=now() where token=p_token and encerrada_em is null returning aparelho into ap;
  update turnos set fim=now() where aparelho is not distinct from ap and fim is null;
end $$;

-- ===== portaria =====
create or replace function turno_atual(p_token uuid) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; prev jsonb; dow int := extract(dow from now() at time zone 'America/Sao_Paulo'); agora time := (now() at time zone 'America/Sao_Paulo')::time;
begin
  u:=_sess(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('nome',x.nome,'inicio',e.inicio,'fim',e.fim)),'[]') into prev
    from escala e join usuarios x on x.id=e.porteiro_id
   where x.condominio_id=u.condominio_id and x.ativo and
     ((e.inicio<=e.fim and dow=any(e.dias_semana) and agora between e.inicio and e.fim) or
      (e.inicio>e.fim and ((dow=any(e.dias_semana) and agora>=e.inicio) or (((dow+6)%7)=any(e.dias_semana) and agora<=e.fim))));
  return jsonb_build_object('logado',u.nome,'previstos',prev);
end $$;

create or replace function unidades_busca(p_token uuid) returns jsonb  -- cadastro completo p/ sugestão no app
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin
  u:=_sess(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('unidade_id',un.id,'bloco',b.nome,'numero',un.numero,
     'moradores',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'nome',m.nome,'principal',m.principal) order by m.principal desc,m.nome),'[]')
        from moradores m where m.unidade_id=un.id and m.ativo)) order by b.nome,un.numero)
     from unidades un join blocos b on b.id=un.bloco_id where b.condominio_id=u.condominio_id),'[]');
end $$;

create or replace function _enc_json(e encomendas) returns jsonb
language sql stable security definer set search_path=portaria,extensions,public as $$
 select jsonb_build_object('id',e.id,'status',e.status,'local',e.local_guarda,'recebida_em',e.recebida_em,
   'bloco',b.nome,'apto',un.numero,'morador',m.nome,'morador_id',e.morador_id,'foto',e.foto_path,
   'retirada_em',e.retirada_em,'retirada_por',e.retirada_por_nome,'terceiro',e.terceiro,
   'aviso',(select n.status from notificacoes n where n.encomenda_id=e.id and n.tipo='aviso' order by criada_em desc limit 1),
   'recebida_por',(select nome from usuarios where id=e.recebida_por),
   'entregue_por',(select nome from usuarios where id=e.entregue_por))
 from unidades un join blocos b on b.id=un.bloco_id left join moradores m on m.id=e.morador_id where un.id=e.unidade_id $$;

create or replace function pendentes(p_token uuid) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin u:=_sess(p_token);
  return coalesce((select jsonb_agg(_enc_json(e) order by e.recebida_em) from encomendas e
    where e.condominio_id=u.condominio_id and e.status='aguardando'),'[]'); end $$;

create or replace function registrar_entrada(p_token uuid, p_unidade uuid, p_morador uuid, p_local text,
   p_foto text, p_ocr jsonb default null, p_destinatario_texto text default null) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; e encomendas; zap text; nome text; apto text; msg text; ok boolean;
begin
  u:=_sess(p_token,'porteiro');
  if coalesce(trim(p_local),'')='' then raise exception 'local_obrigatorio'; end if;
  perform 1 from unidades un join blocos b on b.id=un.bloco_id where un.id=p_unidade and b.condominio_id=u.condominio_id;
  if not found then raise exception 'unidade_invalida'; end if;
  -- sem morador escolhido: usa o contato principal da unidade
  if p_morador is null then select id into p_morador from moradores where unidade_id=p_unidade and principal and ativo; end if;
  insert into encomendas(condominio_id,unidade_id,morador_id,destinatario_texto,foto_path,etiqueta_ocr,local_guarda,recebida_por)
   values(u.condominio_id,p_unidade,p_morador,p_destinatario_texto,p_foto,p_ocr,trim(p_local),u.id) returning * into e;
  insert into eventos(encomenda_id,tipo,usuario_id,dados) values(e.id,'entrada',u.id,jsonb_build_object('local',e.local_guarda));
  select m.whatsapp,m.nome into zap,nome from moradores m where m.id=p_morador;
  if zap is null then
    insert into eventos(encomenda_id,tipo,usuario_id,dados) values(e.id,'aviso_falhou',u.id,'{"erro":"sem_whatsapp"}');
  else
    msg:='Olá, '||split_part(nome,' ',1)||'! Chegou uma encomenda para você na portaria. Para retirar, mostre o QR Code abaixo ao porteiro. Se outra pessoa for buscar, é só encaminhar este QR Code.';
    insert into notificacoes(encomenda_id,tipo,whatsapp,mensagem) values(e.id,'aviso',zap,msg);
  end if;
  return _enc_json(e) || jsonb_build_object('codigo',e.codigo);
end $$;

create or replace function reenviar_aviso(p_token uuid, p_encomenda uuid) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; e encomendas; n notificacoes;
begin
  u:=_sess(p_token,'porteiro');
  select * into e from encomendas where id=p_encomenda and condominio_id=u.condominio_id for update;
  if not found then raise exception 'nao_encontrada'; end if;
  if e.status<>'aguardando' then raise exception 'codigo_ja_utilizado'; end if;
  select * into n from notificacoes where encomenda_id=e.id and tipo='aviso' order by criada_em desc limit 1;
  if not found then raise exception 'sem_aviso_para_reenviar'; end if;
  insert into notificacoes(encomenda_id,tipo,whatsapp,mensagem) values(e.id,'aviso',n.whatsapp,n.mensagem);
  insert into eventos(encomenda_id,tipo,usuario_id) values(e.id,'aviso_reenviado',u.id);
  return jsonb_build_object('ok',true);
end $$;

create or replace function buscar_por_codigo(p_token uuid, p_codigo uuid) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; e encomendas;
begin
  u:=_sess(p_token,'porteiro');
  select * into e from encomendas where codigo=p_codigo and condominio_id=u.condominio_id;
  if not found then raise exception 'codigo_desconhecido'; end if;
  return _enc_json(e);
end $$;

-- BAIXA ATÔMICA. modo: 'destinatario' | 'terceiro' | 'manual'
create or replace function baixar(p_token uuid, p_encomenda uuid, p_modo text, p_nome_retirante text default null,
   p_motivo text default null, p_codigo uuid default null) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; e encomendas; quem text; mor moradores; msg text; ap text;
begin
  u:=_sess(p_token,'porteiro');
  if p_modo not in ('destinatario','terceiro','manual') then raise exception 'modo_invalido'; end if;
  select * into e from encomendas where id=p_encomenda and condominio_id=u.condominio_id;
  if not found then raise exception 'nao_encontrada'; end if;
  if p_modo in ('destinatario','terceiro') and (p_codigo is null or p_codigo<>e.codigo) then raise exception 'codigo_nao_confere'; end if;
  if p_modo='terceiro' and coalesce(trim(p_nome_retirante),'')='' then raise exception 'nome_obrigatorio'; end if;
  if p_modo='manual' and (coalesce(trim(p_nome_retirante),'')='' or coalesce(trim(p_motivo),'')='') then raise exception 'nome_e_motivo_obrigatorios'; end if;
  select m.* into mor from moradores m where m.id=e.morador_id;
  quem := case when p_modo='destinatario' then coalesce(mor.nome,e.destinatario_texto,'Destinatário') else trim(p_nome_retirante) end;
  -- a única baixa: o UPDATE condicional decide a corrida entre aparelhos
  update encomendas set status='retirada', retirada_em=now(), retirada_por_nome=quem,
     retirada_por_morador_id=case when p_modo='destinatario' then e.morador_id end,
     terceiro=(p_modo='terceiro'), baixa_manual=(p_modo='manual'), motivo_baixa=nullif(trim(p_motivo),''), entregue_por=u.id
   where id=e.id and status='aguardando' returning * into e;
  if not found then
    select * into e from encomendas where id=p_encomenda;
    return jsonb_build_object('ok',false,'ja_retirada',true,'retirada_em',e.retirada_em,'retirada_por',e.retirada_por_nome,
        'entregue_por',(select nome from usuarios where id=e.entregue_por));
  end if;
  insert into eventos(encomenda_id,tipo,usuario_id,dados) values(e.id,'retirada',u.id,
     jsonb_build_object('modo',p_modo,'retirante',quem,'motivo',p_motivo));
  if mor.whatsapp is not null then
    msg:='Sua encomenda foi retirada na portaria às '||to_char(e.retirada_em at time zone 'America/Sao_Paulo','HH24:MI')||' por '||quem||'.';
    insert into notificacoes(encomenda_id,tipo,whatsapp,mensagem) values(e.id,'retirada',mor.whatsapp,msg);
  end if;
  return jsonb_build_object('ok',true,'encomenda',_enc_json(e));
end $$;

-- ===== painel do síndico =====
create or replace function painel_encomendas(p_token uuid, p_status text default null, p_busca text default null) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin u:=_sess(p_token,'sindico');
  return coalesce((select jsonb_agg(_enc_json(e) order by e.recebida_em desc) from (
    select e.* from encomendas e join unidades un on un.id=e.unidade_id join blocos b on b.id=un.bloco_id
    left join moradores m on m.id=e.morador_id
    where e.condominio_id=u.condominio_id and (p_status is null or e.status=p_status)
      and (p_busca is null or b.nome ilike '%'||p_busca||'%' or un.numero ilike '%'||p_busca||'%' or m.nome ilike '%'||p_busca||'%')
    order by e.recebida_em desc limit 300) e),'[]'); end $$;

create or replace function painel_historico(p_token uuid, p_encomenda uuid) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin u:=_sess(p_token,'sindico');
  perform 1 from encomendas where id=p_encomenda and condominio_id=u.condominio_id;
  if not found then raise exception 'nao_encontrada'; end if;
  return jsonb_build_object(
   'eventos',(select coalesce(jsonb_agg(jsonb_build_object('tipo',v.tipo,'em',v.em,'por',(select nome from usuarios where id=v.usuario_id),'dados',v.dados) order by v.em),'[]') from eventos v where v.encomenda_id=p_encomenda),
   'avisos',(select coalesce(jsonb_agg(jsonb_build_object('tipo',n.tipo,'status',n.status,'erro',n.erro,'em',n.criada_em) order by n.criada_em),'[]') from notificacoes n where n.encomenda_id=p_encomenda)); end $$;

create or replace function painel_cadastros(p_token uuid) returns jsonb
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin u:=_sess(p_token,'sindico');
  return jsonb_build_object(
   'unidades',unidades_busca(p_token),
   'moradores',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'unidade_id',m.unidade_id,'nome',m.nome,'whatsapp',m.whatsapp,'principal',m.principal,'ativo',m.ativo)),'[]')
       from moradores m join unidades un on un.id=m.unidade_id join blocos b on b.id=un.bloco_id where b.condominio_id=u.condominio_id),
   'porteiros',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'nome',x.nome,'ativo',x.ativo,'tem_pin',x.pin_hash is not null,
       'escala',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'dias',e.dias_semana,'inicio',e.inicio,'fim',e.fim)),'[]') from escala e where e.porteiro_id=x.id))),'[]')
       from usuarios x where x.condominio_id=u.condominio_id and x.papel='porteiro'),
   'turnos',(select coalesce(jsonb_agg(jsonb_build_object('porteiro',x.nome,'inicio',t.inicio,'fim',t.fim,'previsto',t.previsto) order by t.inicio desc),'[]')
       from (select * from turnos order by inicio desc limit 100) t join usuarios x on x.id=t.porteiro_id where x.condominio_id=u.condominio_id)); end $$;

create or replace function painel_salvar_unidade(p_token uuid, p_bloco text, p_numero text) returns uuid
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; b uuid; un uuid;
begin u:=_sess(p_token,'sindico');
  insert into blocos(condominio_id,nome) values(u.condominio_id,trim(p_bloco)) on conflict(condominio_id,nome) do update set nome=excluded.nome returning id into b;
  insert into unidades(bloco_id,numero) values(b,trim(p_numero)) on conflict(bloco_id,numero) do update set numero=excluded.numero returning id into un;
  return un; end $$;

create or replace function painel_salvar_morador(p_token uuid, p_id uuid, p_unidade uuid, p_nome text, p_whatsapp text, p_principal boolean, p_ativo boolean default true) returns uuid
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; r uuid; z text := regexp_replace(p_whatsapp,'\D','','g');
begin u:=_sess(p_token,'sindico');
  perform 1 from unidades un join blocos b on b.id=un.bloco_id where un.id=p_unidade and b.condominio_id=u.condominio_id;
  if not found then raise exception 'unidade_invalida'; end if;
  if length(z) in (10,11) then z:='55'||z; end if;
  if p_principal then update moradores set principal=false where unidade_id=p_unidade and id is distinct from p_id; end if;
  if p_id is null then insert into moradores(unidade_id,nome,whatsapp,principal,ativo) values(p_unidade,trim(p_nome),z,p_principal,p_ativo) returning id into r;
  else update moradores set unidade_id=p_unidade,nome=trim(p_nome),whatsapp=z,principal=p_principal,ativo=p_ativo where id=p_id returning id into r; end if;
  return r; end $$;

create or replace function painel_salvar_porteiro(p_token uuid, p_id uuid, p_nome text, p_pin text, p_ativo boolean default true) returns uuid
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; r uuid;
begin u:=_sess(p_token,'sindico');
  if p_pin is not null and p_pin !~ '^\d{4,6}$' then raise exception 'pin_invalido'; end if;
  if p_id is null then insert into usuarios(condominio_id,papel,nome,pin_hash,ativo) values(u.condominio_id,'porteiro',trim(p_nome),case when p_pin is not null then crypt(p_pin,gen_salt('bf')) end,p_ativo) returning id into r;
  else update usuarios set nome=trim(p_nome),ativo=p_ativo,pin_hash=case when p_pin is not null then crypt(p_pin,gen_salt('bf')) else pin_hash end
        where id=p_id and condominio_id=u.condominio_id and papel='porteiro' returning id into r; end if;
  return r; end $$;

create or replace function painel_salvar_escala(p_token uuid, p_porteiro uuid, p_dias int[], p_inicio time, p_fim time) returns uuid
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios; r uuid;
begin u:=_sess(p_token,'sindico');
  perform 1 from usuarios where id=p_porteiro and condominio_id=u.condominio_id; if not found then raise exception 'porteiro_invalido'; end if;
  insert into escala(porteiro_id,dias_semana,inicio,fim) values(p_porteiro,p_dias,p_inicio,p_fim) returning id into r; return r; end $$;

create or replace function painel_remover_escala(p_token uuid, p_id uuid) returns void
language plpgsql security definer set search_path=portaria,extensions,public as $$
declare u usuarios;
begin u:=_sess(p_token,'sindico');
  delete from escala e using usuarios x where e.id=p_id and x.id=e.porteiro_id and x.condominio_id=u.condominio_id; end $$;

-- só as funções públicas ficam acessíveis ao anon (as de uso interno não)
revoke all on all functions in schema portaria from public, anon, authenticated;
grant execute on function login_sindico, porteiros_do_condominio, login_pin, logout, turno_atual, unidades_busca, pendentes,
  registrar_entrada, reenviar_aviso, buscar_por_codigo, baixar, painel_encomendas, painel_historico, painel_cadastros,
  painel_salvar_unidade, painel_salvar_morador, painel_salvar_porteiro, painel_salvar_escala, painel_remover_escala to anon;
grant usage on schema portaria to anon;
