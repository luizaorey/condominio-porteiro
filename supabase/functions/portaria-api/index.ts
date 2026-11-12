// Condomínio – Porteiro · serviço de borda: OCR da etiqueta, fotos, envio WhatsApp (QR). Schema "portaria".
import QRCode from "npm:qrcode@1.5.4";
const URL_ = Deno.env.get("SUPABASE_URL")!;
const SVC = Deno.env.get("ISA_DB_KEY")!;           // service key (secret já existente no projeto)
const EVO = Deno.env.get("EVOLUTION_URL")!;
const EVO_KEY = Deno.env.get("EVOLUTION_APIKEY_ISA")!;
const EVO_INST = Deno.env.get("PORTARIA_EVOLUTION_INSTANCIA") ?? "isa";
const OPENAI = Deno.env.get("OPENAI_API_KEY");
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type", "Access-Control-Allow-Methods": "POST,OPTIONS" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const H = (extra = {}) => ({ apikey: SVC, Authorization: `Bearer ${SVC}`, "Content-Profile": "portaria", "Accept-Profile": "portaria", "Content-Type": "application/json", ...extra });

async function sessao(token: string) {           // sessão aberta + usuário ativo
  if (!/^[0-9a-f-]{36}$/.test(String(token))) return null;
  const s = await fetch(`${URL_}/rest/v1/sessoes?token=eq.${token}&encerrada_em=is.null&select=usuarios!inner(condominio_id,papel,ativo)`, { headers: H() });
  const a = await s.json(); const u = Array.isArray(a) && a[0]?.usuarios;
  return u && u.ativo ? { condominio: u.condominio_id, papel: u.papel } : null;
}

async function ocr(b64: string, mime: string) {
  if (!OPENAI) return { erro: "ocr_indisponivel" };
  const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { Authorization: `Bearer ${OPENAI}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: "gpt-4.1-mini", response_format: { type: "json_object" }, messages: [
      { role: "system", content: "Você lê etiquetas de encomendas entregues em condomínios brasileiros. Responda JSON: {\"destinatario\":string|null,\"bloco\":string|null,\"apartamento\":string|null,\"transportadora\":string|null,\"legivel\":boolean}. Só preencha o que estiver realmente visível; não invente." },
      { role: "user", content: [{ type: "text", text: "Leia a etiqueta." }, { type: "image_url", image_url: { url: `data:${mime};base64,${b64}` } }] }] }) });
  if (!r.ok) return { erro: "ocr_falhou" };
  try { return JSON.parse((await r.json()).choices[0].message.content); } catch { return { erro: "ocr_falhou" }; }
}

async function enviar(n: any) {
  const num = n.whatsapp.replace(/\D/g, "");
  let r: Response;
  if (n.tipo === "aviso") {
    const cod = (await (await fetch(`${URL_}/rest/v1/encomendas?id=eq.${n.encomenda_id}&select=codigo`, { headers: H() })).json())[0]?.codigo;
    const png = (await QRCode.toDataURL(cod, { width: 600, margin: 2 })).split(",")[1];
    r = await fetch(`${EVO}/message/sendMedia/${EVO_INST}`, { method: "POST", headers: { apikey: EVO_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ number: num, mediatype: "image", mimetype: "image/png", media: png, fileName: "qrcode.png", caption: n.mensagem }) });
  } else {
    r = await fetch(`${EVO}/message/sendText/${EVO_INST}`, { method: "POST", headers: { apikey: EVO_KEY, "Content-Type": "application/json" }, body: JSON.stringify({ number: num, text: n.mensagem }) });
  }
  if (!r.ok) throw new Error(`evolution ${r.status}: ${(await r.text()).slice(0, 200)}`);
}

async function processar(condominio: string) {
  const q = await fetch(`${URL_}/rest/v1/notificacoes?status=in.(pendente)&select=*,encomendas!inner(condominio_id)&encomendas.condominio_id=eq.${condominio}&order=criada_em&limit=20`, { headers: H() });
  const lista = await q.json(); let enviadas = 0, falhas = 0;
  for (const n of Array.isArray(lista) ? lista : []) {
    let erro: string | null = null;
    try { await enviar(n); } catch (e) { erro = String(e.message ?? e); }
    await fetch(`${URL_}/rest/v1/notificacoes?id=eq.${n.id}`, { method: "PATCH", headers: H(), body: JSON.stringify(
      erro ? { status: "falhou", erro, tentativas: n.tentativas + 1 } : { status: "enviado", enviada_em: new Date().toISOString(), tentativas: n.tentativas + 1, erro: null }) });
    if (erro) { falhas++; await fetch(`${URL_}/rest/v1/eventos`, { method: "POST", headers: H(), body: JSON.stringify({ encomenda_id: n.encomenda_id, tipo: n.tipo === "aviso" ? "aviso_falhou" : "aviso_retirada_falhou", dados: { erro } }) }); } else enviadas++;
  }
  return { enviadas, falhas };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  try {
    const b = await req.json(); const s = await sessao(b.token);
    if (!s) return json({ erro: "sessao_invalida" }, 401);
    if (b.acao === "foto") {                         // guarda a foto e (opcional) lê a etiqueta
      if (s.papel !== "porteiro") return json({ erro: "sem_permissao" }, 403);
      const path = `${s.condominio}/${crypto.randomUUID()}.jpg`;
      const bin = Uint8Array.from(atob(b.imagem), (c) => c.charCodeAt(0));
      const up = await fetch(`${URL_}/storage/v1/object/portaria-fotos/${path}`, { method: "POST", headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, "Content-Type": "image/jpeg" }, body: bin });
      if (!up.ok) return json({ erro: "upload_falhou" }, 500);
      return json({ foto_path: path, ocr: b.ler === false ? null : await ocr(b.imagem, "image/jpeg") });
    }
    if (b.acao === "foto_url") {                     // URL assinada p/ ver a foto (só do próprio condomínio)
      if (!String(b.path).startsWith(s.condominio + "/")) return json({ erro: "sem_permissao" }, 403);
      const r = await fetch(`${URL_}/storage/v1/object/sign/portaria-fotos/${b.path}`, { method: "POST", headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, "Content-Type": "application/json" }, body: JSON.stringify({ expiresIn: 600 }) });
      const d = await r.json(); return json({ url: `${URL_}/storage/v1${d.signedURL}` });
    }
    if (b.acao === "processar") return json(await processar(s.condominio));
    return json({ erro: "acao_desconhecida" }, 400);
  } catch (e) { return json({ erro: String(e.message ?? e) }, 500); }
});
