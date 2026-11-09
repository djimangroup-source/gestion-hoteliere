// Nuittea Manager — fonction serveur « push » : notifications Web Push.
// • action « key » (utilisateur connecté) : renvoie la clé publique d'envoi (créée et gardée côté serveur au premier appel).
// • action « test » (utilisateur connecté) : envoie une notification d'essai à ses propres appareils.
// • action « flush » (appel interne, en-tête x-push-secret) : envoie les notifications en attente aux membres concernés.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APP_URL = Deno.env.get("APP_URL") || "https://ayekouen.github.io/horus-hotel/";
const admin = createClient(URL_, SVC, { auth: { persistSession: false } });

async function keys() {
  const { data } = await admin.from("push_keys").select("public_key, private_key, hook_secret").eq("key", "vapid").single();
  if (data && data.public_key && data.private_key) return data;
  const k = webpush.generateVAPIDKeys();
  await admin.from("push_keys").update({ public_key: k.publicKey, private_key: k.privateKey }).eq("key", "vapid").is("public_key", null);
  const { data: d2 } = await admin.from("push_keys").select("public_key, private_key, hook_secret").eq("key", "vapid").single();
  return d2!;
}

async function sendTo(subs: any[], payload: Record<string, unknown>) {
  const k = await keys();
  webpush.setVapidDetails("mailto:contact@nuittea.com", k.public_key, k.private_key);
  let ok = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 3600 });
      ok++;
      await admin.from("push_subscriptions").update({ failures: 0, last_sent_at: new Date().toISOString() }).eq("id", s.id);
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      // Abonnement expiré ou révoqué : on le retire ; autre erreur : on compte et on retire après 5 échecs
      if (code === 404 || code === 410 || (s.failures || 0) >= 4) await admin.from("push_subscriptions").delete().eq("id", s.id);
      else await admin.from("push_subscriptions").update({ failures: (s.failures || 0) + 1 }).eq("id", s.id);
    }
  }
  return ok;
}

Deno.serve(async (req) => {
  try { return await handle(req); } catch (e) { return json({ error: `Notifications : ${(e as Error).message || "erreur inattendue"}` }, 500); }
});

async function handle(req: Request) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  let b: Record<string, string> = {}; try { b = await req.json(); } catch { /* corps vide */ }

  // ---- Appel interne : vider la file d'envoi ----
  if (b.action === "flush") {
    const k = await keys();
    if (!k.hook_secret || req.headers.get("x-push-secret") !== k.hook_secret) return json({ error: "Accès refusé." }, 403);
    const { data: rows } = await admin.from("push_outbox").select("*").is("sent_at", null).order("id").limit(50);
    let total = 0;
    for (const n of rows || []) {
      // Marqué d'abord : deux appels simultanés n'envoient pas deux fois
      const { data: claimed } = await admin.from("push_outbox").update({ sent_at: new Date().toISOString() }).eq("id", n.id).is("sent_at", null).select("id");
      if (!claimed || !claimed.length) continue;
      const { data: mem } = await admin.from("organization_members").select("user_id, role, establishment_id").eq("organization_id", n.organization_id).eq("is_active", true);
      const users = (mem || []).filter((m) => n.roles.includes(m.role) && (!m.establishment_id || !n.establishment_id || m.establishment_id === n.establishment_id)).map((m) => m.user_id);
      if (!users.length) { await admin.from("push_outbox").update({ sent_count: 0 }).eq("id", n.id); continue; }
      const { data: subs } = await admin.from("push_subscriptions").select("*").eq("organization_id", n.organization_id).in("user_id", users);
      const target = (subs || []).filter((s) => (s.prefs || {})[n.kind] !== false);
      const sent = await sendTo(target, { title: n.title, body: n.body, url: APP_URL + (n.url || ""), tag: `${n.kind}-${n.id}` });
      await admin.from("push_outbox").update({ sent_count: sent }).eq("id", n.id);
      total += sent;
    }
    return json({ ok: true, sent: total });
  }

  // ---- Appels de l'application (utilisateur connecté) ----
  const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false } });
  const { data: { user } } = await uc.auth.getUser();
  if (!user) return json({ error: "Connexion requise." }, 401);

  if (b.action === "key") { const k = await keys(); return json({ key: k.public_key }); }
  if (b.action === "test") {
    const { data: subs } = await admin.from("push_subscriptions").select("*").eq("user_id", user.id);
    if (!subs || !subs.length) return json({ error: "Aucun appareil abonné." }, 404);
    const sent = await sendTo(subs, { title: "Nuittea Manager", body: "Les notifications fonctionnent sur cet appareil.", url: APP_URL, tag: "test" });
    return json({ ok: true, sent });
  }
  return json({ error: "Action inconnue." }, 400);
}
