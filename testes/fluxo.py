#!/usr/bin/env python3
"""Teste ponta-a-ponta da API (RPC) do Condomínio–Porteiro no Supabase da Isa."""
import json, urllib.request, urllib.error, os
env = dict(l.strip().split('=',1) for l in open(os.path.expanduser('~/projetos/isa/.env')) if '=' in l and not l.startswith('#'))
URL, KEY = env['SUPABASE_URL'], env['SUPABASE_PUBLISHABLE_KEY']
def rpc(fn, **a):
    r = urllib.request.Request(f"{URL}/rest/v1/rpc/{fn}", json.dumps(a).encode(), {"apikey":KEY,"Content-Type":"application/json","Content-Profile":"portaria"})
    try: return json.load(urllib.request.urlopen(r))
    except urllib.error.HTTPError as e: return {"ERRO": json.load(e).get("message")}
def ok(nome, cond): print(("OK   " if cond else "FALHOU"), nome); 
CID='00000000-0000-0000-0000-000000000001'
s = rpc('login_sindico', p_email='sindico@piloto.local', p_senha='piloto123')['token']
un = rpc('painel_salvar_unidade', p_token=s, p_bloco='A', p_numero='101')
rpc('painel_salvar_morador', p_token=s, p_id=None, p_unidade=un, p_nome='Maria Silva', p_whatsapp='(71) 99999-0001', p_principal=True)
mj = rpc('painel_salvar_morador', p_token=s, p_id=None, p_unidade=un, p_nome='João Silva', p_whatsapp='71999990002', p_principal=False)
ports = {p['nome']:p['id'] for p in rpc('porteiros_do_condominio', p_condominio=CID)}
ok('lista porteiros', set(ports)=={'Carlos','Marcos'})
ok('PIN errado recusado', 'ERRO' in rpc('login_pin', p_porteiro=ports['Carlos'], p_pin='9999', p_aparelho='tablet'))
c = rpc('login_pin', p_porteiro=ports['Carlos'], p_pin='1111', p_aparelho='tablet')['token']
uns = rpc('unidades_busca', p_token=c); apt=[u for u in uns if u['numero']=='101'][0]
maria=[m for m in apt['moradores'] if m['principal']][0]
ok('principal vem primeiro', maria['nome']=='Maria Silva')
e = rpc('registrar_entrada', p_token=c, p_unidade=apt['unidade_id'], p_morador=None, p_local='Prateleira 2', p_foto='x.jpg')
ok('entrada usa contato principal', e.get('morador')=='Maria Silva' and e['status']=='aguardando')
ok('1 pendente', len(rpc('pendentes', p_token=c))>=1)
# troca de porteiro no mesmo aparelho
m = rpc('login_pin', p_porteiro=ports['Marcos'], p_pin='2222', p_aparelho='tablet')['token']
ok('sessão do Carlos encerrada', 'ERRO' in rpc('pendentes', p_token=c))
ok('Marcos vê pendência e local', any(p['id']==e['id'] and p['local']=='Prateleira 2' for p in rpc('pendentes', p_token=m)))
ok('código desconhecido', 'ERRO' in rpc('buscar_por_codigo', p_token=m, p_codigo='11111111-1111-1111-1111-111111111111'))
ok('terceiro exige nome', 'ERRO' in rpc('baixar', p_token=m, p_encomenda=e['id'], p_modo='terceiro', p_codigo=e['codigo']))
r1 = rpc('baixar', p_token=m, p_encomenda=e['id'], p_modo='terceiro', p_nome_retirante='João Silva', p_codigo=e['codigo'])
ok('baixa por terceiro', r1.get('ok') and r1['encomenda']['terceiro'] and r1['encomenda']['morador']=='Maria Silva' and r1['encomenda']['retirada_por']=='João Silva')
r2 = rpc('baixar', p_token=m, p_encomenda=e['id'], p_modo='destinatario', p_codigo=e['codigo'])
ok('segundo scan: já retirada', r2.get('ja_retirada') is True)
ok('reenvio bloqueado após baixa', 'ERRO' in rpc('reenviar_aviso', p_token=m, p_encomenda=e['id']))
# manual
e2 = rpc('registrar_entrada', p_token=m, p_unidade=apt['unidade_id'], p_morador=None, p_local='Prateleira 1', p_foto='y.jpg')
ok('manual exige motivo', 'ERRO' in rpc('baixar', p_token=m, p_encomenda=e2['id'], p_modo='manual', p_nome_retirante='Zé'))
ok('baixa manual', rpc('baixar', p_token=m, p_encomenda=e2['id'], p_modo='manual', p_nome_retirante='Zé', p_motivo='QR perdido')['ok'])
ok('reenvio ok enquanto pendente', rpc('reenviar_aviso', p_token=m, p_encomenda=rpc('registrar_entrada', p_token=m, p_unidade=apt['unidade_id'], p_morador=None, p_local='P3', p_foto='z')['id']).get('ok'))
h = rpc('painel_historico', p_token=s, p_encomenda=e['id'])
ok('histórico tem entrada+retirada com porteiros', [x['tipo'] for x in h['eventos']]==['entrada','retirada'] and h['eventos'][0]['por']=='Carlos' and h['eventos'][1]['por']=='Marcos')
ok('porteiro não acessa painel', 'ERRO' in rpc('painel_encomendas', p_token=m))
ok('painel busca por apto', len(rpc('painel_encomendas', p_token=s, p_busca='101'))>=3)
