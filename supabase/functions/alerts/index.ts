// alerts : envoi des alertes e-mail de la console Nuittea via Resend.
// Déclenchée par le planificateur de la base (en-tête secret) ou par un membre de l'équipe pour un e-mail de test.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND = Deno.env.get("RESEND_API_KEY") || "";
const FROM = Deno.env.get("ALERTS_FROM") || "Console Nuittea <onboarding@resend.dev>";
const CONSOLE = "https://ayekouen.github.io/horus-hotel/admin.html";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const page = (title: string, inner: string) => `<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:#13212C">
  <div style="background:#0F2A3D;color:#fff;padding:14px 18px;border-radius:10px 10px 0 0;font-weight:bold">Nuittea · Console</div>
  <div style="border:1px solid #E3E8EC;border-top:0;padding:18px;border-radius:0 0 10px 10px"><h2 style="margin:0 0 12px;font-size:18px">${esc(title)}</h2>${inner}
  <p style="margin-top:18px"><a href="${CONSOLE}" style="background:#1F7AB8;color:#fff;padding:9px 14px;border-radius:8px;text-decoration:none">Ouvrir la console</a></p>
  <p style="color:#5E6E7A;font-size:12px">Vous recevez cet e-mail car vous faites partie de l'équipe Nuittea. Réglez vos alertes dans Réglages.</p></div></div>`;

async function send(to: string, subject: string, html: string) {
  if (!RESEND) throw new Error("Clé Resend absente (secret RESEND_API_KEY).");
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) throw new Error(`Resend ${r.status} : ${(await r.text()).slice(0, 300)}`);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  try {
    const body = await req.json().catch(() => ({}));
    const action = body.action;

    // E-mail de test, demandé depuis la console par un membre de l'équipe
    if (action === "test") {
      const auth = req.headers.get("Authorization") || "";
      const user = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
      const { data: ok } = await user.rpc("staff_can", { p_perm: "dashboard" });
      if (ok !== true) return json({ error: "Accès refusé." }, 403);
      const { data: me } = await user.auth.getUser(auth.replace(/^Bearer /, ""));
      await send(me.user!.email!, "Test des alertes Nuittea", page("Les alertes e-mail fonctionnent", "<p>Cet e-mail confirme que la console Nuittea peut vous envoyer des alertes.</p>"));
      return json({ ok: true, to: me.user!.email });
    }

    // Appels du planificateur : en-tête secret obligatoire
    const { data: k } = await admin.from("email_keys").select("hook_secret").eq("key", "alerts").maybeSingle();
    if (!k || req.headers.get("x-alerts-secret") !== k.hook_secret) return json({ error: "Accès refusé." }, 403);

    const { data: staff } = await admin.from("platform_staff").select("user_id,email,alert_instant,alert_weekly").eq("is_active", true);
    const perms = new Map<string, string[]>();
    for (const s of staff || []) {
      const { data } = await admin.rpc("platform_perms", { p_uid: s.user_id });
      perms.set(s.user_id, (data as string[]) || []);
    }

    if (action === "flush") {
      const { data: items } = await admin.from("email_outbox").select("*").is("sent_at", null).is("error", null).order("id").limit(20);
      for (const it of items || []) {
        const to = (staff || []).filter((s) => s.alert_instant && s.email && (perms.get(s.user_id) || []).includes(it.perm));
        try {
          for (const s of to) await send(s.email!, it.subject, page(it.subject, `<p style="white-space:pre-wrap">${esc(it.body)}</p>`));
          await admin.from("email_outbox").update({ sent_at: new Date().toISOString() }).eq("id", it.id);
        } catch (e) {
          await admin.from("email_outbox").update({ error: String((e as Error).message).slice(0, 500) }).eq("id", it.id);
        }
      }
      return json({ ok: true, sent: (items || []).length });
    }

    if (action === "weekly") {
      const { data: d, error } = await admin.rpc("alerts_weekly_digest");
      if (error) throw new Error(error.message);
      const g = d as Record<string, any>, list = (a: string[]) => a.length ? `<ul>${a.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>` : "<p style='color:#5E6E7A'>Aucun.</p>";
      const fmt = (n: number) => Math.round(n).toLocaleString("fr-FR").replace(/\s/g, " ") + " F";
      const html = page("Point hebdomadaire", `
        <table style="width:100%;border-collapse:collapse;margin-bottom:12px">
          <tr><td>Réservations Nuittea.com (7 jours)</td><td style="text-align:right"><b>${g.naya_resas}</b></td></tr>
          <tr><td>Abonnements encaissés (7 jours)</td><td style="text-align:right"><b>${fmt(g.paid)}</b></td></tr>
          <tr><td>Nouveaux clients</td><td style="text-align:right"><b>${g.new_orgs}</b></td></tr>
          <tr><td>Fiches à vérifier</td><td style="text-align:right"><b>${g.to_review}</b></td></tr>
          <tr><td>Signalements nouveaux</td><td style="text-align:right"><b>${g.reports}</b></td></tr>
          <tr><td>Demandes d'assistance ouvertes</td><td style="text-align:right"><b>${g.tickets}</b></td></tr>
          <tr><td>Tâches à échéance sous 7 jours</td><td style="text-align:right"><b>${g.tasks_open}</b></td></tr></table>
        <h3 style="font-size:15px">Échéances dans les 7 prochains jours</h3>${list(g.expiring)}
        <h3 style="font-size:15px">Abonnements expirés récemment</h3>${list(g.expired)}
        <h3 style="font-size:15px">Clients sans connexion depuis 10 jours</h3>${list(g.inactive)}`);
      for (const s of (staff || []).filter((x) => x.alert_weekly && x.email && (perms.get(x.user_id) || []).includes("dashboard"))) {
        try { await send(s.email!, "Nuittea · Point hebdomadaire", html); } catch (_) { /* adresse non autorisée sans domaine vérifié */ }
      }
      return json({ ok: true });
    }
    return json({ error: "Action inconnue." }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
