import {
  assertEquals,
  assertExists,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  maybeSingleNotFoundResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

function settingsRow(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    id: "settings-1",
    user_id: "public-user-id",
    morning_brief_enabled: true,
    positive_enabled: true,
    nudges_enabled: true,
    celebration_enabled: true,
    critical_only: false,
    morning_brief_time_local: "08:00",
    quiet_hours_start: "22:00",
    quiet_hours_end: "07:00",
    max_positive_per_day: 2,
    max_nudges_per_day: 1,
    max_celebration_per_day: 1,
    max_total_per_day: 4,
    control_level: "advisory",
    focus_control_enabled: false,
    focus_control_last_granted_at: null,
    created_at: "2026-05-29T00:00:00.000Z",
    updated_at: "2026-05-29T00:00:00.000Z",
    ...overrides,
  };
}

Deno.test("notification settings edge handler enforces guardian invariants and persists normalized payloads", async (t) => {
  const handler = await captureEdgeHandler(
    "../api/settings/notifications/index.ts",
  );

  await t.step(
    "GET downgrades guardian controls when the feature flag is disabled",
    async () => {
      let currentRow = settingsRow({
        control_level: "guardian",
        focus_control_enabled: true,
        focus_control_last_granted_at: "2026-05-28T09:00:00.000Z",
      });

      await withMockedEdgeRuntime({
        responders: [
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([{
                flag_key: "guardian_mode_enabled",
                enabled: false,
                variant: null,
              }]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([currentRow]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "POST"
            ) {
              const payload = JSON.parse(bodyText) as Record<string, unknown>;
              currentRow = {
                ...currentRow,
                ...payload,
                control_level: "protective",
                focus_control_enabled: false,
              };
              return jsonResponse(currentRow);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.control_level, "protective");
        assertEquals(payload.focus_control_enabled, false);
      });
    },
  );

  await t.step(
    "returns CORS preflight, method, auth, and rate-limit guardrails",
    async () => {
      await withMockedEdgeRuntime({
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 12,
            remaining: 0,
            reset_epoch_seconds: Math.floor(Date.now() / 1000) + 12,
          }]),
      }, async () => {
        const preflight = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "OPTIONS",
              headers: {
                Origin: "https://app.lifeos.test",
                "Access-Control-Request-Method": "PATCH",
              },
            },
          ),
        );
        assertEquals(preflight.status, 204);

        const methodNotAllowed = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "DELETE",
            },
          ),
        );
        assertEquals(methodNotAllowed.status, 405);

        const unauthorized = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
            },
          ),
        );
        assertEquals(unauthorized.status, 401);

        const rateLimited = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );
        assertEquals(rateLimited.status, 429);
      });
    },
  );

  await t.step(
    "PATCH normalizes wall-clock fields, clamps counts, and forces critical-only invariants",
    async () => {
      let currentRow = settingsRow({
        control_level: "protective",
        focus_control_enabled: true,
      });

      await withMockedEdgeRuntime({
        responders: [
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([{
                flag_key: "guardian_mode_enabled",
                enabled: false,
                variant: null,
              }]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([currentRow]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "POST"
            ) {
              const payload = JSON.parse(bodyText) as Record<string, unknown>;
              currentRow = {
                ...currentRow,
                ...payload,
                updated_at: "2026-05-29T12:00:00.000Z",
              };
              return jsonResponse(currentRow);
            }
          },
        ],
      }, async (calls) => {
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                critical_only: true,
                control_level: "guardian",
                focus_control_enabled: true,
                morning_brief_time_local: "7:05",
                quiet_hours_start: "23:15",
                quiet_hours_end: "6:30",
                max_positive_per_day: 99,
                max_nudges_per_day: -2,
                max_celebration_per_day: 8,
                max_total_per_day: 0,
              }),
            },
          ),
        );

        const payload = await response.json();
        const upsertCall = calls.fetches.find((call) =>
          call.url.pathname === "/rest/v1/notification_settings" &&
          call.request.method === "POST"
        );
        assertExists(upsertCall);
        const upsertPayload = JSON.parse(upsertCall.bodyText) as Record<
          string,
          unknown
        >;

        assertEquals(response.status, 200);
        assertEquals(payload.critical_only, true);
        assertEquals(payload.control_level, "advisory");
        assertEquals(payload.focus_control_enabled, false);
        assertEquals(payload.morning_brief_time_local, "07:05");
        assertEquals(payload.quiet_hours_start, "23:15");
        assertEquals(payload.quiet_hours_end, "06:30");
        assertEquals(payload.max_positive_per_day, 3);
        assertEquals(payload.max_nudges_per_day, 0);
        assertEquals(payload.max_celebration_per_day, 2);
        assertEquals(payload.max_total_per_day, 1);
        assertEquals(upsertPayload.control_level, "advisory");
        assertEquals(upsertPayload.focus_control_enabled, false);
      });
    },
  );

  await t.step(
    "PATCH rejects invalid json, invalid payloads, and malformed times",
    async () => {
      await withMockedEdgeRuntime({
        responders: [
          (request, { url }) => {
            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([settingsRow()]);
            }
          },
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
          },
        ],
      }, async () => {
        const invalidJson = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: "{",
            },
          ),
        );
        assertEquals(invalidJson.status, 400);
        assertEquals(await invalidJson.json(), { error: "invalid_json" });

        const invalidPayload = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ critical_only: "yes" }),
            },
          ),
        );
        assertEquals(invalidPayload.status, 400);

        const invalidTime = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ quiet_hours_end: "25:10" }),
            },
          ),
        );
        assertEquals(invalidTime.status, 400);
        assertEquals(
          await invalidTime.json(),
          { error: "invalid_quiet_hours_end" },
        );

        const invalidMorning = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ morning_brief_time_local: "24:00" }),
            },
          ),
        );
        assertEquals(invalidMorning.status, 400);
        assertEquals(
          await invalidMorning.json(),
          { error: "invalid_morning_brief_time_local" },
        );

        const invalidQuietStart = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ quiet_hours_start: "25:10" }),
            },
          ),
        );
        assertEquals(invalidQuietStart.status, 400);
        assertEquals(
          await invalidQuietStart.json(),
          { error: "invalid_quiet_hours_start" },
        );
      });
    },
  );

  await t.step(
    "PATCH rejects guardian mode without focus control when the feature flag is enabled",
    async () => {
      const currentRow = settingsRow();

      await withMockedEdgeRuntime({
        responders: [
          (request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([{
                flag_key: "guardian_mode_enabled",
                enabled: true,
                variant: null,
              }]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([currentRow]);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                control_level: "guardian",
                focus_control_enabled: false,
              }),
            },
          ),
        );

        assertEquals(response.status, 400);
        assertEquals(
          await response.json(),
          { error: "guardian_requires_focus_control" },
        );
      });
    },
  );

  await t.step(
    "PATCH downgrades guardian requests when the feature flag is disabled",
    async () => {
      let currentRow = settingsRow({
        control_level: "guardian",
        focus_control_enabled: true,
      });

      await withMockedEdgeRuntime({
        responders: [
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([{
                flag_key: "guardian_mode_enabled",
                enabled: false,
                variant: null,
              }]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse([currentRow]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "POST"
            ) {
              currentRow = settingsRow(JSON.parse(bodyText));
              return jsonResponse(currentRow);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                control_level: "guardian",
                focus_control_enabled: true,
              }),
            },
          ),
        );

        const payload = await response.json();
        assertEquals(response.status, 200);
        assertEquals(payload.control_level, "protective");
        assertEquals(payload.focus_control_enabled, false);
      });
    },
  );

  await t.step(
    "surfaces feature-flag, fetch, and update failures with stable API errors",
    async () => {
      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse({ message: "rpc failed" }, 500);
            }
            if (url.pathname === "/rest/v1/notification_settings") {
              return jsonResponse([settingsRow()]);
            }
          },
        ],
      }, async () => {
        const getFailure = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );
        assertEquals(getFailure.status, 500);
        assertEquals(
          (await getFailure.json()).error,
          "feature_flags_resolve_failed",
        );
      });

      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
            if (
              url.pathname === "/rest/v1/notification_settings" &&
              url.searchParams.has("select")
            ) {
              return jsonResponse({ message: "settings down" }, 500);
            }
          },
        ],
      }, async () => {
        const getFailure = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );
        assertEquals(getFailure.status, 500);
        assertEquals((await getFailure.json()).error, "settings_fetch_failed");
      });

      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
            if (url.pathname === "/rest/v1/notification_settings") {
              return jsonResponse({ message: "write failed" }, 500);
            }
          },
        ],
      }, async () => {
        const patchFailure = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ positive_enabled: false }),
            },
          ),
        );
        assertEquals(patchFailure.status, 500);
        assertEquals(
          (await patchFailure.json()).error,
          "settings_fetch_failed",
        );
      });

      const currentRow = settingsRow();
      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
            if (
              url.pathname === "/rest/v1/notification_settings" &&
              url.searchParams.has("on_conflict")
            ) {
              return jsonResponse({ message: "upsert failed" }, 500);
            }
            if (url.pathname === "/rest/v1/notification_settings") {
              return jsonResponse([currentRow]);
            }
          },
        ],
      }, async () => {
        const patchFailure = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ positive_enabled: false }),
            },
          ),
        );
        assertEquals(patchFailure.status, 500);
        assertEquals(
          (await patchFailure.json()).error,
          "settings_update_failed",
        );
      });

      await withMockedEdgeRuntime({
        responders: [
          (request, { url }) => {
            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return jsonResponse({ message: "fetch failed" }, 500);
            }
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
          },
        ],
      }, async () => {
        const patchFailure = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "PATCH",
              headers: {
                Authorization: "Bearer test-access-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ positive_enabled: false }),
            },
          ),
        );
        assertEquals(patchFailure.status, 500);
        assertEquals(
          (await patchFailure.json()).error,
          "settings_fetch_failed",
        );
      });
    },
  );

  await t.step("maps user lookup failures and missing user rows", async () => {
    await withMockedEdgeRuntime({
      userLookupResponse: () => jsonResponse({ message: "users down" }, 500),
    }, async () => {
      const response = await handler(
        new Request(
          "http://localhost/functions/v1/api-settings-notifications",
          {
            method: "GET",
            headers: {
              Authorization: "Bearer test-access-token",
            },
          },
        ),
      );
      assertEquals(response.status, 500);
      assertEquals((await response.json()).error, "user_lookup_failed");
    });

    await withMockedEdgeRuntime({
      publicUser: null,
    }, async () => {
      const response = await handler(
        new Request(
          "http://localhost/functions/v1/api-settings-notifications",
          {
            method: "GET",
            headers: {
              Authorization: "Bearer test-access-token",
            },
          },
        ),
      );
      assertEquals(response.status, 404);
      assertEquals((await response.json()).error, "user_not_found");
    });
  });

  await t.step(
    "GET creates a default settings row when none exists yet",
    async () => {
      let currentRow: Record<string, unknown> | null = null;

      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
          },
          (request, { bodyText, url }) => {
            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              return currentRow
                ? jsonResponse([currentRow])
                : maybeSingleNotFoundResponse();
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "POST" &&
              !url.searchParams.has("on_conflict")
            ) {
              const payload = JSON.parse(bodyText) as Record<string, unknown>;
              currentRow = settingsRow(payload);
              return jsonResponse(currentRow);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.control_level, "advisory");
        assertEquals(payload.focus_control_enabled, false);
      });
    },
  );

  await t.step(
    "GET tolerates an insert race by loading the row created in parallel",
    async () => {
      let lookupCount = 0;
      const currentRow = settingsRow();

      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              return jsonResponse([]);
            }
          },
          (request, { url }) => {
            if (
              url.pathname === "/rest/v1/notification_settings" &&
              request.method === "GET"
            ) {
              lookupCount += 1;
              return lookupCount === 1
                ? maybeSingleNotFoundResponse()
                : jsonResponse([currentRow]);
            }

            if (
              url.pathname === "/rest/v1/notification_settings" &&
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
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );

        assertEquals(response.status, 200);
        assertEquals((await response.json()).control_level, "advisory");
      });
    },
  );

  await t.step(
    "GET stringifies non-Error feature flag failures",
    async () => {
      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (
              url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user"
            ) {
              throw "flags offline";
            }
            return undefined;
          },
        ],
      }, async () => {
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/api-settings-notifications",
            {
              method: "GET",
              headers: {
                Authorization: "Bearer test-access-token",
              },
            },
          ),
        );

        assertEquals(response.status, 500);
        const payload = await response.json();
        assertEquals(payload.error, "feature_flags_resolve_failed");
        assertEquals(payload.detail, "internal_error");
      });
    },
  );
});
