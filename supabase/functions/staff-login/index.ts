// Horus Hotel — fonction serveur « staff-login » : connexion du personnel (code hôtel + identifiant + code).
// • Le mot de passe réel est dérivé avec une clé secrète serveur : impossible de tester les codes directement auprès de l'authentification.
// • Verrouillage : 5 échecs sur un compte => 15 min ; 30 échecs depuis une même adresse => 1 h.
// • Action « change_pin » (utilisateur connecté) : changement du code personnel.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(URL_, SVC, { auth: { persistSession: false } });
const staffEmail = (code: string, user: string) => `${user}.${code}@staff.horushotel.app`;
let PEPPER: string | null = null;
async function staffPassword(code: string, user: string, pin: string) {
  if (!PEPPER) { const { data } = await admin.from("server_secrets").select("value").eq("name", "staff_pepper").single(); PEPPER = data!.value; }
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(PEPPER!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${code}|${user}|${pin}`)));
  return "hk1:" + btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function attempt(key: string) { const { data } = await admin.from("staff_login_attempts").select("*").eq("key", key).maybeSingle(); return data; }
async function fail(key: string, max: number, lockMin: number) {
  const a = await attempt(key); const n = (a && (!a.locked_until || new Date(a.locked_until) < new Date()) && a.failures >= max ? 0 : (a ? a.failures : 0)) + 1;
  await admin.from("staff_login_attempts").upsert({ key, failures: n, locked_until: n >= max ? new Date(Date.now() + lockMin * 60000).toISOString() : null, updated_at: new Date().toISOString() });
  return n;
}
const locked = (a: any) => a && a.locked_until && new Date(a.locked_until) > new Date();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  let b: Record<string, string>; try { b = await req.json(); } catch { return json({ error: "Requête invalide." }, 400); }

  if (b.action === "change_pin") {
    const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
    const { data: { user } } = await uc.auth.getUser();
    const md = (user && user.user_metadata) || {};
    if (!user || !md.staff) return json({ error: "Connexion requise." }, 401);
    if (!/^\d{4}$/.test(b.pin || "") || /^(\d)\1{3}$/.test(b.pin) || ["1234", "4321", "0123", "9876"].includes(b.pin)) return json({ error: "Code trop simple : évitez 1111 ou 1234." }, 400);
    const { error } = await admin.auth.admin.updateUserById(user.id, { password: await staffPassword(md.staff_code, md.username, b.pin) });
    if (error) return json({ error: error.message }, 400);
    await admin.from("organization_members").update({ must_change_password: false }).eq("user_id", user.id);
    return json({ ok: true });
  }

  const code = String(b.code || "").trim().toLowerCase(), user = String(b.username || "").trim().toLowerCase(), pin = String(b.pin || "");
  if (!/^[a-z0-9]{3,20}$/.test(code) || !/^[a-z0-9]{2,20}$/.test(user) || !/^\d{4}$/.test(pin)) return json({ error: "Code hôtel, identifiant ou code incorrect." }, 400);
  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "inconnue";
  const kAcc = `acc:${code}:${user}`, kIp = `ip:${ip}`;
  const [aAcc, aIp] = await Promise.all([attempt(kAcc), attempt(kIp)]);
  if (locked(aAcc)) return json({ error: "Trop d’essais : ce compte est bloqué 15 minutes. Votre responsable peut aussi vous donner un nouveau code.", locked: true }, 429);
  if (locked(aIp)) return json({ error: "Trop d’essais depuis cet appareil. Réessayez dans une heure.", locked: true }, 429);
  const uc = createClient(URL_, ANON, { auth: { persistSession: false } });
  const { data, error } = await uc.auth.signInWithPassword({ email: staffEmail(code, user), password: await staffPassword(code, user, pin) });
  if (error || !data.session) {
    if (/banned/i.test(error?.message || "")) return json({ error: "Ce compte est suspendu. Contactez votre responsable." }, 403);
    const n = await fail(kAcc, 5, 15); await fail(kIp, 30, 60);
    const left = Math.max(0, 5 - n);
    return json({ error: left ? `Code hôtel, identifiant ou code incorrect. ${left} essai${left > 1 ? "s" : ""} restant${left > 1 ? "s" : ""}.` : "Trop d’essais : ce compte est bloqué 15 minutes." }, 401);
  }
  await admin.from("staff_login_attempts").delete().eq("key", kAcc);
  return json({ ok: true, access_token: data.session.access_token, refresh_token: data.session.refresh_token });
});
