import {
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  maybeSingleNotFoundResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

function privacyRow(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
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
    ...overrides,
  };
}

Deno.test("privacy settings edge handler creates defaults and runs real cleanup side effects", async (t) => {
  const handler = await captureEdgeHandler("../api/settings/privacy/index.ts");

  await t.step(
    "GET creates a default row when privacy settings do not exist yet",
    async () => {
      let currentRow: Record<string, unknown> | null = null;

      await withMockedEdgeRuntime({
        publicUser: {
          id: "public-user-id",
          auth_id: "auth-user-id",
        },
        responders: [
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "GET"
            ) {
              return currentRow
                ? jsonResponse([currentRow])
                : maybeSingleNotFoundResponse();
            }

            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "POST" &&
              !url.searchParams.has("on_conflict")
            ) {
              currentRow = privacyRow(JSON.parse(bodyText));
              return jsonResponse(currentRow);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "GET",
            headers: {
              Authorization: "Bearer test-access-token",
            },
          }),
        );

        assertEquals(response.status, 200);
        assertEquals(await response.json(), {
          menstrual_local_only: true,
          medical_scan_local_only: true,
          vector_opt_in: false,
          analytics_consent: false,
          ai_processing_consent: false,
          cloud_ocr_enabled: true,
          cloud_backup_enabled: false,
        });
      });
    },
  );

  await t.step(
    "returns preflight, method, auth, rate-limit, json, and payload guardrails",
    async () => {
      await withMockedEdgeRuntime({
        publicUser: {
          id: "public-user-id",
          auth_id: "auth-user-id",
        },
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 8,
            remaining: 0,
            reset_epoch_seconds: Math.floor(Date.now() / 1000) + 8,
          }]),
      }, async () => {
        const preflight = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "OPTIONS",
            headers: {
              Origin: "https://app.lifeos.test",
              "Access-Control-Request-Method": "PATCH",
            },
          }),
        );
        assertEquals(preflight.status, 204);

        const methodNotAllowed = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "DELETE",
          }),
        );
        assertEquals(methodNotAllowed.status, 405);

        const unauthorized = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "GET",
          }),
        );
        assertEquals(unauthorized.status, 401);

        const rateLimited = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "GET",
            headers: {
              Authorization: "Bearer test-access-token",
            },
          }),
        );
        assertEquals(rateLimited.status, 429);
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
              return jsonResponse([privacyRow()]);
            }
          },
        ],
      }, async () => {
        const invalidJson = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "PATCH",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: "{",
          }),
        );
        assertEquals(invalidJson.status, 400);
        assertEquals(await invalidJson.json(), { error: "invalid_json" });

        const invalidPayload = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "PATCH",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ cloud_backup_enabled: "off" }),
          }),
        );
        assertEquals(invalidPayload.status, 400);
        assertEquals((await invalidPayload.json()).error, "invalid_payload");
      });
    },
  );

  await t.step(
    "PATCH clears cloud data, deletes storage objects, and forces local-only mode",
    async () => {
      let currentRow = privacyRow({
        medical_scan_local_only: false,
        cloud_backup_enabled: true,
      });

      await withMockedEdgeRuntime({
        publicUser: {
          id: "public-user-id",
          auth_id: "auth-user-id",
        },
        responders: [
          (request, { url }) => {
            if (
              url.pathname === "/rest/v1/vector_memory" &&
              request.method === "HEAD"
            ) {
              return new Response(null, {
                status: 200,
                headers: { "Content-Range": "*/0" },
              });
            }
          },
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([currentRow]);
            }

            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "POST" &&
              url.searchParams.get("on_conflict") === "user_id"
            ) {
              currentRow = privacyRow({
                ...currentRow,
                ...JSON.parse(bodyText),
                updated_at: "2026-05-29T12:00:00.000Z",
              });
              return jsonResponse(currentRow);
            }

            if (
              url.pathname === "/rest/v1/user_health_flags" &&
              request.method === "DELETE"
            ) {
              return jsonResponse([]);
            }

            if (
              url.pathname === "/rest/v1/medical_scans" &&
              request.method === "GET"
            ) {
              return jsonResponse([{
                image_url:
                  "https://project.supabase.co/storage/v1/object/public/medical-scans/auth-user-id/scan-1/processed.jpg",
                original_image_url:
                  "https://project.supabase.co/storage/v1/object/authenticated/medical-scans/auth-user-id/scan-1/original.jpg",
              }]);
            }

            if (
              url.pathname === "/storage/v1/object/medical-scans" &&
              request.method === "DELETE"
            ) {
              return jsonResponse([]);
            }

            if (
              url.pathname === "/rest/v1/objects" &&
              request.method === "GET"
            ) {
              return jsonResponse([]);
            }

            if (
              url.pathname === "/rest/v1/medical_scans" &&
              request.method === "PATCH"
            ) {
              return jsonResponse([]);
            }
          },
        ],
      }, async (calls) => {
        const response = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "PATCH",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              cloud_backup_enabled: false,
              medical_scan_local_only: true,
            }),
          }),
        );

        const payload = await response.json();
        const storageDeleteCall = calls.fetches.find((call) =>
          call.url.pathname === "/storage/v1/object/medical-scans"
        );
        const medicalUpdateCall = calls.fetches.find((call) =>
          call.url.pathname === "/rest/v1/medical_scans" &&
          call.request.method === "PATCH"
        );
        assertExists(storageDeleteCall);
        assertExists(medicalUpdateCall);

        const deletePayload = JSON.parse(storageDeleteCall.bodyText) as {
          prefixes: string[];
        };
        const updatePayload = JSON.parse(medicalUpdateCall.bodyText) as Record<
          string,
          unknown
        >;

        assertEquals(response.status, 200);
        assertEquals(payload.cloud_backup_enabled, false);
        assertEquals(payload.medical_scan_local_only, true);
        assertEquals(deletePayload.prefixes, [
          "auth-user-id/scan-1/original.jpg",
          "auth-user-id/scan-1/processed.jpg",
        ]);
        assertEquals(updatePayload.storage_mode, "local_only");
        assertEquals(updatePayload.image_url, null);
        assertEquals(updatePayload.original_image_url, null);
      });
    },
  );

  await t.step(
    "surfaces fetch, write, and create-race branches with stable API errors",
    async () => {
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
              return jsonResponse({ message: "lookup failed" }, 500);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "GET",
            headers: {
              Authorization: "Bearer test-access-token",
            },
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(
          (await response.json()).error,
          "privacy_settings_fetch_failed",
        );
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
              return jsonResponse([privacyRow()]);
            }
            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "POST" &&
              url.searchParams.get("on_conflict") === "user_id"
            ) {
              return jsonResponse({ message: "write failed" }, 500);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "PATCH",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ analytics_consent: true }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(
          (await response.json()).error,
          "privacy_settings_update_failed",
        );
      });

      let lookupCount = 0;
      const racedRow = privacyRow();
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
              lookupCount += 1;
              return lookupCount === 1
                ? maybeSingleNotFoundResponse()
                : jsonResponse([racedRow]);
            }

            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "POST" &&
              !url.searchParams.has("on_conflict")
            ) {
              return jsonResponse({
                code: "23505",
                message: "duplicate key value violates unique constraint",
              }, 409);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "GET",
            headers: {
              Authorization: "Bearer test-access-token",
            },
          }),
        );
        assertEquals(response.status, 200);
        assertEquals((await response.json()).medical_scan_local_only, true);
      });
    },
  );

  await t.step(
    "PATCH surfaces cleanup failures when side effects cannot finish",
    async () => {
      const currentRow = privacyRow({
        medical_scan_local_only: false,
        cloud_backup_enabled: true,
      });

      await withMockedEdgeRuntime({
        publicUser: {
          id: "public-user-id",
          auth_id: "auth-user-id",
        },
        responders: [
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([currentRow]);
            }

            if (
              url.pathname === "/rest/v1/privacy_settings" &&
              request.method === "POST" &&
              url.searchParams.get("on_conflict") === "user_id"
            ) {
              return jsonResponse(privacyRow({
                ...currentRow,
                ...JSON.parse(bodyText),
                cloud_backup_enabled: false,
                medical_scan_local_only: true,
              }));
            }

            if (
              url.pathname === "/rest/v1/user_health_flags" &&
              request.method === "DELETE"
            ) {
              return jsonResponse({ message: "cleanup denied" }, 500);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/api-settings-privacy", {
            method: "PATCH",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              cloud_backup_enabled: false,
              medical_scan_local_only: true,
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 500);
        assertEquals(payload.error, "privacy_settings_side_effects_failed");
        assertEquals(payload.detail, "internal_error");
      });
    },
  );

  await t.step("maps user lookup failures and missing user rows", async () => {
    await withMockedEdgeRuntime({
      publicUser: {
        id: "public-user-id",
        auth_id: "auth-user-id",
      },
      userLookupResponse: () => jsonResponse({ message: "users down" }, 500),
    }, async () => {
      const response = await handler(
        new Request("http://localhost/functions/v1/api-settings-privacy", {
          method: "GET",
          headers: {
            Authorization: "Bearer test-access-token",
          },
        }),
      );
      assertEquals(response.status, 500);
      assertEquals((await response.json()).error, "user_lookup_failed");
    });

    await withMockedEdgeRuntime({
      publicUser: null,
    }, async () => {
      const response = await handler(
        new Request("http://localhost/functions/v1/api-settings-privacy", {
          method: "GET",
          headers: {
            Authorization: "Bearer test-access-token",
          },
        }),
      );
      assertEquals(response.status, 404);
      assertEquals((await response.json()).error, "user_not_found");
    });
  });

  await t.step("PATCH stringifies non-Error cleanup failures", async () => {
    const currentRow = privacyRow({
      medical_scan_local_only: false,
      cloud_backup_enabled: true,
    });

    await withMockedEdgeRuntime({
      publicUser: {
        id: "public-user-id",
        auth_id: "auth-user-id",
      },
      responders: [
        (request, { bodyText, url }) => {
          if (
            url.pathname === "/rest/v1/privacy_settings" &&
            request.method === "GET"
          ) {
            return jsonResponse([currentRow]);
          }

          if (
            url.pathname === "/rest/v1/privacy_settings" &&
            request.method === "POST" &&
            url.searchParams.get("on_conflict") === "user_id"
          ) {
            return jsonResponse(privacyRow({
              ...currentRow,
              ...JSON.parse(bodyText),
              cloud_backup_enabled: false,
            }));
          }

          if (
            url.pathname === "/rest/v1/user_health_flags" &&
            request.method === "DELETE"
          ) {
            throw "health flags offline";
          }

          return undefined;
        },
      ],
    }, async () => {
      const response = await handler(
        new Request("http://localhost/functions/v1/api-settings-privacy", {
          method: "PATCH",
          headers: {
            Authorization: "Bearer test-access-token",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            cloud_backup_enabled: false,
          }),
        }),
      );

      assertEquals(response.status, 500);
      const payload = await response.json();
      assertEquals(payload.error, "privacy_settings_side_effects_failed");
      assertEquals(payload.detail, "internal_error");
    });
  });
});
