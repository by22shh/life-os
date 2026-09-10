import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";
import { assertMatch } from "https://deno.land/std@0.224.0/assert/assert_match.ts";

type JsonValue = null | boolean | number | string | JsonValue[] | {
  [key: string]: JsonValue;
};

interface HttpResponse {
  status: number;
  body: JsonValue | string | null;
  headers: Headers;
  rawText: string;
}

interface AuthSession {
  accessToken: string;
  authUserId: string;
  email: string;
}

interface EnvConfig {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
}

const LOCAL_FUNCTION_URL = "http://127.0.0.1:8000";
const REPO_ROOT = new URL("../../../", import.meta.url);

const env = loadEnv();
const auth = await createAuthSession(env);
const publicUserId = await waitForPublicUser(env, auth.authUserId, auth.email);
const stressAuth = await createAuthSession(env);
const stressPublicUserId = await waitForPublicUser(
  env,
  stressAuth.authUserId,
  stressAuth.email,
);
const watchScenario = createWatchScenarioState();
const immediateReceiptToken = crypto.randomUUID().replaceAll("-", "") +
  crypto.randomUUID().replaceAll("-", "");

await runFunctionScenario(
  "api-vector-memory-worker",
  "../api/vector_memory/worker/index.ts",
  async () => {
    const rejected = await requestJson(LOCAL_FUNCTION_URL, "/", {
      method: "POST",
      headers: jsonAuthHeaders(auth.accessToken),
      body: "{}",
    });
    assertEquals(rejected.status, 401);
    const idle = await requestJson(LOCAL_FUNCTION_URL, "/", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.serviceRoleKey}`,
        apikey: env.serviceRoleKey,
        "Content-Type": "application/json",
        "X-Vector-Memory-Worker": "scheduled",
      },
      body: "{}",
    });
    assertEquals(idle.status, 200);
    assertEquals(objectValue(idle.body, "processed"), 0);
  },
);

await runFunctionScenario(
  "api-settings-notifications",
  "../api/settings/notifications/index.ts",
  async () => {
    const correlationId = `edge-e2e-corr-${crypto.randomUUID()}`;
    const malformedAuth = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: {
          Authorization: "Basic malformed",
        },
      },
    );
    assertEquals(malformedAuth.status, 401);

    const initial = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: {
          ...authHeaders(auth.accessToken),
          "X-Correlation-Id": correlationId,
        },
      },
    );
    assertEquals(initial.status, 200);
    assertEquals(initial.headers.get("X-Correlation-Id"), correlationId);
    assertEquals(
      typeof objectValue(initial.body, "max_total_per_day"),
      "number",
    );

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ critical_only: true }),
      },
    );
    assertEquals(patched.status, 200);
    assertEquals(objectValue(patched.body, "critical_only"), true);
    assertEquals(objectValue(patched.body, "control_level"), "advisory");

    const criticalGuardianPayload = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          critical_only: true,
          control_level: "guardian",
          focus_control_enabled: false,
        }),
      },
    );
    assertEquals(criticalGuardianPayload.status, 200);
    assertEquals(
      objectValue(criticalGuardianPayload.body, "critical_only"),
      true,
    );
    assertEquals(
      objectValue(criticalGuardianPayload.body, "control_level"),
      "advisory",
    );
    assertEquals(
      objectValue(criticalGuardianPayload.body, "focus_control_enabled"),
      false,
    );

    const enableGuardian = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          critical_only: false,
          control_level: "guardian",
          focus_control_enabled: true,
        }),
      },
    );
    assertEquals(enableGuardian.status, 200);
    assertEquals(objectValue(enableGuardian.body, "critical_only"), false);
    assertEquals(objectValue(enableGuardian.body, "control_level"), "guardian");
    assertEquals(
      objectValue(enableGuardian.body, "focus_control_enabled"),
      true,
    );

    const guardianWithoutFocus = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          focus_control_enabled: false,
        }),
      },
    );
    assertEquals(guardianWithoutFocus.status, 400);
    assertEquals(
      objectValue(guardianWithoutFocus.body, "error"),
      "guardian_requires_focus_control",
    );

    const criticalOnlyOverridesGuardian = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          critical_only: true,
          control_level: "guardian",
          focus_control_enabled: true,
        }),
      },
    );
    assertEquals(criticalOnlyOverridesGuardian.status, 200);
    assertEquals(
      objectValue(criticalOnlyOverridesGuardian.body, "control_level"),
      "advisory",
    );
    assertEquals(
      objectValue(criticalOnlyOverridesGuardian.body, "focus_control_enabled"),
      false,
    );
  },
);

await runFunctionScenario(
  "api-settings-privacy",
  "../api/settings/privacy/index.ts",
  async () => {
    const cleanupScanId = crypto.randomUUID();
    const invalidBearer = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: {
          Authorization: "Bearer",
        },
      },
    );
    assertEquals(invalidBearer.status, 401);

    const initial = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(initial.status, 200);

    const updated = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          analytics_consent: true,
          medical_scan_local_only: false,
          cloud_backup_enabled: true,
        }),
      },
    );
    assertEquals(updated.status, 200);
    assertEquals(objectValue(updated.body, "analytics_consent"), true);
    assertEquals(objectValue(updated.body, "medical_scan_local_only"), false);
    assertEquals(objectValue(updated.body, "cloud_backup_enabled"), true);

    await upsertRestRows(env, "user_health_flags", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      has_pacemaker: true,
    });

    await upsertRestRows(env, "medical_scans", {
      id: cleanupScanId,
      user_id: publicUserId,
      scan_type: "blood_test",
      scan_date: "2026-02-20",
      status: "completed",
      storage_mode: "cloud",
      store_original_in_cloud: true,
      image_url: `${auth.authUserId}/${cleanupScanId}/original.pdf`,
      original_image_url: `${auth.authUserId}/${cleanupScanId}/original.pdf`,
      image_uploaded_at: "2026-02-20T09:00:00Z",
      scheduled_deletion_at: "2026-05-21T09:00:00Z",
      extraction_status: "completed",
      markers_extracted: 0,
      created_at: "2026-02-20T09:00:00Z",
      updated_at: "2026-02-20T09:00:00Z",
      processed_data: null,
      pinned_by_user: false,
      notes: null,
      source_file_sha256: null,
      document_language: null,
      ocr_confidence: null,
      ai_confidence: null,
      manually_verified: false,
      needs_review: false,
      user_reviewed: false,
      user_reviewed_at: null,
      deleted_at: null,
    });

    const revoked = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          cloud_backup_enabled: false,
        }),
      },
    );
    assertEquals(revoked.status, 200, JSON.stringify(revoked.body));
    assertEquals(objectValue(revoked.body, "cloud_backup_enabled"), false);

    const cleanedScans = await fetchRestRows(
      env,
      "medical_scans",
      { id: `eq.${cleanupScanId}` },
      "image_url,original_image_url,image_uploaded_at,store_original_in_cloud,scheduled_deletion_at",
    );
    assertEquals(cleanedScans.length, 1);
    assertEquals(objectValue(cleanedScans[0], "image_url"), null);
    assertEquals(objectValue(cleanedScans[0], "original_image_url"), null);
    assertEquals(objectValue(cleanedScans[0], "image_uploaded_at"), null);
    assertEquals(
      objectValue(cleanedScans[0], "store_original_in_cloud"),
      false,
    );
    assertEquals(objectValue(cleanedScans[0], "scheduled_deletion_at"), null);

    const flagsAfterRevoke = await fetchRestRows(
      env,
      "user_health_flags",
      { user_id: `eq.${publicUserId}` },
      "id",
    );
    assertEquals(flagsAfterRevoke.length, 0);
  },
);

let exportId = "";
let exportDownloadPath = "";
await runFunctionScenario(
  "api-user-export",
  "../api/user/export/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({}),
      },
    );
    assertEquals(created.status, 202);
    exportId = String(objectValue(created.body, "export_id"));
    assertMatch(exportId, /^[0-9a-f-]{36}$/i);

    const invalidPayload = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ export_id: 42 }),
      },
    );
    assertEquals(invalidPayload.status, 400);
  },
);

await runFunctionScenario(
  "api-user-export-status",
  "../api/user/export_status/index.ts",
  async () => {
    const statusRes = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ export_id: exportId }),
      },
    );
    assertEquals(statusRes.status, 200);
    assertEquals(objectValue(statusRes.body, "export_id"), exportId);
    exportDownloadPath = (() => {
      const rawUrl = String(objectValue(statusRes.body, "download_url"));
      const parsed = new URL(rawUrl);
      return `/?${parsed.searchParams.toString()}`;
    })();
    assertMatch(exportDownloadPath, /^\/\?export_id=[0-9a-f-]+&token=/i);

    const missingId = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({}),
      },
    );
    assertEquals(missingId.status, 400);
  },
);

await runFunctionScenario(
  "api-user-export-download",
  "../api/user/export_download/index.ts",
  async () => {
    const downloadRes = await requestJson(
      LOCAL_FUNCTION_URL,
      exportDownloadPath,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(downloadRes.status, 200);
    assertMatch(
      downloadRes.headers.get("Content-Disposition") ?? "",
      /^attachment; filename="lifeos_export_/,
    );
    objectValue(downloadRes.body, "profile");
    objectValue(
      objectValue(downloadRes.body, "settings"),
      "notification_settings",
    );
  },
);

await runFunctionScenario(
  "api-notifications-register-device",
  "../api/notifications/register_device/index.ts",
  async () => {
    const registered = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          device_id: "edge-e2e-device",
          push_token: "deadbeef1234",
          platform: "ios",
          environment: "development",
          locale: "en-US",
          timezone: "UTC",
          app_version: "1.0",
          build_number: "1",
        }),
      },
    );
    assertEquals(registered.status, 200);
    assertEquals(objectValue(registered.body, "status"), "registered");
    assertEquals(objectValue(registered.body, "device_id"), "edge-e2e-device");
  },
);

await runFunctionScenario(
  "api-notifications-unregister-device",
  "../api/notifications/unregister_device/index.ts",
  async () => {
    const unregistered = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          device_id: "edge-e2e-device",
          push_token: "deadbeef1234",
        }),
      },
    );
    assertEquals(unregistered.status, 200);
    assertEquals(objectValue(unregistered.body, "status"), "unregistered");
  },
);

await runFunctionScenario(
  "api-watch-snapshot",
  "../api/watch/snapshot/index.ts",
  async () => {
    await resetAndSeedWatchScenario(env, publicUserId);

    const okRes = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ date: watchScenario.date }),
      },
    );
    assertEquals(okRes.status, 200);
    assertEquals(objectValue(okRes.body, "date"), watchScenario.date);
    assertEquals(
      objectValue(objectValue(okRes.body, "next_best_action"), "type"),
      "supplement_taken",
    );
    assertEquals(
      objectValue(objectValue(okRes.body, "next_best_action"), "label_copy_id"),
      "supplements.log_primary",
    );
    const nextActionPayload = objectValue(
      objectValue(okRes.body, "next_best_action"),
      "payload",
    );
    assertEquals(
      objectValue(nextActionPayload, "supplement_name"),
      watchScenario.supplementName,
    );
    assertEquals(
      objectValue(nextActionPayload, "scheduled_time"),
      watchScenario.dueTime,
    );
    assertEquals(
      objectValue(objectValue(okRes.body, "supplements_due_soon"), "time"),
      watchScenario.dueTime,
    );
    assertEquals(
      objectValue(objectValue(okRes.body, "supplements_due_soon"), "count"),
      1,
    );
    assertEquals(objectValue(okRes.body, "nutrition_adherence_percent"), 84);

    const badDate = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ date: "22-02-2026" }),
      },
    );
    assertEquals(badDate.status, 400);
  },
);

const foodLogId = crypto.randomUUID();
await runFunctionScenario(
  "api-food-log",
  "../api/food/log/index.ts",
  async () => {
    const payload = {
      id: foodLogId,
      logged_at: "2026-02-22T10:00:00.000Z",
      logged_date: "2026-02-22",
      input_method: "manual",
      calories: 420,
      protein_g: 30,
      fat_g: 12,
      carbs_g: 55,
      context: "home",
      meal_type: "lunch",
    };

    const first = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": foodLogId,
        },
        body: JSON.stringify(payload),
      },
    );
    assertEquals(first.status, 202);

    const replay = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": foodLogId,
        },
        body: JSON.stringify(payload),
      },
    );
    assertEquals(replay.status, 202);
    assertEquals(replay.headers.get("X-Idempotent-Replay"), "true");

    const malformedReplayHeaderCalls: HttpResponse[] = [];
    for (let i = 0; i < 31; i += 1) {
      malformedReplayHeaderCalls.push(
        await requestJson(
          LOCAL_FUNCTION_URL,
          "/",
          {
            method: "POST",
            headers: {
              ...jsonAuthHeaders(stressAuth.accessToken),
              "X-Outbox-Replay": "true, true",
            },
            body: JSON.stringify({
              id: crypto.randomUUID(),
              logged_at: "2026-02-22T11:00:00.000Z",
              logged_date: "2026-02-22",
              input_method: "manual",
              calories: 300,
              protein_g: 20,
              fat_g: 8,
              carbs_g: 40,
            }),
          },
        ),
      );
    }
    assertEquals(malformedReplayHeaderCalls[30].status, 429);
  },
);

async function exerciseSupplementLogEndpoint(functionName: string) {
  await runFunctionScenario(
    functionName,
    "../api/supplements/log/index.ts",
    async () => {
      const idempotencyKey = crypto.randomUUID();
      const payload = {
        supplement_name: watchScenario.supplementName,
        taken_at: watchScenario.takenAtIso,
        scheduled_time: watchScenario.dueTime,
      };

      const first = await requestJson(
        LOCAL_FUNCTION_URL,
        "/",
        {
          method: "POST",
          headers: {
            ...jsonAuthHeaders(auth.accessToken),
            "Idempotency-Key": idempotencyKey,
          },
          body: JSON.stringify(payload),
        },
      );
      assertEquals(first.status, 200);
      assertEquals(objectValue(first.body, "ok"), true);

      const replay = await requestJson(
        LOCAL_FUNCTION_URL,
        "/",
        {
          method: "POST",
          headers: {
            ...jsonAuthHeaders(auth.accessToken),
            "Idempotency-Key": idempotencyKey,
          },
          body: JSON.stringify(payload),
        },
      );
      assertEquals(replay.status, 202);
      assertEquals(objectValue(replay.body, "idempotent_replay"), true);
    },
  );
}

await exerciseSupplementLogEndpoint("api-supplements-log");
await exerciseSupplementLogEndpoint("api-supplement-log");

await runFunctionScenario(
  "api-watch-snapshot-post-supplement",
  "../api/watch/snapshot/index.ts",
  async () => {
    const snapshot = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${watchScenario.date}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(snapshot.status, 200);
    assertEquals(
      objectValue(objectValue(snapshot.body, "next_best_action"), "type"),
      "insight_acknowledge",
    );
    assertEquals(
      objectValue(
        objectValue(objectValue(snapshot.body, "next_best_action"), "payload"),
        "insight_id",
      ),
      watchScenario.insightId,
    );
  },
);

await runFunctionScenario(
  "api-insight-acknowledge",
  "../api/insight/acknowledge/index.ts",
  async () => {
    const acknowledged = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          insight_id: watchScenario.insightId,
          acknowledged_at: watchScenario.takenAtIso,
        }),
      },
    );
    assertEquals(acknowledged.status, 200);
    assertEquals(objectValue(acknowledged.body, "ok"), true);

    const invalid = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ insight_id: "not-a-uuid" }),
      },
    );
    assertEquals(invalid.status, 400);
    assertEquals(objectValue(invalid.body, "error"), "invalid_insight_id");
  },
);

await runFunctionScenario(
  "api-watch-snapshot-post-actions",
  "../api/watch/snapshot/index.ts",
  async () => {
    const snapshot = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${watchScenario.date}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(snapshot.status, 200);
    assertEquals(
      objectValue(objectValue(snapshot.body, "next_best_action"), "type"),
      "open_on_iphone",
    );
    assertEquals(
      objectValue(
        objectValue(snapshot.body, "next_best_action"),
        "label_copy_id",
      ),
      "global.open_on_iphone",
    );
    assertEquals(
      objectValue(
        objectValue(objectValue(snapshot.body, "next_best_action"), "payload"),
        "deep_link",
      ),
      `lifeos://diary?date=${watchScenario.date}`,
    );
  },
);

await runFunctionScenario(
  "api-menstrual-sync",
  "../api/menstrual/sync/index.ts",
  async () => {
    await upsertRestRows(env, "privacy_settings", {
      user_id: publicUserId,
      menstrual_local_only: false,
    }, { onConflict: "user_id" });
    const id = crypto.randomUUID();

    const upsert = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id,
          date: "2026-02-22",
          flow: "medium",
          pain_level: 3,
        }),
      },
    );
    assertEquals(upsert.status, 200);
    assertEquals(objectValue(upsert.body, "ok"), true);

    const deleteRes = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id,
          deleted: true,
        }),
      },
    );
    assertEquals(deleteRes.status, 200);
    assertEquals(objectValue(deleteRes.body, "ok"), true);
  },
);

await runFunctionScenario(
  "api-settings-consent",
  "../api/settings/consent/index.ts",
  async () => {
    const mismatch = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": crypto.randomUUID(),
        },
        body: JSON.stringify({
          id: crypto.randomUUID(),
          consent_type: "privacy.analytics",
          granted: true,
          version: "1.0",
        }),
      },
    );
    assertEquals(mismatch.status, 400);
    assertEquals(
      objectValue(mismatch.body, "error"),
      "idempotency_key_mismatch",
    );

    const id = crypto.randomUUID();
    const payload = {
      id,
      consent_type: "privacy.analytics",
      granted: true,
      version: "1.0",
      timestamp: "2026-02-22T08:00:00.000Z",
    };

    const first = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": id,
        },
        body: JSON.stringify(payload),
      },
    );
    assertEquals(first.status, 202);

    const replay = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": id,
        },
        body: JSON.stringify(payload),
      },
    );
    assertEquals(replay.status, 202);
    assertEquals(objectValue(replay.body, "idempotent_replay"), true);
  },
);

await runFunctionScenario(
  "api-account-delete",
  "../api/account/delete/index.ts",
  async () => {
    for (let i = 0; i < 3; i += 1) {
      const requestId = crypto.randomUUID();
      const ok = await requestJson(
        LOCAL_FUNCTION_URL,
        "/",
        {
          method: "POST",
          headers: {
            ...jsonAuthHeaders(stressAuth.accessToken),
            "X-Outbox-Replay": "true",
            "Idempotency-Key": requestId,
          },
          body: JSON.stringify({
            immediate: false,
            reason: `security-test-${i}`,
          }),
        },
      );
      assertEquals(ok.status, 202);
    }

    const blocked = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(stressAuth.accessToken),
          "X-Outbox-Replay": "true",
          "Idempotency-Key": crypto.randomUUID(),
        },
        body: JSON.stringify({
          immediate: false,
          reason: "security-test-overflow",
        }),
      },
    );
    assertEquals(blocked.status, 429);
    assertEquals(objectValue(blocked.body, "error"), "rate_limit_exceeded");

    // Immediate deletion smoke-check on an isolated auth user.
    const immediateAuth = await createAuthSession(env);
    await waitForPublicUser(
      env,
      immediateAuth.authUserId,
      immediateAuth.email,
    );

    const immediateKey = crypto.randomUUID();
    const immediateDelete = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(immediateAuth.accessToken),
          "Idempotency-Key": immediateKey,
          "X-Deletion-Receipt": immediateReceiptToken,
        },
        body: JSON.stringify({
          immediate: true,
          reason: "edge-e2e-immediate-delete",
        }),
      },
    );
    assertEquals(immediateDelete.status, 200);
    assertEquals(objectValue(immediateDelete.body, "success"), true);
    assertEquals(
      objectValue(immediateDelete.body, "deletion_receipt"),
      immediateReceiptToken,
    );
    assertEquals(
      objectValue(immediateDelete.body, "deletion_state"),
      "completed",
    );

    const immediateReplay = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(immediateAuth.accessToken),
          "Idempotency-Key": immediateKey,
        },
        body: JSON.stringify({
          immediate: true,
          reason: "edge-e2e-immediate-delete",
        }),
      },
    );
    assertMatch(String(immediateReplay.status), /^(401|404)$/);
  },
);

await runFunctionScenario(
  "api-account-delete-status",
  "../api/account/delete_status/index.ts",
  async () => {
    const receiptStatus = await requestJson(LOCAL_FUNCTION_URL, "/", {
      method: "GET",
      headers: {
        apikey: env.anonKey,
        "X-Deletion-Receipt": immediateReceiptToken,
      },
    });
    assertEquals(receiptStatus.status, 200);
    assertEquals(objectValue(receiptStatus.body, "completed"), true);
    assertEquals(
      Object.keys(receiptStatus.body as Record<string, JsonValue>).sort(),
      ["completed", "deletion_state"],
    );
    const statusRes = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(stressAuth.accessToken),
      },
    );
    assertEquals(statusRes.status, 200);
    assertEquals(objectValue(statusRes.body, "scheduled"), true);
    assertEquals(objectValue(statusRes.body, "deletion_state"), "scheduled");
  },
);

await runFunctionScenario(
  "api-account-delete-cancel",
  "../api/account/delete_cancel/index.ts",
  async () => {
    const cancelRes = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(stressAuth.accessToken),
        body: JSON.stringify({}),
      },
    );
    assertEquals(cancelRes.status, 200);
    assertEquals(objectValue(cancelRes.body, "cancelled"), true);
  },
);

await runFunctionScenario(
  "api-account-delete-status (post-cancel)",
  "../api/account/delete_status/index.ts",
  async () => {
    const statusRes = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(stressAuth.accessToken),
      },
    );
    assertEquals(statusRes.status, 200);
    assertEquals(objectValue(statusRes.body, "scheduled"), false);
    assertEquals(objectValue(statusRes.body, "deletion_state"), "cancelled");
  },
);

await runFunctionScenario(
  "api-recovery",
  "../api/recovery/index.ts",
  async () => {
    const trend = await requestJson(
      LOCAL_FUNCTION_URL,
      "/trend?days=30",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(trend.status, 200);

    const invalidDaily = await requestJson(
      LOCAL_FUNCTION_URL,
      "/daily?date=20260222",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(invalidDaily.status, 400);
  },
);

const customFoodId = crypto.randomUUID();
const customBarcodeOverrideId = crypto.randomUUID();
const ocrCatalogBarcode = "4601234500007";
await runFunctionScenario(
  "api-foods",
  "../api/foods/index.ts",
  async () => {
    const custom = await requestJson(
      LOCAL_FUNCTION_URL,
      "/custom",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: customFoodId,
          name: "Oatmeal (dry)",
          default_serving_g: 40,
          macros_per_100g: {
            calories: 380,
            protein_g: 13,
            fat_g: 7,
            carbs_g: 67,
            fiber_g: 10,
          },
        }),
      },
    );
    assertEquals(custom.status, 200);
    assertEquals(objectValue(custom.body, "id"), customFoodId);

    const search = await requestJson(
      LOCAL_FUNCTION_URL,
      "/search?q=oat&limit=5",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(search.status, 200);

    const favorite = await requestJson(
      LOCAL_FUNCTION_URL,
      "/favorites",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: crypto.randomUUID(),
          ref_type: "custom",
          ref_id: customFoodId,
        }),
      },
    );
    assertEquals(favorite.status, 200);
    assertEquals(objectValue(favorite.body, "ok"), true);

    const favorites = await requestJson(
      LOCAL_FUNCTION_URL,
      "/favorites",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(favorites.status, 200);
    const favoriteRows = objectValue(favorites.body, "favorites");
    assertEquals(Array.isArray(favoriteRows), true);
    if (!Array.isArray(favoriteRows)) {
      throw new Error("favorites response is not an array");
    }
    assertEquals(
      favoriteRows.some((row) =>
        objectValue(row, "ref_type") === "custom" &&
        objectValue(row, "ref_id") === customFoodId
      ),
      true,
    );

    const deleteFavorite = await requestJson(
      LOCAL_FUNCTION_URL,
      `/favorites/custom/${customFoodId}`,
      {
        method: "DELETE",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(deleteFavorite.status, 200);
    assertEquals(objectValue(deleteFavorite.body, "ok"), true);

    const favoritesAfterDelete = await requestJson(
      LOCAL_FUNCTION_URL,
      "/favorites",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(favoritesAfterDelete.status, 200);
    const favoriteRowsAfterDelete = objectValue(
      favoritesAfterDelete.body,
      "favorites",
    );
    assertEquals(Array.isArray(favoriteRowsAfterDelete), true);
    if (!Array.isArray(favoriteRowsAfterDelete)) {
      throw new Error("favorites response is not an array");
    }
    assertEquals(
      favoriteRowsAfterDelete.some((row) =>
        objectValue(row, "ref_type") === "custom" &&
        objectValue(row, "ref_id") === customFoodId
      ),
      false,
    );

    const createOcrCatalog = await requestJson(
      LOCAL_FUNCTION_URL,
      `/barcode/${ocrCatalogBarcode}/create`,
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          provider: "lifeos_label_ocr",
          name: "Ryazhenka 4%",
          serving_size_g: 200,
          source_confidence: 0.72,
          macros_per_100g: {
            calories: 67,
            protein_g: 2.8,
            fat_g: 4,
            carbs_g: 4.2,
            fiber_g: 0,
          },
        }),
      },
    );
    assertEquals(createOcrCatalog.status, 200);
    assertEquals(
      objectValue(createOcrCatalog.body, "provider"),
      "lifeos_label_ocr",
    );

    const ocrLookup = await requestJson(
      LOCAL_FUNCTION_URL,
      `/barcode/${ocrCatalogBarcode}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(ocrLookup.status, 200);
    assertEquals(objectValue(ocrLookup.body, "type"), "catalog");
    assertEquals(objectValue(ocrLookup.body, "provider"), "lifeos_label_ocr");

    const override = await requestJson(
      LOCAL_FUNCTION_URL,
      "/custom",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: customBarcodeOverrideId,
          name: "Ryazhenka 4% (corrected)",
          barcode: ocrCatalogBarcode,
          default_serving_g: 200,
          macros_per_100g: {
            calories: 64,
            protein_g: 3,
            fat_g: 3.5,
            carbs_g: 4.1,
            fiber_g: 0,
          },
        }),
      },
    );
    assertEquals(override.status, 200);
    assertEquals(objectValue(override.body, "id"), customBarcodeOverrideId);

    const overrideLookup = await requestJson(
      LOCAL_FUNCTION_URL,
      `/barcode/${ocrCatalogBarcode}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(overrideLookup.status, 200);
    assertEquals(objectValue(overrideLookup.body, "type"), "custom");
    const overrideTags = objectValue(overrideLookup.body, "tags");
    assertEquals(Array.isArray(overrideTags), true);
    assertEquals((overrideTags as JsonValue[])[0], "user_override");

    const invalidBarcode = await requestJson(
      LOCAL_FUNCTION_URL,
      "/barcode/!!",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(invalidBarcode.status, 400);
  },
);

const scanId = crypto.randomUUID();
const legacyScanId = crypto.randomUUID();
const rootScanId = crypto.randomUUID();
const rootMeasurementId = crypto.randomUUID();
const revokedCloudScanId = crypto.randomUUID();
const localOnlyScanId = crypto.randomUUID();
await runFunctionScenario(
  "api-labs",
  "../api/labs/index.ts",
  async () => {
    await upsertRestRows(env, "privacy_settings", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      menstrual_local_only: true,
      medical_scan_local_only: false,
      vector_opt_in: false,
      analytics_consent: true,
      cloud_ocr_enabled: true,
      ai_processing_consent: true,
      cloud_backup_enabled: true,
    }, { onConflict: "user_id" });

    const rootCreate = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          scan_id: rootScanId,
          scan_type: "blood_test",
          storage_mode: "cloud",
          scan_date: "2026-02-21",
          status: "completed",
          stored_asset_path: `${auth.authUserId}/${rootScanId}/original.pdf`,
          store_original_in_cloud: true,
          processed_data: {
            markers: [
              {
                measurement_id: rootMeasurementId,
                marker_id: "ferritin",
                value: 58,
                unit: "ng/mL",
                status: "optimal",
                confidence: 0.9,
                reference_range_low: 30,
                reference_range_high: 400,
              },
            ],
          },
        }),
      },
    );
    assertEquals(rootCreate.status, 200);
    assertEquals(objectValue(rootCreate.body, "scan_id"), rootScanId);

    const getRootScan = await requestJson(
      LOCAL_FUNCTION_URL,
      `/scan/${rootScanId}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(getRootScan.status, 200);
    assertEquals(
      objectValue(getRootScan.body, "original_image_url"),
      `${auth.authUserId}/${rootScanId}/original.pdf`,
    );

    await upsertRestRows(env, "privacy_settings", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      menstrual_local_only: true,
      medical_scan_local_only: false,
      vector_opt_in: false,
      analytics_consent: true,
      cloud_ocr_enabled: true,
      ai_processing_consent: true,
      cloud_backup_enabled: false,
    }, { onConflict: "user_id" });

    const revokedCloudCreate = await requestJson(
      LOCAL_FUNCTION_URL,
      "/scan",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          scan_id: revokedCloudScanId,
          scan_type: "blood_test",
          storage_mode: "cloud",
          scan_date: "2026-02-22",
          status: "completed",
          stored_asset_path:
            `${auth.authUserId}/${revokedCloudScanId}/revoked.pdf`,
          store_original_in_cloud: true,
        }),
      },
    );
    assertEquals(revokedCloudCreate.status, 200);

    const revokedCloudRows = await fetchRestRows(
      env,
      "medical_scans",
      { id: `eq.${revokedCloudScanId}` },
      "storage_mode,original_image_url,store_original_in_cloud,scheduled_deletion_at",
    );
    assertEquals(revokedCloudRows.length, 1);
    assertEquals(objectValue(revokedCloudRows[0], "storage_mode"), "cloud");
    assertEquals(objectValue(revokedCloudRows[0], "original_image_url"), null);
    assertEquals(
      objectValue(revokedCloudRows[0], "store_original_in_cloud"),
      false,
    );
    assertEquals(
      objectValue(revokedCloudRows[0], "scheduled_deletion_at"),
      null,
    );

    await upsertRestRows(env, "privacy_settings", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      menstrual_local_only: true,
      medical_scan_local_only: true,
      vector_opt_in: false,
      analytics_consent: true,
      cloud_ocr_enabled: true,
      ai_processing_consent: true,
      cloud_backup_enabled: true,
    }, { onConflict: "user_id" });

    const localOnlyCreate = await requestJson(
      LOCAL_FUNCTION_URL,
      "/scan",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          scan_id: localOnlyScanId,
          scan_type: "blood_test",
          storage_mode: "cloud",
          scan_date: "2026-02-22",
          status: "completed",
          stored_asset_path:
            `${auth.authUserId}/${localOnlyScanId}/local-only.pdf`,
          store_original_in_cloud: true,
        }),
      },
    );
    assertEquals(localOnlyCreate.status, 200);

    const localOnlyRows = await fetchRestRows(
      env,
      "medical_scans",
      { id: `eq.${localOnlyScanId}` },
      "storage_mode,original_image_url,store_original_in_cloud,scheduled_deletion_at",
    );
    assertEquals(localOnlyRows.length, 1);
    assertEquals(objectValue(localOnlyRows[0], "storage_mode"), "local_only");
    assertEquals(objectValue(localOnlyRows[0], "original_image_url"), null);
    assertEquals(
      objectValue(localOnlyRows[0], "store_original_in_cloud"),
      false,
    );
    assertEquals(objectValue(localOnlyRows[0], "scheduled_deletion_at"), null);

    const create = await requestJson(
      LOCAL_FUNCTION_URL,
      "/scan",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          scan_id: scanId,
          scan_type: "blood_test",
          storage_mode: "local_only",
          scan_date: "2026-02-22",
          processed_data: {
            markers: [
              {
                marker_id: "vitamin_d_25oh",
                value: 24,
                unit: "ng/mL",
                status: "low",
                confidence: 0.8,
              },
            ],
          },
        }),
      },
    );
    assertEquals(create.status, 200);
    assertEquals(objectValue(create.body, "scan_id"), scanId);

    const getScan = await requestJson(
      LOCAL_FUNCTION_URL,
      `/scan/${scanId}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(getScan.status, 200);
    assertEquals(objectValue(getScan.body, "scan_id"), scanId);

    const legacyCreate = await requestJson(
      LOCAL_FUNCTION_URL,
      "/scan",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          scan_id: legacyScanId,
          scan_type: "bloodwork",
          storage_mode: "local_only",
          scan_date: "2026-02-23",
        }),
      },
    );
    assertEquals(legacyCreate.status, 200);
    assertEquals(objectValue(legacyCreate.body, "scan_id"), legacyScanId);

    const markerLatest = await requestJson(
      LOCAL_FUNCTION_URL,
      "/markers?marker_id=vitamin_d_25oh",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(markerLatest.status, 200);

    const markerHistory = await requestJson(
      LOCAL_FUNCTION_URL,
      "/markers/history?marker_id=vitamin_d_25oh&from=2026-02-01&to=2026-02-28",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(markerHistory.status, 200);
  },
);

const retentionWorkerScanId = crypto.randomUUID();
await runFunctionScenario(
  "api-labs-retention-worker",
  "../api/labs/retention_worker/index.ts",
  async () => {
    await upsertRestRows(env, "medical_scans", {
      id: retentionWorkerScanId,
      user_id: publicUserId,
      scan_type: "blood_test",
      scan_date: "2025-12-01",
      status: "completed",
      storage_mode: "cloud",
      store_original_in_cloud: true,
      image_url: `${auth.authUserId}/${retentionWorkerScanId}/original.pdf`,
      original_image_url:
        `${auth.authUserId}/${retentionWorkerScanId}/original.pdf`,
      image_uploaded_at: "2025-12-01T09:00:00Z",
      scheduled_deletion_at: "2026-01-01T09:00:00Z",
      extraction_status: "completed",
      markers_extracted: 0,
      created_at: "2025-12-01T09:00:00Z",
      updated_at: "2025-12-01T09:00:00Z",
      processed_data: null,
      pinned_by_user: false,
      notes: null,
      source_file_sha256: null,
      document_language: null,
      ocr_confidence: null,
      ai_confidence: null,
      manually_verified: false,
      needs_review: false,
      user_reviewed: false,
      user_reviewed_at: null,
      deleted_at: null,
    });

    const workerResponse = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: env.serviceRoleKey,
          Authorization: `Bearer ${env.serviceRoleKey}`,
          "X-Labs-Retention-Worker": "scheduled",
        },
        body: JSON.stringify({
          batch_size: 10,
          now: "2026-03-17T00:00:00Z",
        }),
      },
    );
    assertEquals(workerResponse.status, 200);

    const retainedRows = await fetchRestRows(
      env,
      "medical_scans",
      { id: `eq.${retentionWorkerScanId}` },
      "image_url,original_image_url,image_uploaded_at,store_original_in_cloud,scheduled_deletion_at",
    );
    assertEquals(retainedRows.length, 1);
    assertEquals(objectValue(retainedRows[0], "image_url"), null);
    assertEquals(objectValue(retainedRows[0], "original_image_url"), null);
    assertEquals(objectValue(retainedRows[0], "image_uploaded_at"), null);
    assertEquals(
      objectValue(retainedRows[0], "store_original_in_cloud"),
      false,
    );
    assertEquals(objectValue(retainedRows[0], "scheduled_deletion_at"), null);
  },
);

const experimentId = crypto.randomUUID();
await runFunctionScenario(
  "api-experiments",
  "../api/experiments/index.ts",
  async () => {
    const staleExperimentId = crypto.randomUUID();
    const historicalExperimentId = crypto.randomUUID();

    await upsertRestRows(env, "experiments", {
      id: staleExperimentId,
      user_id: publicUserId,
      title: "Old stale baseline",
      hypothesis: "Historical test should not block creation",
      variable: "caffeine_cutoff",
      status: "baseline",
      baseline_start_date: localDateDaysFromToday(-21),
      baseline_end_date: localDateDaysFromToday(-15),
      baseline_duration_days: 7,
      intervention_start_date: localDateDaysFromToday(-14),
      intervention_end_date: localDateDaysFromToday(-8),
      intervention_duration_days: 7,
      washout_start_date: localDateDaysFromToday(-7),
      washout_end_date: localDateDaysFromToday(-1),
      washout_duration_days: 7,
      primary_metric: "sleep_quality",
    });

    const create = await requestJson(
      LOCAL_FUNCTION_URL,
      "/create",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: experimentId,
          title: "Supplement Timing",
          hypothesis: "Evening routine improves sleep",
          variable: "timing",
          primary_metric: "sleep_quality",
          baseline_duration_days: 3,
          intervention_duration_days: 5,
        }),
      },
    );
    assertEquals(create.status, 200);
    assertEquals(objectValue(create.body, "id"), experimentId);
    assertEquals(objectValue(create.body, "status"), "baseline");

    const staleRows = await fetchRestRows(
      env,
      "experiments",
      { id: `eq.${staleExperimentId}` },
      "status",
    );
    assertEquals(staleRows.length, 1);
    assertEquals(objectValue(staleRows[0], "status"), "completed");

    await upsertRestRows(env, "experiments", {
      id: historicalExperimentId,
      user_id: publicUserId,
      title: "Completed lifecycle",
      hypothesis: "Historical measurement should resolve intervention phase",
      variable: "supplement_timing",
      status: "baseline",
      baseline_start_date: localDateDaysFromToday(-21),
      baseline_end_date: localDateDaysFromToday(-15),
      baseline_duration_days: 7,
      intervention_start_date: localDateDaysFromToday(-14),
      intervention_end_date: localDateDaysFromToday(-8),
      intervention_duration_days: 7,
      washout_start_date: localDateDaysFromToday(-7),
      washout_end_date: localDateDaysFromToday(-1),
      washout_duration_days: 7,
      primary_metric: "sleep_quality",
    });

    const log = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${historicalExperimentId}/log`,
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          date: localDateDaysFromToday(-10),
          measurements: {
            sleep_quality: 82,
          },
          notes: "Felt rested",
        }),
      },
    );
    assertEquals(log.status, 200);
    assertEquals(objectValue(log.body, "logged"), true);
    assertEquals(objectValue(log.body, "measurement_phase"), "intervention");
    assertEquals(objectValue(log.body, "experiment_status"), "completed");

    const historicalRows = await fetchRestRows(
      env,
      "experiments",
      { id: `eq.${historicalExperimentId}` },
      "status",
    );
    assertEquals(historicalRows.length, 1);
    assertEquals(objectValue(historicalRows[0], "status"), "completed");

    const measurementRows = await fetchRestRows(
      env,
      "experiment_measurements",
      {
        experiment_id: `eq.${historicalExperimentId}`,
        measurement_date: `eq.${localDateDaysFromToday(-10)}`,
      },
      "measurement_phase,metric_name,metric_value",
    );
    assertEquals(measurementRows.length, 1);
    assertEquals(
      objectValue(measurementRows[0], "measurement_phase"),
      "intervention",
    );
    assertEquals(
      objectValue(measurementRows[0], "metric_name"),
      "sleep_quality",
    );
    assertEquals(objectValue(measurementRows[0], "metric_value"), 82);

    const removed = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${experimentId}`,
      {
        method: "DELETE",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(removed.status, 200);

    const undo = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${experimentId}/undo`,
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({}),
      },
    );
    assertEquals(undo.status, 200);
  },
);

let trainingPlanId = "";
await runFunctionScenario(
  "api-training-plan",
  "../api/training/plan/index.ts",
  async () => {
    const generated = await requestJson(
      LOCAL_FUNCTION_URL,
      "/generate",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          goal: "hypertrophy",
          available_days: [1, 3, 5],
          session_duration_minutes: 60,
        }),
      },
    );
    assertEquals(generated.status, 200);
    trainingPlanId = String(objectValue(generated.body, "plan_id"));
    assertMatch(trainingPlanId, /^[0-9a-f-]{36}$/i);

    const active = await requestJson(
      LOCAL_FUNCTION_URL,
      "/active",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(active.status, 200);

    const sessions = await requestJson(
      LOCAL_FUNCTION_URL,
      "/sessions?from=2026-02-01&to=2026-03-31",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(sessions.status, 200);

    const detail = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${trainingPlanId}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(detail.status, 200);

    const patch = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${trainingPlanId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          status: "paused",
          name: "Adjusted Plan Name",
        }),
      },
    );
    assertEquals(patch.status, 200);

    const adjust = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${trainingPlanId}/adjust`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          reason: "recovery_low",
          adjustment: "reduce_volume_30",
        }),
      },
    );
    assertEquals(adjust.status, 200);
  },
);

const hydrationLogId = crypto.randomUUID();
await runFunctionScenario(
  "api-hydration",
  "../api/hydration/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/log",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: hydrationLogId,
          logged_at: "2026-02-22T12:30:00.000Z",
          logged_date: "2026-02-22",
          water_ml: 350,
          source: "manual",
        }),
      },
    );
    assertEquals(created.status, 200);
    assertEquals(objectValue(created.body, "id"), hydrationLogId);

    const daily = await requestJson(
      LOCAL_FUNCTION_URL,
      "/daily?date=2026-02-22",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(daily.status, 200);

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      `/log/${hydrationLogId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ water_ml: 400 }),
      },
    );
    assertEquals(patched.status, 200);

    const history = await requestJson(
      LOCAL_FUNCTION_URL,
      "/history?from=2026-02-01&to=2026-02-28",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(history.status, 200);

    const deleted = await requestJson(
      LOCAL_FUNCTION_URL,
      `/log/${hydrationLogId}`,
      {
        method: "DELETE",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(deleted.status, 200);
  },
);

const bodyCompositionId = crypto.randomUUID();
await runFunctionScenario(
  "api-body-composition",
  "../api/body-composition/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: bodyCompositionId,
          measured_at: "2026-02-22T07:10:00.000Z",
          input_type: "home_scale",
          weight_kg: 72.4,
          body_fat_percent: 18.2,
          source: "manual",
        }),
      },
    );
    assertEquals(created.status, 200);
    assertEquals(objectValue(created.body, "id"), bodyCompositionId);

    const history = await requestJson(
      LOCAL_FUNCTION_URL,
      "/history?from=2026-02-01&to=2026-02-28",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(history.status, 200);

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${bodyCompositionId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ body_fat_percent: 17.8 }),
      },
    );
    assertEquals(patched.status, 200);

    const deleted = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${bodyCompositionId}`,
      {
        method: "DELETE",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(deleted.status, 200);
  },
);

await runFunctionScenario(
  "api-wellness",
  "../api/wellness/index.ts",
  async () => {
    const check = await requestJson(
      LOCAL_FUNCTION_URL,
      "/check",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: crypto.randomUUID(),
          date: "2026-02-22",
          perceived_sleep_quality: 4,
          energy_level: 4,
          muscle_soreness: 2,
          stress_level: 3,
          mood: 4,
          pss4_q1: 1,
          pss4_q2: 2,
          pss4_q3: 2,
          pss4_q4: 1,
          feeling_ill: false,
        }),
      },
    );
    assertEquals(check.status, 200);
    assertEquals(objectValue(check.body, "ok"), true);

    const history = await requestJson(
      LOCAL_FUNCTION_URL,
      "/history?from=2026-02-01&to=2026-02-28",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(history.status, 200);
  },
);

await runFunctionScenario(
  "api-recommendations",
  "../api/recommendations/index.ts",
  async () => {
    const listed = await requestJson(
      LOCAL_FUNCTION_URL,
      "/?date=2026-02-22",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(listed.status, 200);
    assertEquals(
      Array.isArray(objectValue(listed.body, "recommendations")),
      true,
    );

    const dismiss = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${crypto.randomUUID()}/dismiss`,
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({}),
      },
    );
    assertEquals(dismiss.status, 404);
  },
);

await runFunctionScenario(
  "api-insights-daily",
  "../api/insights/daily/index.ts",
  async () => {
    const daily = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(daily.status, 200);
    assertEquals(typeof objectValue(daily.body, "date"), "string");
    assertEquals(Array.isArray(objectValue(daily.body, "insights")), true);
    assertEquals(
      Array.isArray(objectValue(daily.body, "recommendations")),
      true,
    );
  },
);

let userSupplementId = "";
await deleteRestRows(env, "rate_limit_windows", {
  bucket_key: `eq.write_heavy:${publicUserId}`,
});
await runFunctionScenario(
  "api-user-supplements",
  "../api/user-supplements/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: crypto.randomUUID(),
          custom_name: "Magnesium Glycinate",
          frequency: "daily",
          scheduled_times: ["21:00"],
          take_with_food: false,
          notes: "evening routine",
          active: true,
        }),
      },
    );
    assertEquals(created.status, 200);
    userSupplementId = String(objectValue(created.body, "id"));
    assertMatch(userSupplementId, /^[0-9a-f-]{36}$/i);

    const listed = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(listed.status, 200);

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${userSupplementId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          notes: "updated note",
        }),
      },
    );
    assertEquals(patched.status, 200);

    const deleted = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${userSupplementId}`,
      {
        method: "DELETE",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(deleted.status, 200);
  },
);

await runFunctionScenario(
  "api-weekly-strategy",
  "../api/weekly-strategy/index.ts",
  async () => {
    const weekly = await requestJson(
      LOCAL_FUNCTION_URL,
      "/?week_start=2026-02-16",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(weekly.status, 200);
    assertEquals(objectValue(weekly.body, "week_start"), "2026-02-16");
  },
);

await runFunctionScenario(
  "api-hydration-log-alias",
  "../api/hydration/log/index.ts",
  async () => {
    await deleteRestRows(env, "rate_limit_windows", {
      bucket_key: `eq.write_heavy:${publicUserId}`,
    });

    const aliasLog = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: crypto.randomUUID(),
          logged_at: "2026-02-22T10:00:00.000Z",
          logged_date: "2026-02-22",
          water_ml: 250,
          source: "manual",
        }),
      },
    );
    assertEquals(aliasLog.status, 200);
  },
);

await runFunctionScenario(
  "api-wellness-check-alias",
  "../api/wellness/check/index.ts",
  async () => {
    const aliasCheck = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          id: crypto.randomUUID(),
          date: "2026-02-21",
          perceived_sleep_quality: 4,
          energy_level: 3,
          muscle_soreness: 2,
          stress_level: 2,
          mood: 4,
        }),
      },
    );
    assertEquals(aliasCheck.status, 200);
  },
);

await runFunctionScenario(
  "api-search",
  "../api/search/index.ts",
  async () => {
    const search = await requestJson(
      LOCAL_FUNCTION_URL,
      "/?q=oat&limit=5",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(search.status, 200);
  },
);

const coverageScenarioDate = "2026-02-24";
const coverageScenarioNextDate = "2026-02-25";
const tinyPngDataUrl =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=";

await runFunctionScenario(
  "api-config-feature-flags",
  "../api/config/feature-flags/index.ts",
  async () => {
    const unauthorized = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      { method: "GET" },
    );
    assertEquals(unauthorized.status, 401);

    const flags = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(flags.status, 200);
    assertEquals(Array.isArray(objectValue(flags.body, "flags")), true);
    assertEquals(objectValue(flags.body, "ttl_seconds"), 3600);
  },
);

await runFunctionScenario(
  "api-analytics-batch",
  "../api/analytics/batch/index.ts",
  async () => {
    const missingDevice = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ events: [] }),
      },
    );
    assertEquals(missingDevice.status, 400);
    assertEquals(objectValue(missingDevice.body, "error"), "missing_device_id");

    await deleteRestRows(env, "privacy_settings", {
      user_id: `eq.${publicUserId}`,
    });
    await upsertRestRows(env, "privacy_settings", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      menstrual_local_only: true,
      medical_scan_local_only: false,
      vector_opt_in: false,
      analytics_consent: true,
      cloud_ocr_enabled: true,
      ai_processing_consent: true,
      cloud_backup_enabled: true,
    }, { onConflict: "user_id" });

    const accepted = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "X-Device-Id": "edge-e2e-device",
          "X-App-Version": "1.0.0",
        },
        body: JSON.stringify({
          events: [
            {
              name: "edge_e2e.analytics.accepted",
              timestamp: new Date().toISOString(),
              properties: { source: "edge_local_e2e" },
              session_id: crypto.randomUUID(),
            },
            {
              name: "",
              timestamp: new Date().toISOString(),
            },
          ],
        }),
      },
    );
    assertEquals(accepted.status, 202);
    assertEquals(objectValue(accepted.body, "accepted"), 1);
    assertEquals(objectValue(accepted.body, "rejected"), 1);
  },
);

await runFunctionScenario(
  "api-sleep-daily",
  "../api/sleep/daily/index.ts",
  async () => {
    await deleteRestRows(env, "physiological_states", {
      user_id: `eq.${publicUserId}`,
      date: `eq.${coverageScenarioDate}`,
    });
    await upsertRestRows(env, "physiological_states", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      date: coverageScenarioDate,
      recovery_score: 83,
      recovery_zone: "optimal",
      sleep_duration_hours: 7.5,
      sleep_score: 81,
      sleep_quality_percent: 84,
      deep_sleep_percent: 22,
      rem_sleep_percent: 21,
      light_sleep_percent: 52,
      awake_percent: 5,
      data_completeness: 0.91,
      confidence_score: 0.88,
      updated_at: `${coverageScenarioDate}T07:30:00.000Z`,
    });

    const daily = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(daily.status, 200);
    assertEquals(objectValue(daily.body, "date"), coverageScenarioDate);
    assertEquals(objectValue(daily.body, "sleep_duration_hours"), 7.5);
    assertEquals(
      objectValue(objectValue(daily.body, "stages"), "stages_available"),
      true,
    );
  },
);

await runFunctionScenario(
  "api-sleep-log",
  "../api/sleep/log/index.ts",
  async () => {
    await deleteRestRows(env, "sleep_logs", {
      user_id: `eq.${publicUserId}`,
      sleep_date: `eq.${coverageScenarioDate}`,
    });
    const firstID = crypto.randomUUID();
    const postSleep = (body: unknown) =>
      requestJson(LOCAL_FUNCTION_URL, "/", {
        method: "POST",
        headers: authHeaders(auth.accessToken),
        body: JSON.stringify(body),
      });
    const base = {
      id: firstID,
      sleep_date: coverageScenarioDate,
      source: "healthkit",
      total_duration_minutes: 360,
      deep_sleep_minutes: 60,
      updated_at: `${coverageScenarioDate}T08:00:00Z`,
    };
    assertEquals((await postSleep(base)).status, 200);
    const manual = await postSleep({
      ...base,
      id: crypto.randomUUID(),
      source: "manual",
      total_duration_minutes: 480,
      deep_sleep_minutes: null,
      updated_at: `${coverageScenarioDate}T09:00:00Z`,
    });
    assertEquals(manual.status, 200);
    assertEquals(
      objectValue(objectValue(manual.body, "sleep_log"), "id"),
      firstID,
    );
    const imported = await postSleep({
      ...base,
      id: crypto.randomUUID(),
      updated_at: `${coverageScenarioDate}T10:00:00Z`,
    });
    assertEquals(imported.status, 200);
    assertEquals(
      objectValue(objectValue(imported.body, "sleep_log"), "source"),
      "manual",
    );
    assertEquals(
      objectValue(
        objectValue(imported.body, "sleep_log"),
        "total_duration_minutes",
      ),
      480,
    );
    assertEquals(
      objectValue(
        objectValue(imported.body, "sleep_log"),
        "deep_sleep_minutes",
      ),
      null,
    );
    assertEquals(
      (await postSleep({ ...base, total_duration_minutes: -1 })).status,
      400,
    );
  },
);

await runFunctionScenario(
  "api-sleep-calendar",
  "../api/sleep/calendar/index.ts",
  async () => {
    const calendar = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?from=${coverageScenarioDate}&to=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(calendar.status, 200);
    assertEquals(objectValue(calendar.body, "from"), coverageScenarioDate);
    assertEquals(objectValue(calendar.body, "to"), coverageScenarioDate);
    assertEquals(Array.isArray(objectValue(calendar.body, "days")), true);
  },
);

await runFunctionScenario(
  "api-nutrition-daily",
  "../api/nutrition/daily/index.ts",
  async () => {
    await deleteRestRows(env, "food_logs", {
      user_id: `eq.${publicUserId}`,
      logged_date: `eq.${coverageScenarioDate}`,
    });
    await deleteRestRows(env, "daily_nutrition_targets", {
      user_id: `eq.${publicUserId}`,
      date: `eq.${coverageScenarioDate}`,
    });
    await upsertRestRows(env, "daily_nutrition_targets", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      date: coverageScenarioDate,
      final_calories: 2100,
      final_protein_g: 150,
      final_fat_g: 70,
      final_carbs_g: 230,
    });
    await upsertRestRows(env, "food_logs", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      logged_at: `${coverageScenarioDate}T10:00:00.000Z`,
      logged_date: coverageScenarioDate,
      input_method: "manual",
      meal_type: "breakfast",
      calories: 510,
      protein_g: 36,
      fat_g: 14,
      carbs_g: 62,
      fiber_g: 7,
      needs_review: false,
      ai_confidence: 0.92,
    });

    const daily = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(daily.status, 200);
    assertEquals(objectValue(daily.body, "date"), coverageScenarioDate);
    assertEquals(objectValue(daily.body, "meal_count"), 1);
    assertEquals(
      objectValue(objectValue(daily.body, "totals"), "calories"),
      510,
    );
  },
);

await runFunctionScenario(
  "api-nutrition-calendar",
  "../api/nutrition/calendar/index.ts",
  async () => {
    const calendar = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?from=${coverageScenarioDate}&to=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(calendar.status, 200);
    assertEquals(Array.isArray(objectValue(calendar.body, "days")), true);
  },
);

const coverageSupplementCatalogId = crypto.randomUUID();
const coverageUserSupplementId = crypto.randomUUID();
const coverageSupplementLogId = crypto.randomUUID();
await runFunctionScenario(
  "api-supplements-daily",
  "../api/supplements/daily/index.ts",
  async () => {
    await deleteRestRows(env, "supplement_logs", {
      id: `eq.${coverageSupplementLogId}`,
    });
    await deleteRestRows(env, "user_supplements", {
      id: `eq.${coverageUserSupplementId}`,
    });
    await deleteRestRows(env, "supplement_catalog", {
      id: `eq.${coverageSupplementCatalogId}`,
    });
    await upsertRestRows(env, "supplement_catalog", {
      id: coverageSupplementCatalogId,
      name: "Vitamin D Edge Coverage",
      category: "vitamin",
    });
    await upsertRestRows(env, "user_supplements", {
      id: coverageUserSupplementId,
      user_id: publicUserId,
      catalog_id: coverageSupplementCatalogId,
      custom_name: null,
      dose_amount: 2000,
      dose_unit: "IU",
      frequency: "daily",
      scheduled_times: ["08:00"],
      days_of_week: null,
      take_with_food: true,
      notes: null,
      active: true,
      started_at: "2026-02-01",
      ended_at: null,
    });
    await upsertRestRows(env, "supplement_logs", {
      id: coverageSupplementLogId,
      user_id: publicUserId,
      user_supplement_id: coverageUserSupplementId,
      supplement_name: "Vitamin D Edge Coverage",
      taken_at: `${coverageScenarioDate}T08:05:00.000Z`,
      taken_date: coverageScenarioDate,
      taken_timezone: "UTC",
      was_scheduled: true,
      scheduled_time: "08:00",
    });

    const daily = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(daily.status, 200);
    assertEquals(objectValue(daily.body, "date"), coverageScenarioDate);
    assertEquals(objectValue(daily.body, "adherence_today_percent"), 100);
    assertEquals(Array.isArray(objectValue(daily.body, "schedule")), true);
  },
);

await runFunctionScenario(
  "api-supplements-calendar",
  "../api/supplements/calendar/index.ts",
  async () => {
    const calendar = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?from=${coverageScenarioDate}&to=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(calendar.status, 200);
    assertEquals(Array.isArray(objectValue(calendar.body, "days")), true);
  },
);

await runFunctionScenario(
  "api-diary-daily",
  "../api/diary/daily/index.ts",
  async () => {
    await deleteRestRows(env, "medical_scans", {
      user_id: `eq.${publicUserId}`,
      extraction_status: "in.(pending,processing,needs_review,review_required)",
    });

    const diary = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(diary.status, 200);
    assertEquals(objectValue(diary.body, "date"), coverageScenarioDate);
    assertEquals(objectValue(diary.body, "needs_review"), false);
    objectValue(diary.body, "recovery");
    objectValue(diary.body, "nutrition");
    objectValue(diary.body, "supplements");
  },
);

await runFunctionScenario(
  "api-diary-calendar",
  "../api/diary/calendar/index.ts",
  async () => {
    const calendar = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?from=${coverageScenarioDate}&to=${coverageScenarioDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(calendar.status, 200);
    assertEquals(Array.isArray(objectValue(calendar.body, "days")), true);
  },
);

const coverageWorkoutId = crypto.randomUUID();
const coverageWorkoutAliasId = crypto.randomUUID();
await runFunctionScenario(
  "api-workouts-log",
  "../api/workouts/log/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageWorkoutId,
        },
        body: JSON.stringify({
          id: coverageWorkoutId,
          started_at: `${coverageScenarioNextDate}T17:00:00.000Z`,
          ended_at: `${coverageScenarioNextDate}T17:45:00.000Z`,
          session_date: coverageScenarioNextDate,
          workout_type: "strength",
          location: "gym",
          perceived_exertion_rpe: 7,
          exercises: [
            {
              name: "Goblet squat",
              category: "strength",
              order_in_session: 0,
              sets: [
                {
                  set_number: 1,
                  weight: 24,
                  reps: 10,
                  rpe: 7,
                },
              ],
            },
          ],
        }),
      },
    );
    assertEquals(created.status, 202);
    assertEquals(objectValue(created.body, "id"), coverageWorkoutId);

    const replay = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageWorkoutId,
        },
        body: JSON.stringify({
          id: coverageWorkoutId,
          started_at: `${coverageScenarioNextDate}T17:00:00.000Z`,
          session_date: coverageScenarioNextDate,
        }),
      },
    );
    assertEquals(replay.status, 202);
    assertEquals(objectValue(replay.body, "idempotent_replay"), true);
  },
);

await runFunctionScenario(
  "api-workout-log",
  "../api/workouts/log/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageWorkoutAliasId,
        },
        body: JSON.stringify({
          id: coverageWorkoutAliasId,
          started_at: `${coverageScenarioNextDate}T18:00:00.000Z`,
          session_date: coverageScenarioNextDate,
          workout_type: "mobility",
          perceived_exertion_rpe: 3,
        }),
      },
    );
    assertEquals(created.status, 202);
    assertEquals(objectValue(created.body, "id"), coverageWorkoutAliasId);
  },
);

await runFunctionScenario(
  "api-workouts",
  "../api/workouts/index.ts",
  async () => {
    const detail = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageWorkoutId}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(detail.status, 200);
    assertEquals(objectValue(detail.body, "id"), coverageWorkoutId);

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageWorkoutId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          notes: "edge e2e patched workout",
          duration_minutes: 50,
        }),
      },
    );
    assertEquals(patched.status, 200);
    assertEquals(objectValue(patched.body, "id"), coverageWorkoutId);

    const deleted = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageWorkoutId}`,
      {
        method: "DELETE",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(deleted.status, 200);
    assertEquals(objectValue(deleted.body, "ok"), true);

    const undo = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageWorkoutId}/undo`,
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({}),
      },
    );
    assertEquals(undo.status, 200);
    assertEquals(objectValue(undo.body, "ok"), true);
  },
);

await runFunctionScenario(
  "api-workouts-calendar",
  "../api/workouts/calendar/index.ts",
  async () => {
    const calendar = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?from=${coverageScenarioNextDate}&to=${coverageScenarioNextDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(calendar.status, 200);
    assertEquals(Array.isArray(objectValue(calendar.body, "days")), true);
  },
);

await runFunctionScenario(
  "api-workouts-daily",
  "../api/workouts/daily/index.ts",
  async () => {
    const daily = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?date=${coverageScenarioNextDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(daily.status, 200);
    assertEquals(Array.isArray(objectValue(daily.body, "sessions")), true);
  },
);

await runFunctionScenario(
  "api-workouts-summary",
  "../api/workouts/summary/index.ts",
  async () => {
    const summary = await requestJson(
      LOCAL_FUNCTION_URL,
      "/?days=30",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(summary.status, 200);
    assertEquals(typeof objectValue(summary.body, "workout_count"), "number");
    assertEquals(typeof objectValue(summary.body, "total_volume"), "number");
  },
);

await runFunctionScenario(
  "api-workouts-weekly",
  "../api/workouts/weekly/index.ts",
  async () => {
    const weekly = await requestJson(
      LOCAL_FUNCTION_URL,
      `/?from=${coverageScenarioNextDate}&to=${coverageScenarioNextDate}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(weekly.status, 200);
    assertEquals(Array.isArray(objectValue(weekly.body, "weeks")), true);
  },
);

const coverageTemplateId = crypto.randomUUID();
const coverageTemplateFoodLogId = crypto.randomUUID();
await runFunctionScenario(
  "api-nutrition-templates",
  "../api/nutrition/templates/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageTemplateId,
        },
        body: JSON.stringify({
          id: coverageTemplateId,
          name: "Edge Template Oats",
          meal_type: "breakfast",
          template_items: [{ name: "Oats", weight_g: 60 }],
          calories: 228,
          protein_g: 7.8,
          fat_g: 4.2,
          carbs_g: 40.2,
          fiber_g: 6,
        }),
      },
    );
    assertEquals(created.status, 201);
    assertEquals(objectValue(created.body, "id"), coverageTemplateId);

    const listed = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(listed.status, 200);
    assertEquals(Array.isArray(objectValue(listed.body, "templates")), true);

    const detail = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageTemplateId}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(detail.status, 200);
    assertEquals(objectValue(detail.body, "id"), coverageTemplateId);

    const logged = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageTemplateId}/log`,
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageTemplateFoodLogId,
        },
        body: JSON.stringify({
          logged_at: `${coverageScenarioDate}T12:00:00.000Z`,
          logged_date: coverageScenarioDate,
          context: "home",
        }),
      },
    );
    assertEquals(logged.status, 202);
    assertEquals(
      objectValue(logged.body, "food_log_id"),
      coverageTemplateFoodLogId,
    );

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageTemplateId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ archived: true }),
      },
    );
    assertEquals(patched.status, 200);
    assertEquals(objectValue(patched.body, "archived"), true);
  },
);

const coverageBatchId = crypto.randomUUID();
const coverageBatchFoodLogId = crypto.randomUUID();
const coverageBatchFoodItemId = crypto.randomUUID();
await runFunctionScenario(
  "api-nutrition-batches",
  "../api/nutrition/batches/index.ts",
  async () => {
    const created = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageBatchId,
        },
        body: JSON.stringify({
          id: coverageBatchId,
          name: "Edge Batch Chili",
          description: "coverage batch",
          cooked_at: coverageScenarioDate,
          total_weight_g: 1000,
          total_portions: 4,
          ingredients: [
            {
              name: "Beans",
              weight_g: 600,
              macros_total: {
                calories: 720,
                protein_g: 42,
                fat_g: 6,
                carbs_g: 126,
                fiber_g: 36,
              },
            },
            {
              name: "Rice",
              weight_g: 400,
              macros_total: {
                calories: 520,
                protein_g: 10,
                fat_g: 1,
                carbs_g: 112,
                fiber_g: 2,
              },
            },
          ],
        }),
      },
    );
    assertEquals(created.status, 201);
    assertEquals(objectValue(created.body, "id"), coverageBatchId);

    const listed = await requestJson(
      LOCAL_FUNCTION_URL,
      "/?status=active",
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(listed.status, 200);
    assertEquals(Array.isArray(objectValue(listed.body, "results")), true);

    const detail = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageBatchId}`,
      {
        method: "GET",
        headers: authHeaders(auth.accessToken),
      },
    );
    assertEquals(detail.status, 200);
    assertEquals(objectValue(detail.body, "id"), coverageBatchId);

    const logged = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageBatchId}/log`,
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": coverageBatchFoodLogId,
        },
        body: JSON.stringify({
          food_log_id: coverageBatchFoodLogId,
          food_item_id: coverageBatchFoodItemId,
          portion_weight_g: 250,
          logged_at: `${coverageScenarioDate}T18:00:00.000Z`,
          logged_date: coverageScenarioDate,
          meal_type: "dinner",
          context: "home",
        }),
      },
    );
    assertEquals(logged.status, 202);
    assertEquals(objectValue(logged.body, "batch_id"), coverageBatchId);

    const patched = await requestJson(
      LOCAL_FUNCTION_URL,
      `/${coverageBatchId}`,
      {
        method: "PATCH",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({ archived: true }),
      },
    );
    assertEquals(patched.status, 200);
    assertEquals(objectValue(patched.body, "ok"), true);
  },
);

await runFunctionScenario(
  "parse-food-text",
  "../parse-food-text/index.ts",
  async () => {
    const parsed = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          text: "40g oatmeal, 1 banana",
          locale: "en-US",
          meal_type: "breakfast",
        }),
      },
    );
    assertEquals(parsed.status, 200);
    assertEquals(Array.isArray(objectValue(parsed.body, "items")), true);
    assertEquals(objectValue(parsed.body, "meal_type"), "breakfast");
  },
);

await runFunctionScenario(
  "ai-openrouter-gateway",
  "../ai/openrouter-gateway/index.ts",
  async () => {
    const missingKey = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          model: "openai/gpt-4o-mini",
          messages: [{ role: "user", content: "ping" }],
          max_tokens: 8,
        }),
      },
    );
    assertEquals(missingKey.status, 500);
    assertEquals(
      objectValue(missingKey.body, "error"),
      "openrouter_key_not_configured",
    );
  },
);

await runFunctionScenario(
  "analyze-food-image",
  "../analyze-food-image/index.ts",
  async () => {
    const missingKey = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          image_base64: tinyPngDataUrl,
          context: "home",
          locale: "en-US",
          recognized_text: "oatmeal banana",
        }),
      },
    );
    assertEquals(missingKey.status, 500);
    assertEquals(
      objectValue(missingKey.body, "error"),
      "openrouter_key_not_configured",
    );
  },
);

await runFunctionScenario(
  "analyze-food-label",
  "../analyze-food-label/index.ts",
  async () => {
    const missingKey = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          barcode: "4601234500007",
          locale: "en-US",
          images_base64: [tinyPngDataUrl],
        }),
      },
    );
    assertEquals(missingKey.status, 500);
    assertEquals(
      objectValue(missingKey.body, "error"),
      "openrouter_key_not_configured",
    );
  },
);

await runFunctionScenario(
  "analyze-batch-recipe-image",
  "../analyze-batch-recipe-image/index.ts",
  async () => {
    const missingKey = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          recipe_name: "Chili",
          total_weight_grams: 1000,
          portions_planned: 4,
          cooking_method: "stewed",
          known_ingredients: [{ name: "beans", raw_weight_g: 600 }],
          image_base64: tinyPngDataUrl,
          locale: "en-US",
        }),
      },
    );
    assertEquals(missingKey.status, 500);
    assertEquals(
      objectValue(missingKey.body, "error"),
      "openrouter_key_not_configured",
    );
  },
);

await runFunctionScenario(
  "api-insights-predict",
  "../api/insights/predict/index.ts",
  async () => {
    const prediction = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: jsonAuthHeaders(auth.accessToken),
        body: JSON.stringify({
          target_date: "2026-02-26",
          scenario_text: "Sleep 8 hours and do a light mobility session.",
          scenario_type: "sleep",
          environmental_context: {
            city: "Novosibirsk",
            weather_condition: "cold",
            temperature_celsius: -8,
          },
        }),
      },
    );
    assertEquals(prediction.status, 200);
    assertEquals(
      Array.isArray(objectValue(prediction.body, "predicted_recovery_range")),
      true,
    );
    assertEquals(
      objectValue(prediction.body, "fallback_mode"),
      "deterministic",
    );
  },
);

await runFunctionScenario(
  "send-notification",
  "../send-notification/index.ts",
  async () => {
    await deleteRestRows(env, "notification_settings", {
      user_id: `eq.${publicUserId}`,
    });
    await upsertRestRows(env, "notification_settings", {
      id: crypto.randomUUID(),
      user_id: publicUserId,
      morning_brief_enabled: true,
      positive_enabled: true,
      nudges_enabled: true,
      celebration_enabled: true,
      critical_only: false,
      quiet_hours_start: "22:00",
      quiet_hours_end: "07:00",
      max_total_per_day: 6,
      control_level: "advisory",
      focus_control_enabled: false,
    });

    const sent = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          ...jsonAuthHeaders(auth.accessToken),
          "Idempotency-Key": crypto.randomUUID(),
        },
        body: JSON.stringify({
          title: "Edge E2E",
          body: "Notification path coverage",
          category: "INSIGHT",
          priority: "active",
          deep_link: "lifeos://insights",
          scheduled_at_local: "2026-02-24T12:00:00.000Z",
        }),
      },
    );
    assertEquals(sent.status, 202);
    assertEquals(objectValue(sent.body, "status"), "accepted");
    assertEquals(objectValue(sent.body, "delivery_state"), "no_devices");
  },
);

await runFunctionScenario(
  "api-account-delete-worker",
  "../api/account/delete_worker/index.ts",
  async () => {
    const unauthorized = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ batch_size: 1 }),
      },
    );
    assertEquals(unauthorized.status, 401);

    const processed = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: env.serviceRoleKey,
          Authorization: `Bearer ${env.serviceRoleKey}`,
          "X-Account-Deletion-Worker": "scheduled",
        },
        body: JSON.stringify({ batch_size: 1 }),
      },
    );
    assertEquals(processed.status, 200);
    assertEquals(typeof objectValue(processed.body, "processed"), "number");
    assertEquals(Array.isArray(objectValue(processed.body, "results")), true);
  },
);

await runFunctionScenario(
  "ops-alert-dispatch",
  "../ops-alert-dispatch/index.ts",
  async () => {
    const unauthorized = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ window_minutes: 1 }),
      },
    );
    assertEquals(unauthorized.status, 401);

    const dispatched = await requestJson(
      LOCAL_FUNCTION_URL,
      "/",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: env.serviceRoleKey,
          Authorization: `Bearer ${env.serviceRoleKey}`,
          "X-Ops-Alert-Dispatcher": "scheduled",
        },
        body: JSON.stringify({ window_minutes: 1 }),
      },
    );
    assertEquals(dispatched.status, 200);
    assertEquals(
      typeof objectValue(dispatched.body, "status"),
      "string",
    );
  },
);

console.log(
  `Edge local e2e completed for primary auth user ${auth.authUserId} / public user ${publicUserId}; stress auth user ${stressAuth.authUserId} / public user ${stressPublicUserId}.`,
);

function loadEnv(): EnvConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ??
    "";

  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    throw new Error(
      "Missing SUPABASE_URL, SUPABASE_ANON_KEY, or SUPABASE_SERVICE_ROLE_KEY.",
    );
  }

  return { supabaseUrl, anonKey, serviceRoleKey };
}

async function createAuthSession(env: EnvConfig): Promise<AuthSession> {
  const email = `edge-e2e-${crypto.randomUUID()}@example.com`;
  const password = `LifeOs!${crypto.randomUUID()}`;

  const signup = await fetch(`${env.supabaseUrl}/auth/v1/signup`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.anonKey,
    },
    body: JSON.stringify({ email, password }),
  });

  const signupJson = await safeJson(signup);
  const signupToken = objectString(signupJson, "access_token") ??
    objectString(objectValueOrNull(signupJson, "session"), "access_token");
  const signupUserId = objectString(
    objectValueOrNull(signupJson, "user"),
    "id",
  );

  if (signup.ok && signupToken && signupUserId) {
    return {
      accessToken: signupToken,
      authUserId: signupUserId,
      email,
    };
  }

  const login = await fetch(
    `${env.supabaseUrl}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: env.anonKey,
      },
      body: JSON.stringify({ email, password }),
    },
  );
  const loginJson = await safeJson(login);
  const loginToken = objectString(loginJson, "access_token");
  const loginUserId = objectString(objectValueOrNull(loginJson, "user"), "id");

  if (!login.ok || !loginToken || !loginUserId) {
    throw new Error(
      `Unable to create auth session. signup=${
        JSON.stringify(signupJson)
      } login=${JSON.stringify(loginJson)}`,
    );
  }

  return {
    accessToken: loginToken,
    authUserId: loginUserId,
    email,
  };
}

async function waitForPublicUser(
  env: EnvConfig,
  authUserId: string,
  email?: string,
): Promise<string> {
  const selectUrl = new URL(`${env.supabaseUrl}/rest/v1/users`);
  selectUrl.searchParams.set("select", "id,auth_id");
  selectUrl.searchParams.set("auth_id", `eq.${authUserId}`);

  for (let i = 0; i < 30; i += 1) {
    const response = await fetch(selectUrl, {
      headers: {
        apikey: env.serviceRoleKey,
        Authorization: `Bearer ${env.serviceRoleKey}`,
      },
    });

    if (response.ok) {
      const rows = await safeJson(response);
      if (Array.isArray(rows) && rows.length > 0) {
        const id = objectString(rows[0], "id");
        if (id) return id;
      }
    }

    await delay(200);
  }

  const fallback = await fetch(`${env.supabaseUrl}/rest/v1/users`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.serviceRoleKey,
      Authorization: `Bearer ${env.serviceRoleKey}`,
      Prefer: "resolution=merge-duplicates,return=representation",
    },
    body: JSON.stringify({
      id: authUserId,
      auth_id: authUserId,
      email: email ?? null,
      timezone: "UTC",
      units: "metric",
      notification_enabled: true,
      onboarding_completed: false,
      calibration_days_remaining: 3,
      deletion_in_progress: false,
    }),
  });

  if (!fallback.ok) {
    throw new Error(
      `public.users row was not created for test auth user (fallback upsert failed with status ${fallback.status})`,
    );
  }

  return authUserId;
}

async function runFunctionScenario(
  name: string,
  relativeEntrypoint: string,
  run: () => Promise<void>,
): Promise<void> {
  const entrypointPath = pathFromUrl(
    new URL(relativeEntrypoint, import.meta.url),
  );
  console.log(`\n[edge-e2e] ${name} :: starting ${entrypointPath}`);

  const proc = new Deno.Command("deno", {
    args: [
      "run",
      "--allow-env",
      "--allow-net",
      "--allow-read",
      entrypointPath,
    ],
    cwd: pathFromUrl(REPO_ROOT),
    env: {
      SUPABASE_URL: env.supabaseUrl,
      SUPABASE_ANON_KEY: env.anonKey,
      SUPABASE_SERVICE_ROLE_KEY: env.serviceRoleKey,
      OPENROUTER_API_KEY: "",
      APNS_TEAM_ID: "",
      APNS_KEY_ID: "",
      APNS_PRIVATE_KEY_P8: "",
      APNS_BUNDLE_ID: "",
      ...forwardedEdgeEnv(),
    },
    stdout: "inherit",
    stderr: "inherit",
  }).spawn();

  try {
    await waitForFunctionReadiness();
    await run();
    console.log(`[edge-e2e] ${name} :: OK`);
  } finally {
    try {
      proc.kill("SIGTERM");
    } catch {
      // ignore
    }

    const exited = await Promise.race([
      proc.status,
      delay(2_000).then(() => null),
    ]);

    if (exited === null) {
      try {
        proc.kill("SIGKILL");
      } catch {
        // ignore
      }
      await proc.status;
    }

    await delay(150);
  }
}

async function waitForFunctionReadiness(): Promise<void> {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(LOCAL_FUNCTION_URL, {
        method: "OPTIONS",
      });

      if (
        response.status === 204 || response.status === 200 ||
        response.status === 401 || response.status === 405
      ) {
        return;
      }
    } catch {
      // server not ready
    }

    await delay(100);
  }

  throw new Error(
    "Timed out waiting for edge function to start on localhost:8000",
  );
}

function authHeaders(accessToken: string): HeadersInit {
  return {
    Authorization: `Bearer ${accessToken}`,
  };
}

function jsonAuthHeaders(accessToken: string): HeadersInit {
  return {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
  };
}

async function requestJson(
  origin: string,
  path: string,
  init: RequestInit,
): Promise<HttpResponse> {
  const response = await fetch(`${origin}${path}`, init);
  const rawText = await response.text();
  let parsed: JsonValue | string | null = null;

  if (rawText.length > 0) {
    try {
      parsed = JSON.parse(rawText) as JsonValue;
    } catch {
      parsed = rawText;
    }
  }

  return {
    status: response.status,
    body: parsed,
    headers: response.headers,
    rawText,
  };
}

function forwardedEdgeEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (
    const key of [
      "FOODS_PROVIDER_ENABLED",
      "FOODS_PROVIDER_SEARCH_ENABLED",
      "FOODS_PROVIDER_BARCODE_ENABLED",
      "OPEN_FOOD_FACTS_BASE_URL",
      "OPEN_FOOD_FACTS_USER_AGENT",
      "OPEN_FOOD_FACTS_BARCODE_TIMEOUT_MS",
      "OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS",
    ] as const
  ) {
    const value = Deno.env.get(key)?.trim();
    if (value) env[key] = value;
  }
  return env;
}

interface WatchScenarioState {
  date: string;
  dueTime: string;
  takenAtIso: string;
  supplementName: string;
  supplementCatalogId: string;
  userSupplementId: string;
  targetId: string;
  foodLogId: string;
  insightId: string;
  supplementLogId: string;
}

function createWatchScenarioState(): WatchScenarioState {
  const now = new Date();
  const date = new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: "UTC",
  }).format(now);
  const dueTime = dueSoonWallClock(now);

  return {
    date,
    dueTime,
    takenAtIso: now.toISOString(),
    supplementName: "Magnesium Glycinate Watch E2E",
    supplementCatalogId: "11111111-1111-4111-8111-111111111111",
    userSupplementId: "22222222-2222-4222-8222-222222222222",
    targetId: "33333333-3333-4333-8333-333333333333",
    foodLogId: "44444444-4444-4444-8444-444444444444",
    insightId: "55555555-5555-4555-8555-555555555555",
    supplementLogId: "66666666-6666-4666-8666-666666666666",
  };
}

function dueSoonWallClock(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  }).formatToParts(now);
  const hour = Number(parts.find((part) => part.type === "hour")?.value ?? "0");
  const minute = Number(
    parts.find((part) => part.type === "minute")?.value ?? "0",
  );
  const currentMinutes = (hour * 60) + minute;
  const targetMinutes = Math.min(currentMinutes + 30, (23 * 60) + 59);
  const targetHour = Math.floor(targetMinutes / 60);
  const targetMinute = targetMinutes % 60;
  return `${String(targetHour).padStart(2, "0")}:${
    String(targetMinute).padStart(2, "0")
  }`;
}

function localDateDaysFromToday(offset: number): string {
  const today = new Date();
  today.setUTCHours(12, 0, 0, 0);
  today.setUTCDate(today.getUTCDate() + offset);
  return today.toISOString().slice(0, 10);
}

async function resetAndSeedWatchScenario(
  env: EnvConfig,
  userId: string,
): Promise<void> {
  await deleteRestRows(env, "supplement_logs", {
    id: `eq.${watchScenario.supplementLogId}`,
  });
  await deleteRestRows(env, "insights", {
    id: `eq.${watchScenario.insightId}`,
  });
  await deleteRestRows(env, "food_logs", {
    id: `eq.${watchScenario.foodLogId}`,
  });
  await deleteRestRows(env, "daily_nutrition_targets", {
    id: `eq.${watchScenario.targetId}`,
  });
  await deleteRestRows(env, "physiological_states", {
    user_id: `eq.${userId}`,
    date: `eq.${watchScenario.date}`,
  });
  await deleteRestRows(env, "user_supplements", {
    id: `eq.${watchScenario.userSupplementId}`,
  });
  await deleteRestRows(env, "supplement_catalog", {
    id: `eq.${watchScenario.supplementCatalogId}`,
  });

  await upsertRestRows(env, "supplement_catalog", {
    id: watchScenario.supplementCatalogId,
    name: watchScenario.supplementName,
    category: "mineral",
  });
  await upsertRestRows(env, "user_supplements", {
    id: watchScenario.userSupplementId,
    user_id: userId,
    catalog_id: watchScenario.supplementCatalogId,
    custom_name: null,
    dose_amount: 300,
    dose_unit: "mg",
    frequency: "daily",
    scheduled_times: [watchScenario.dueTime],
    days_of_week: null,
    take_with_food: false,
    notes: null,
    active: true,
    started_at: watchScenario.date,
    ended_at: null,
  });
  await upsertRestRows(env, "physiological_states", {
    id: crypto.randomUUID(),
    user_id: userId,
    date: watchScenario.date,
    recovery_score: 78,
    recovery_zone: "optimal",
    confidence_score: 0.86,
    sleep_duration_hours: 7.33,
    sleep_quality_percent: 82,
    updated_at: watchScenario.takenAtIso,
  });
  await upsertRestRows(env, "daily_nutrition_targets", {
    id: watchScenario.targetId,
    user_id: userId,
    date: watchScenario.date,
    final_calories: 2000,
    final_protein_g: 140,
  });
  await upsertRestRows(env, "food_logs", {
    id: watchScenario.foodLogId,
    user_id: userId,
    logged_at: watchScenario.takenAtIso,
    logged_date: watchScenario.date,
    input_method: "manual",
    meal_type: "breakfast",
    calories: 1680,
    protein_g: 118,
    fat_g: 40,
    carbs_g: 150,
    needs_review: false,
    ai_confidence: 0.95,
  });
  await upsertRestRows(env, "insights", {
    id: watchScenario.insightId,
    user_id: userId,
    category: "general",
    title: "Hydration reminder",
    body: "Drink water earlier in the day.",
    confidence: 0.91,
    confidence_score: 0.91,
    priority: 3,
    actionable: true,
    read: false,
    acknowledged: false,
    dismissed: false,
    needs_review: false,
  });
}

async function upsertRestRows(
  env: EnvConfig,
  table: string,
  payload: Record<string, JsonValue>,
  options: { onConflict?: string } = {},
): Promise<void> {
  const url = new URL(`${env.supabaseUrl}/rest/v1/${table}`);
  if (options.onConflict) {
    url.searchParams.set("on_conflict", options.onConflict);
  }

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.serviceRoleKey,
      Authorization: `Bearer ${env.serviceRoleKey}`,
      Prefer: "resolution=merge-duplicates,return=minimal",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(
      `Failed to upsert ${table}: ${response.status} ${await response.text()}`,
    );
  }
}

async function deleteRestRows(
  env: EnvConfig,
  table: string,
  filters: Record<string, string>,
): Promise<void> {
  const url = new URL(`${env.supabaseUrl}/rest/v1/${table}`);
  for (const [key, value] of Object.entries(filters)) {
    url.searchParams.set(key, value);
  }

  const response = await fetch(url, {
    method: "DELETE",
    headers: {
      apikey: env.serviceRoleKey,
      Authorization: `Bearer ${env.serviceRoleKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(
      `Failed to delete ${table}: ${response.status} ${await response.text()}`,
    );
  }
}

async function fetchRestRows(
  env: EnvConfig,
  table: string,
  filters: Record<string, string>,
  select = "*",
): Promise<JsonValue[]> {
  const url = new URL(`${env.supabaseUrl}/rest/v1/${table}`);
  url.searchParams.set("select", select);
  for (const [key, value] of Object.entries(filters)) {
    url.searchParams.set(key, value);
  }

  const response = await fetch(url, {
    headers: {
      apikey: env.serviceRoleKey,
      Authorization: `Bearer ${env.serviceRoleKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(
      `Failed to fetch ${table}: ${response.status} ${await response.text()}`,
    );
  }

  const body = await safeJson(response);
  return Array.isArray(body) ? body : [];
}

async function safeJson(response: Response): Promise<JsonValue | null> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as JsonValue;
  } catch {
    return null;
  }
}

function objectValue(value: JsonValue | string | null, key: string): JsonValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(
      `Expected object body with key '${key}', got ${JSON.stringify(value)}`,
    );
  }

  if (!(key in value)) {
    throw new Error(
      `Missing key '${key}' in response: ${JSON.stringify(value)}`,
    );
  }

  return (value as Record<string, JsonValue>)[key];
}

function objectValueOrNull(
  value: JsonValue | null,
  key: string,
): JsonValue | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  return (value as Record<string, JsonValue>)[key] ?? null;
}

function objectString(value: JsonValue | null, key: string): string | null {
  const raw = objectValueOrNull(value, key);
  return typeof raw === "string" ? raw : null;
}

function pathFromUrl(url: URL): string {
  if (Deno.build.os === "windows") {
    return url.pathname.replace(/^\//, "");
  }
  return url.pathname;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
