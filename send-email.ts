// Supabase Edge Function: send-email
// Deploy with: supabase functions deploy send-email
// Uses the same RESEND_API_KEY secret as manager-users

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
    if (!RESEND_API_KEY) {
      return new Response(
        JSON.stringify({ error: "RESEND_API_KEY not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { to, from_email, from_name, subject, body, reply_to, skip_cc } = await req.json();

    if (!to || !subject || !body) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: to, subject, body" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Format the from address
    const from = from_name ? `${from_name} <${from_email}>` : from_email;

    // Skip CC if skip_cc flag is set, or if the recipient is the same as the CC address
    const ccAddress = "rob@prospectmanager.co.uk";
    const cc = (skip_cc || to.toLowerCase() === ccAddress.toLowerCase()) ? [] : [ccAddress];

    // Build Resend payload
    const resendPayload: Record<string, unknown> = {
      from,
      to: [to],
      subject,
      html: body,
    };
    if (cc.length) resendPayload.cc = cc;
    if (reply_to && reply_to.length) resendPayload.reply_to = reply_to;

    // Send via Resend API
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${RESEND_API_KEY}`,
      },
      body: JSON.stringify(resendPayload),
    });

    const data = await res.json();

    if (!res.ok) {
      console.error("Resend API error:", JSON.stringify(data));
      const errMsg = [data.name, data.message, data.statusCode ? `(${data.statusCode})` : ""].filter(Boolean).join(" — ") || "Failed to send email";
      return new Response(
        JSON.stringify({ error: errMsg, resend_response: data }),
        { status: res.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, id: data.id }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err.message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
