// Nuittea Manager — fonction « receipt » : lien sécurisé vers le reçu d'un séjour.
// • POST { action: "link", reservation_id } (utilisateur connecté, accès vérifié par les règles d'accès) → { url }
// • POST { action: "get", t } (public) → données du reçu, uniquement pour le jeton signé correspondant
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const URL_ = Deno.env.get("SUPABASE_URL")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!, SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PAGE = Deno.env.get("RECEIPT_PAGE") || "https://ayekouen.github.io/horus-hotel/recu.html";
const admin = createClient(URL_, SVC, { auth: { persistSession: false } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function sign(id: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("receipt-v1:" + SVC), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(id)));
  return [...mac.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  try {
    let b: Record<string, string> = {}; try { b = await req.json(); } catch { /* vide */ }
    if (b.action === "link") {
      const uc = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false } });
      const { data: { user } } = await uc.auth.getUser();
      if (!user) return json({ error: "Connexion requise." }, 401);
      if (!UUID.test(b.reservation_id || "")) return json({ error: "Réservation inconnue." }, 400);
      const { data } = await uc.from("reservations").select("id").eq("id", b.reservation_id).maybeSingle();
      if (!data) return json({ error: "Réservation introuvable ou accès refusé." }, 403);
      return json({ url: `${PAGE}?t=${data.id}.${await sign(data.id)}` });
    }
    if (b.action === "get") {
      const [id, mac] = String(b.t || "").split(".");
      if (!UUID.test(id || "") || !mac || mac !== await sign(id)) return json({ error: "Lien de reçu invalide." }, 403);
      const { data: r } = await admin.from("reservation_balances").select("id,establishment_id,room_number,guest_name,check_in,check_out,nights,status,nightly_rate,discount,total_amount,paid,balance,extras,created_at").eq("id", id).maybeSingle();
      if (!r) return json({ error: "Reçu introuvable." }, 404);
      const [{ data: e }, { data: pay }, { data: ex }] = await Promise.all([
        admin.from("establishments").select("name,public_name,address,public_address,city,phone,public_phone,public_logo_url,currency").eq("id", r.establishment_id).maybeSingle(),
        admin.from("cash_movements").select("kind,method,amount,label,created_at").eq("reservation_id", id).in("kind", ["payment", "refund"]).order("created_at"),
        admin.from("extra_sales").select("label,qty,unit_price,total,created_at,status").eq("reservation_id", id).order("created_at"),
      ]);
      return json({ reservation: r, establishment: e, payments: pay || [], extras: (ex || []).filter((x) => x.status !== "cancelled") });
    }
    return json({ error: "Action inconnue." }, 400);
  } catch (e) { return json({ error: `Reçu : ${(e as Error).message || "erreur inattendue"}` }, 500); }
});
