// Nuittea — fonction serveur « geniuspay » : paiement en ligne par l'agrégateur Genius Pay.
// • action « subscription » (utilisateur connecté, propriétaire ou administrateur) : crée le paiement chez Genius Pay
//   pour un paiement d'abonnement déjà préparé par start_subscription_checkout, et renvoie le lien de paiement.
// • action « verify » : redemande le statut à Genius Pay et valide le paiement s'il est réglé (utile au retour du client).
// • appel de Genius Pay (webhook, en-tête X-Webhook-Signature) : signature vérifiée, statut redemandé, puis validation.
// Les montants viennent toujours de la base, jamais du navigateur. Les clés restent dans les secrets du serveur.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Noms acceptés pour les secrets (ceux saisis dans le tableau de bord Supabase compris)
const env = (...names: string[]) => { for (const n of names) { const v = (Deno.env.get(n) || "").trim(); if (v) return v; } return ""; };
const GP_KEY = env("GENIUSPAY_API_KEY", "GENIUS PAY API KEY", "GENIUS_PAY_API_KEY", "apigenius");
const GP_SECRET = env("GENIUSPAY_API_SECRET", "CLE API GENIUS SECRETE", "GENIUS_PAY_API_SECRET");
const GP_WH = env("GENIUSPAY_WEBHOOK_SECRET", "GENIUS PAY WEBHOOK SECRET", "GENIUS_PAY_WEBHOOK_SECRET");
const GP_BASE = (Deno.env.get("GENIUSPAY_BASE_URL") || "https://geniuspay.ci/api/v1/merchant").replace(/\/+$/, "");
const SANDBOX = /sandbox/.test(GP_KEY) || /sandbox/.test(GP_SECRET);
const APP_URL = Deno.env.get("APP_URL") || "https://ayekouen.github.io/horus-hotel/";
const admin = createClient(URL_, SVC, { auth: { persistSession: false } });

async function gp(path: string, init: RequestInit = {}) {
  const r = await fetch(GP_BASE + path, { ...init, headers: { "X-API-Key": GP_KEY, "X-API-Secret": GP_SECRET, "Content-Type": "application/json", "Accept": "application/json", ...(init.headers || {}) } });
  const t = await r.text(); let b: any = null; try { b = JSON.parse(t); } catch { b = { raw: t.slice(0, 300) }; }
  if (!r.ok) throw new Error((b && (b.message || b.error)) || `Genius Pay a répondu ${r.status}.`);
  return b && b.data ? b.data : b;
}
const DONE = ["completed", "success", "succeeded", "paid"], FAILED = ["failed", "cancelled", "canceled", "expired"];

// Valide (ou marque en échec) un paiement d'abonnement d'après le statut renvoyé par Genius Pay
async function settleSubscription(paymentId: string, gpPay: any) {
  const st = String(gpPay.status || "").toLowerCase();
  if (DONE.includes(st)) {
    const { data, error } = await admin.rpc("confirm_subscription_payment", { p_payment_id: paymentId, p_transaction_reference: gpPay.reference || null, p_payload: { provider: "geniuspay", environment: gpPay.environment || (SANDBOX ? "sandbox" : "live"), method: gpPay.payment_method || null, fees: gpPay.fees ?? null } });
    if (error) throw new Error(error.message);
    return { status: "succeeded", result: data };
  }
  if (FAILED.includes(st)) {
    await admin.rpc("fail_subscription_payment", { p_payment_id: paymentId, p_reason: `Genius Pay : ${st}` });
    return { status: "failed" };
  }
  return { status: "pending" };
}

async function hmacHex(secret: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg)));
  return Array.from(s).map((x) => x.toString(16).padStart(2, "0")).join("");
}
function safeEq(a: string, b: string) { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; }

Deno.serve(async (req) => {
  try { return await handle(req); } catch (e) { return json({ error: `Paiement en ligne : ${(e as Error).message || "erreur inattendue"}` }, 502); }
});

async function handle(req: Request) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  if (!GP_KEY || !GP_SECRET) return json({ error: "Le paiement en ligne n'est pas encore configuré." }, 503);
  const raw = await req.text();

  // ---- Appel de Genius Pay (webhook) ----
  const sig = req.headers.get("x-webhook-signature");
  if (sig) {
    if (!GP_WH) return json({ error: "Secret webhook absent." }, 503);
    const ts = req.headers.get("x-webhook-timestamp") || "";
    if (!/^\d+$/.test(ts) || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return json({ error: "Horodatage invalide." }, 401);
    const expected = await hmacHex(GP_WH, `${ts}.${raw}`);
    const given = sig.replace(/^sha256=/, "").trim().toLowerCase();
    if (!safeEq(expected, given)) return json({ error: "Signature invalide." }, 401);
    let evt: any; try { evt = JSON.parse(raw); } catch { return json({ error: "Contenu invalide." }, 400); }
    const ref = evt?.data?.reference;
    if (!ref) return json({ ok: true, ignored: true });
    // Double vérification : le statut fait foi seulement s'il est redemandé à Genius Pay
    const pay = await gp(`/payments/${encodeURIComponent(ref)}`);
    const md = pay.metadata || {};
    if (md.kind === "subscription" && md.payment_id) {
      const r = await settleSubscription(md.payment_id, pay);
      return json({ ok: true, ...r });
    }
    return json({ ok: true, ignored: true });
  }

  // ---- Appels de l'application (utilisateur connecté) ----
  let b: Record<string, string>; try { b = JSON.parse(raw || "{}"); } catch { return json({ error: "Requête invalide." }, 400); }
  const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false } });
  const { data: { user } } = await uc.auth.getUser();
  if (!user) return json({ error: "Connexion requise." }, 401);

  if (b.action === "subscription" || b.action === "verify") {
    const { data: pay } = await admin.from("payments").select("id, organization_id, amount, currency, status, payment_method, transaction_reference, metadata, plans(name)").eq("id", b.payment_id).maybeSingle();
    if (!pay) return json({ error: "Paiement introuvable." }, 404);
    const { data: m } = await admin.from("organization_members").select("role").eq("organization_id", pay.organization_id).eq("user_id", user.id).eq("is_active", true).maybeSingle();
    const { data: isAdm } = await uc.rpc("is_platform_admin");
    if (!isAdm && !(m && ["owner", "admin"].includes(m.role))) return json({ error: "Accès refusé." }, 403);
    // En mode test (clés sandbox), seul l'administrateur de la plateforme peut payer : aucun hôtel n'est prolongé avec de l'argent fictif.
    if (SANDBOX && !isAdm) return json({ error: "Le paiement en ligne est en cours de mise en service. Utilisez un autre moyen de paiement pour le moment." }, 403);

    if (b.action === "verify") {
      if (pay.status !== "pending") return json({ status: pay.status });
      if (!pay.transaction_reference) return json({ status: "pending" });
      const gpPay = await gp(`/payments/${encodeURIComponent(pay.transaction_reference)}`);
      return json(await settleSubscription(pay.id, gpPay));
    }

    if (pay.status !== "pending" || pay.payment_method !== "geniuspay") return json({ error: "Ce paiement ne peut plus être réglé en ligne." }, 409);
    const { data: org } = await admin.from("organizations").select("name").eq("id", pay.organization_id).maybeSingle();
    const back = (b.return_url && /^https:\/\//.test(b.return_url) ? b.return_url : APP_URL).split("#")[0];
    const sep = back.includes("?") ? "&" : "?";
    const created = await gp("/payments", { method: "POST", body: JSON.stringify({
      amount: pay.amount, currency: pay.currency || "XOF",
      description: `Abonnement Nuittea Manager · ${(pay as any).plans?.name || "formule"} · ${org?.name || ""}`.slice(0, 480),
      customer: { name: org?.name || "Client Nuittea", email: user.email || undefined, country: "CI" },
      success_url: `${back}${sep}gp=${pay.id}&gps=ok`, error_url: `${back}${sep}gp=${pay.id}&gps=ko`,
      metadata: { kind: "subscription", payment_id: pay.id, organization_id: pay.organization_id },
    }) });
    const url = created.checkout_url || created.payment_url;
    if (!url || !created.reference) return json({ error: "Genius Pay n'a pas renvoyé de lien de paiement." }, 502);
    await admin.from("payments").update({ transaction_reference: created.reference, metadata: { ...(pay.metadata || {}), geniuspay: { reference: created.reference, environment: created.environment || (SANDBOX ? "sandbox" : "live") } } }).eq("id", pay.id);
    return json({ ok: true, url, reference: created.reference, sandbox: SANDBOX });
  }

  return json({ error: "Action inconnue." }, 400);
}
