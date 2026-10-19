// Horus Hotel — fonction serveur « staff-admin » : comptes du personnel (code hôtel + identifiant + code à 4 chiffres).
// La clé d'administration ne quitte jamais le serveur. Seuls le propriétaire et les administrateurs de l'hôtel peuvent agir.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const ROLES = ["admin", "manager", "receptionist", "housekeeping", "accountant", "staff"];
export const staffEmail = (code: string, username: string) => `${username}.${code}@staff.horushotel.app`;
export const staffPassword = (code: string, username: string, pin: string) => `hh:${code}:${username}:${pin}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!, svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") || "";
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Connexion requise." }, 401);
  let body: Record<string, string>;
  try { body = await req.json(); } catch { return json({ error: "Requête invalide." }, 400); }
  const admin = createClient(url, svc, { auth: { persistSession: false } });
  const org = String(body.org || "");
  const { data: me } = await admin.from("organization_members").select("role,is_active").eq("organization_id", org).eq("user_id", user.id).maybeSingle();
  if (!me || !me.is_active || !["owner", "admin"].includes(me.role)) return json({ error: "Accès refusé." }, 403);
  const { data: o } = await admin.from("organizations").select("staff_code,name").eq("id", org).single();
  if (!o?.staff_code) return json({ error: "Code hôtel manquant." }, 400);
  const code = o.staff_code;
  const pinOk = (p: string) => /^\d{4}$/.test(p || "");

  if (body.action === "create") {
    const username = String(body.username || "").toLowerCase().trim();
    const role = String(body.role || "");
    const display = String(body.display_name || "").trim().slice(0, 80);
    if (!/^[a-z0-9]{2,20}$/.test(username)) return json({ error: "Identifiant : 2 à 20 lettres minuscules ou chiffres, sans espace ni accent." }, 400);
    if (!ROLES.includes(role) || (role === "admin" && me.role !== "owner")) return json({ error: "Poste non autorisé." }, 400);
    if (!pinOk(body.pin)) return json({ error: "Le code doit contenir exactement 4 chiffres." }, 400);
    const { data: exists } = await admin.from("organization_members").select("id").eq("organization_id", org).eq("username", username).maybeSingle();
    if (exists) return json({ error: "Cet identifiant est déjà utilisé dans votre établissement." }, 409);
    const { data: created, error: e1 } = await admin.auth.admin.createUser({
      email: staffEmail(code, username), password: staffPassword(code, username, body.pin), email_confirm: true,
      user_metadata: { staff: true, display_name: display, staff_code: code, username },
    });
    if (e1 || !created?.user) return json({ error: /already/i.test(e1?.message || "") ? "Cet identifiant existe déjà." : "Création impossible : " + (e1?.message || "erreur") }, 400);
    const { data: m, error: e2 } = await admin.from("organization_members").insert({
      organization_id: org, user_id: created.user.id, role, is_active: true, username, display_name: display || null,
      must_change_password: true, establishment_id: body.establishment_id || null,
    }).select("id").single();
    if (e2) { await admin.auth.admin.deleteUser(created.user.id); return json({ error: /Limite/.test(e2.message) ? e2.message : "Création impossible : " + e2.message }, 400); }
    await admin.from("audit_log").insert({ organization_id: org, entity: "equipe", entity_id: m.id, action: "creation", summary: `Compte personnel créé : ${display || username} (${role})`, details: { username, role }, actor_id: user.id, actor_role: me.role });
    return json({ ok: true, member_id: m.id, login: { code, username } });
  }

  const memberId = String(body.member_id || "");
  const { data: t } = await admin.from("organization_members").select("id,user_id,role,username,display_name").eq("id", memberId).eq("organization_id", org).maybeSingle();
  if (!t || !t.username) return json({ error: "Compte personnel introuvable." }, 404);
  if (t.role === "owner" || (t.role === "admin" && me.role !== "owner")) return json({ error: "Accès refusé." }, 403);
  const log = (action: string, summary: string) => admin.from("audit_log").insert({ organization_id: org, entity: "equipe", entity_id: t.id, action, summary, details: { username: t.username }, actor_id: user.id, actor_role: me.role });

  if (body.action === "reset") {
    if (!pinOk(body.pin)) return json({ error: "Le code doit contenir exactement 4 chiffres." }, 400);
    const { error } = await admin.auth.admin.updateUserById(t.user_id, { password: staffPassword(code, t.username, body.pin) });
    if (error) return json({ error: error.message }, 400);
    await admin.from("organization_members").update({ must_change_password: true }).eq("id", t.id);
    await log("reinitialisation", `Code réinitialisé : ${t.display_name || t.username}`);
    return json({ ok: true });
  }
  if (body.action === "suspend" || body.action === "reactivate") {
    const on = body.action === "reactivate";
    const { error } = await admin.from("organization_members").update({ is_active: on }).eq("id", t.id);
    if (error) return json({ error: error.message }, 400);
    await admin.auth.admin.updateUserById(t.user_id, { ban_duration: on ? "none" : "876000h" });
    await log(on ? "reactivation" : "suspension", `${on ? "Compte réactivé" : "Compte suspendu"} : ${t.display_name || t.username}`);
    return json({ ok: true });
  }
  if (body.action === "rename") {
    const display = String(body.display_name || "").trim().slice(0, 80);
    await admin.from("organization_members").update({ display_name: display || null }).eq("id", t.id);
    return json({ ok: true });
  }
  return json({ error: "Action inconnue." }, 400);
});
