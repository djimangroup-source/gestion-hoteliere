// demo-access : comptes de démonstration Nuittea Manager (organisation isolée « Hôtel Démo Nuittea »).
// Réservé à l'équipe Nuittea ayant l'accès « demo ». Ne génère de lien de connexion que pour les comptes de démonstration.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APP = "https://ayekouen.github.io/horus-hotel/";
const ROLES: Record<string, string> = {
  owner: "Propriétaire (démo)", manager: "Gérant (démo)", receptionist: "Réceptionniste (démo)",
  housekeeping: "Agent de ménage (démo)", accountant: "Comptable (démo)", staff: "Employé (démo)",
};
const emailOf = (r: string) => `demo.${r}@demo.nuittea.app`;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function ensureUsers(admin: ReturnType<typeof createClient>) {
  const { data } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  const byEmail = new Map((data?.users || []).map((u) => [u.email?.toLowerCase(), u.id]));
  const out: { user_id: string; role: string; name: string }[] = [];
  for (const [role, name] of Object.entries(ROLES)) {
    let id = byEmail.get(emailOf(role));
    if (!id) {
      const { data: c, error } = await admin.auth.admin.createUser({ email: emailOf(role), email_confirm: true, user_metadata: { demo: true, full_name: name } });
      if (error) throw new Error(error.message);
      id = c.user!.id;
    }
    out.push({ user_id: id!, role, name });
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization") || "";
    const user = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
    const { data: ok, error: e1 } = await user.rpc("staff_can", { p_perm: "demo" });
    if (e1 || ok !== true) return json({ error: "Accès refusé." }, 403);
    const { data: me } = await user.auth.getUser();
    const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
    const { action, role } = await req.json();

    const seed = async () => {
      const users = await ensureUsers(admin);
      const { error } = await admin.rpc("demo_seed", { p_users: users });
      if (error) throw new Error(error.message);
    };
    const log = (a: string, d: Record<string, unknown>) =>
      admin.from("platform_audit").insert({ actor: me.user?.id, action: a, target_type: "demo", target_id: role || "all", detail: d });

    if (action === "reset") {
      await seed();
      await log("demo_reinitialisee", {});
      return json({ ok: true });
    }
    if (action === "login") {
      if (!ROLES[role]) return json({ error: "Rôle inconnu." }, 400);
      const { data: org } = await admin.from("organizations").select("id").eq("is_test", true).eq("name", "Hôtel Démo Nuittea").maybeSingle();
      if (!org) await seed();
      else await ensureUsers(admin);
      const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email: emailOf(role), options: { redirectTo: APP } });
      if (error) return json({ error: error.message }, 500);
      await log("demo_connexion", { role });
      return json({ ok: true, link: data.properties.action_link, role: ROLES[role] });
    }
    return json({ error: "Action inconnue." }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
