import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { __medicalScanPrivacyTestHooks } from "../_shared/medical_scan_privacy.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

Deno.test("medical scan privacy hooks normalize storage URLs and chunk manifests", () => {
  const hooks = __medicalScanPrivacyTestHooks;
  assertEquals(hooks.extractStorageObjectPath(""), null);
  assertEquals(
    hooks.extractStorageObjectPath(
      "https://project.supabase.co/storage/v1/object/authenticated/medical-scans/auth-user/scan/original.jpg",
    ),
    "auth-user/scan/original.jpg",
  );
  assertEquals(
    hooks.extractStorageObjectPath(
      "https://project.supabase.co/storage/v1/object/sign/medical-scans/auth-user/scan/original.jpg?token=abc",
    ),
    "auth-user/scan/original.jpg",
  );
  assertEquals(
    hooks.extractStorageObjectPath(
      "https://project.supabase.co/storage/v1/object/render/medical-scans/auth-user/scan/original.jpg",
    ),
    "auth-user/scan/original.jpg",
  );
  assertEquals(
    hooks.extractStorageObjectPath(
      "https://project.supabase.co/storage/v1/object/public/other-bucket/auth-user/scan/original.jpg",
    ),
    null,
  );
  assertEquals(
    hooks.normalizeMedicalScanStorageObjectPaths(
      [
        "medical-scans/auth-user/scan-b/file.jpg",
        "auth-user/scan-a/file.jpg",
        "auth-user/scan-a/file.jpg",
        "../evil",
      ],
      "auth-user",
    ),
    ["auth-user/scan-a/file.jpg", "auth-user/scan-b/file.jpg"],
  );
  assertEquals(hooks.chunkArray([], 2), []);
  assertEquals(hooks.chunkArray([1, 2, 3], 2), [[1, 2], [3]]);
});

Deno.test("additional notifications and privacy edge guardrails map auth and lookup failures", async () => {
  const notificationsHandler = await captureEdgeHandler(
    "../api/settings/notifications/index.ts",
  );
  const privacyHandler = await captureEdgeHandler(
    "../api/settings/privacy/index.ts",
  );

  await withMockedEdgeRuntime({
    authUser: null,
  }, async () => {
    const response = await notificationsHandler(
      new Request("http://localhost/functions/v1/api-settings-notifications", {
        method: "GET",
        headers: { Authorization: "Bearer test-access-token" },
      }),
    );
    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });
  });

  await withMockedEdgeRuntime({
    userLookupResponse: () => jsonResponse({ message: "lookup failed" }, 500),
  }, async () => {
    const response = await notificationsHandler(
      new Request("http://localhost/functions/v1/api-settings-notifications", {
        method: "GET",
        headers: { Authorization: "Bearer test-access-token" },
      }),
    );
    assertEquals(response.status, 500);
    assertEquals((await response.json()).error, "user_lookup_failed");
  });

  await withMockedEdgeRuntime({
    publicUser: null,
  }, async () => {
    const response = await privacyHandler(
      new Request("http://localhost/functions/v1/api-settings-privacy", {
        method: "GET",
        headers: { Authorization: "Bearer test-access-token" },
      }),
    );
    assertEquals(response.status, 404);
    assertEquals(await response.json(), { error: "user_not_found" });
  });

  await withMockedEdgeRuntime({
    publicUser: {
      id: "public-user-id",
      auth_id: "auth-user-id",
    },
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user") {
          return jsonResponse({ message: "flags down" }, 500);
        }
      },
      (request, { url }) => {
        if (
          url.pathname === "/rest/v1/privacy_settings" &&
          request.method === "GET"
        ) {
          return jsonResponse([{
            id: "privacy-1",
            user_id: "public-user-id",
            menstrual_local_only: true,
            medical_scan_local_only: true,
            vector_opt_in: false,
            analytics_consent: false,
            cloud_ocr_enabled: true,
            cloud_backup_enabled: false,
            created_at: "2026-05-29T00:00:00.000Z",
            updated_at: "2026-05-29T00:00:00.000Z",
          }]);
        }
      },
    ],
  }, async () => {
    const response = await notificationsHandler(
      new Request("http://localhost/functions/v1/api-settings-notifications", {
        method: "GET",
        headers: { Authorization: "Bearer test-access-token" },
      }),
    );
    assertEquals(response.status, 500);
    assertEquals((await response.json()).error, "feature_flags_resolve_failed");
  });

  await withMockedEdgeRuntime({
    publicUser: {
      id: "public-user-id",
      auth_id: "auth-user-id",
    },
    responders: [
      (request, { url }) => {
        if (
          url.pathname === "/rest/v1/privacy_settings" &&
          request.method === "GET"
        ) {
          return jsonResponse({ message: "broken" }, 500);
        }
      },
    ],
  }, async () => {
    const response = await privacyHandler(
      new Request("http://localhost/functions/v1/api-settings-privacy", {
        method: "GET",
        headers: { Authorization: "Bearer test-access-token" },
      }),
    );
    assertEquals(response.status, 500);
    assertEquals(
      (await response.json()).error,
      "privacy_settings_fetch_failed",
    );
  });
});

Deno.test("edge handler capture fails for modules without Deno.serve", async () => {
  await assertRejects(
    () => captureEdgeHandler("./_no_serve_fixture.ts"),
    Error,
    "Failed to capture edge handler for ./_no_serve_fixture.ts",
  );
});
