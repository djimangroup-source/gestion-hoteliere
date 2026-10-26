// Horus Hotel — fonction serveur « admin-tools » (administrateur plateforme uniquement).
// Action « create_test_account » : crée un compte propriétaire de test, son hôtel (marqué « test », jamais visible
// dans la recherche NAYA) et quelques chambres d'exemple. Le mot de passe est généré ici et renvoyé une seule fois.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const rand = (n: number, set: string) => { const b = crypto.getRandomValues(new Uint32Array(n)); return Array.from(b, (x) => set[x % set.length]).join(""); };
const password = () => rand(4, "ABCDEFGHJKLMNPQRSTUVWXYZ") + "-" + rand(4, "abcdefghijkmnpqrstuvwxyz") + "-" + rand(4, "23456789");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
  const { data: { user } } = await uc.auth.getUser();
  if (!user) return json({ error: "Connexion requise." }, 401);
  const { data: isAdmin } = await uc.rpc("is_platform_admin");
  if (isAdmin !== true) return json({ error: "Réservé à l'administrateur plateforme." }, 403);
  let b: Record<string, unknown>; try { b = await req.json(); } catch { return json({ error: "Requête invalide." }, 400); }

  if (b.action === "create_test_account") {
    const hotel = String(b.hotel || "").trim().slice(0, 80) || "Hôtel test";
    const city = String(b.city || "").trim().slice(0, 60) || "Abidjan";
    const kind = b.kind === "residence" ? "residence" : "hotel";
    const admin = createClient(URL_, SVC, { auth: { persistSession: false } });
    const email = `test-${rand(6, "abcdefghjkmnpqrstuvwxyz23456789")}@test.horushotel.app`;
    const pwd = password();
    const { data: cu, error: e1 } = await admin.auth.admin.createUser({ email, password: pwd, email_confirm: true, user_metadata: { test_account: true, created_by_admin: user.id } });
    if (e1 || !cu.user) return json({ error: e1?.message || "Création du compte impossible." }, 400);
    // Création de l'hôtel au nom du compte de test (mêmes règles que l'inscription normale)
    const tc = createClient(URL_, ANON, { auth: { persistSession: false } });
    const { data: s, error: e2 } = await tc.auth.signInWithPassword({ email, password: pwd });
    if (e2 || !s.session) { await admin.auth.admin.deleteUser(cu.user.id); return json({ error: "Connexion du compte de test impossible." }, 500); }
    const as = createClient(URL_, ANON, { global: { headers: { Authorization: `Bearer ${s.session.access_token}` } }, auth: { persistSession: false } });
    const { data: org, error: e3 } = await as.rpc("create_organization", { p_org_name: hotel, p_establishment_name: hotel, p_city: city });
    if (e3 || !org) { await admin.auth.admin.deleteUser(cu.user.id); return json({ error: e3?.message || "Création de l'hôtel impossible." }, 400); }
    await admin.from("organizations").update({ is_test: true }).eq("id", org);
    const { data: est } = await admin.from("establishments").select("id").eq("organization_id", org).limit(1).single();
    const rooms = kind === "residence"
      ? [["A1", "Studio", 20000, 2], ["A2", "Studio", 20000, 2], ["B1", "Appartement 2 pièces", 35000, 3], ["C1", "Appartement 3 pièces", 50000, 5]]
      : [["101", "Standard", 15000, 2], ["102", "Standard", 15000, 2], ["201", "Supérieure", 25000, 2], ["301", "Suite", 45000, 4]];
    if (est) await admin.from("rooms").insert(rooms.map(([n, t, p, c]) => ({ organization_id: org, establishment_id: est.id, number: n, room_type: t, base_rate: p, capacity: c })));
    await tc.auth.signOut();
    const { data: o } = await admin.from("organizations").select("staff_code").eq("id", org).single();
    await admin.from("subscription_events").insert({ organization_id: org, event_type: "admin_test_account_created", details: { email, kind }, actor_id: user.id });
    return json({ ok: true, email, password: pwd, hotel, city, staff_code: o?.staff_code || null, organization_id: org });
  }
  return json({ error: "Action inconnue." }, 400);
});
