// Server-side enforcement of explicit AI processing consent.
//
// Several endpoints forward user-derived health data to OpenRouter (an
// external subprocessor): insight prediction, food image/label/batch analysis
// and free-text parsing, plus the client-facing openrouter-gateway. Consent is
// stored on privacy_settings.ai_processing_consent (default FALSE) and must be
// enforced server-side, not just hidden in the UI, mirroring how analytics
// consent gates analytics_events ingestion.
//
// Lookup failures fail CLOSED: without a confirmed consent answer no health
// data leaves the platform.

import { json, serviceRoleClient } from "./supabase.ts";

export async function enforceAIProcessingConsent(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
): Promise<Response | null> {
  const { data, error } = await service
    .from("privacy_settings")
    .select("ai_processing_consent")
    .eq("user_id", userId)
    .maybeSingle<{ ai_processing_consent: boolean | null }>();

  if (error) {
    // Fail closed: unverifiable consent means no third-party processing.
    return json({ error: "ai_consent_lookup_failed" }, 503);
  }

  if (!(data?.ai_processing_consent ?? false)) {
    return json({ error: "ai_processing_consent_required" }, 403);
  }
  return null;
}
