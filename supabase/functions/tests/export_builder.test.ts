import {
  assertEquals,
  assertExists,
  assertNotEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  ensureExportReady,
  fetchReadyExportArtifact,
} from "../_shared/export_builder.ts";
import {
  createMockSupabaseService,
  type MockQueryState,
} from "./_mock_supabase_service.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const JOB_ID = "22222222-2222-4222-8222-222222222222";

function filterValue(
  state: MockQueryState,
  op: string,
  column: string,
): unknown {
  return state.filters.find((filter) =>
    filter.op === op && filter.column === column
  )?.value;
}

async function withMockedDate(
  isoTimestamp: string,
  fn: () => Promise<void>,
): Promise<void> {
  const RealDate = Date;
  const fixedTime = new RealDate(isoTimestamp).getTime();

  class MockDate extends RealDate {
    constructor(value?: ConstructorParameters<typeof Date>[0]) {
      super(value ?? fixedTime);
    }

    static override now() {
      return fixedTime;
    }

    static override parse(value: string) {
      return RealDate.parse(value);
    }

    static override UTC(...args: Parameters<typeof Date.UTC>) {
      return RealDate.UTC(...args);
    }
  }

  globalThis.Date = MockDate as DateConstructor;
  try {
    await fn();
  } finally {
    globalThis.Date = RealDate;
  }
}

Deno.test("ensureExportReady reuses a non-expired artifact and refreshes the job URL", async () => {
  const existingDownloadUrl =
    "https://lifeos.app/functions/v1/api-user-export-download?export_id=22222222-2222-4222-8222-222222222222&token=token-123";
  const service = createMockSupabaseService((state) => {
    if (
      state.table === "export_artifacts" &&
      state.action === "select" &&
      state.terminal === "maybeSingle"
    ) {
      return {
        data: {
          job_id: JOB_ID,
          user_id: USER_ID,
          download_token: "token-digest",
          file_name: "lifeos_export.json",
          expires_at: "2099-01-01T00:00:00.000Z",
        },
        error: null,
      };
    }

    if (
      state.table === "export_jobs" &&
      state.action === "select" &&
      state.terminal === "maybeSingle"
    ) {
      return {
        data: { download_url: existingDownloadUrl },
        error: null,
      };
    }

    if (state.table === "export_jobs" && state.action === "update") {
      return { data: null, error: null };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const result = await ensureExportReady(
    service as never,
    USER_ID,
    JOB_ID,
    "https://lifeos.app",
  );

  assertEquals(result.status, "ready");
  assertEquals(result.downloadUrl, existingDownloadUrl);

  const refreshCall = service.__calls.find((state) =>
    state.table === "export_jobs" && state.action === "update"
  );
  assertExists(refreshCall);
  assertEquals(filterValue(refreshCall, "eq", "id"), JOB_ID);
  assertEquals(filterValue(refreshCall, "eq", "user_id"), USER_ID);
  assertEquals(
    (refreshCall.payload as Record<string, unknown>).status,
    "ready",
  );
});

Deno.test("ensureExportReady rotates tokens for artifacts migrated away from plaintext", async () => {
  const staleUrl =
    "https://lifeos.app/functions/v1/api-user-export-download?export_id=22222222-2222-4222-8222-222222222222&token=legacy";
  const service = createMockSupabaseService((state) => {
    if (
      state.table === "export_artifacts" &&
      state.action === "select" &&
      state.terminal === "maybeSingle"
    ) {
      return {
        data: {
          job_id: JOB_ID,
          user_id: USER_ID,
          download_token: "invalidated-legacy-plaintext-deadbeef",
          file_name: "lifeos_export.json",
          expires_at: "2099-01-01T00:00:00.000Z",
        },
        error: null,
      };
    }

    if (
      state.table === "export_jobs" &&
      state.action === "select" &&
      state.terminal === "maybeSingle"
    ) {
      return {
        data: { download_url: staleUrl },
        error: null,
      };
    }

    if (
      state.table === "export_artifacts" &&
      state.action === "update" &&
      state.terminal === "then"
    ) {
      return { data: null, error: null };
    }

    if (state.table === "export_jobs" && state.action === "update") {
      return { data: null, error: null };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const result = await ensureExportReady(
    service as never,
    USER_ID,
    JOB_ID,
    "https://lifeos.app",
  );

  assertEquals(result.status, "ready");
  assertExists(result.downloadUrl);
  assertNotEquals(result.downloadUrl, staleUrl);

  const rotation = service.__calls.find((state) =>
    state.table === "export_artifacts" && state.action === "update"
  );
  assertExists(rotation);
  const rotatedToken = (rotation.payload as Record<string, unknown>)
    .download_token as string;
  // Only the digest is persisted, never the raw rotating token.
  assertEquals(/^[0-9a-f]{64}$/.test(rotatedToken), true);
});

Deno.test("ensureExportReady expires stale artifacts and short-circuits expired jobs", async () => {
  await withMockedDate("2026-05-29T12:00:00.000Z", async () => {
    const staleArtifactService = createMockSupabaseService((state) => {
      if (
        state.table === "export_artifacts" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: {
            job_id: JOB_ID,
            user_id: USER_ID,
            download_token: "token-123",
            file_name: "lifeos_export.json",
            expires_at: "2026-05-28T12:00:00.000Z",
          },
          error: null,
        };
      }

      if (state.table === "export_jobs" && state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const staleResult = await ensureExportReady(
      staleArtifactService as never,
      USER_ID,
      JOB_ID,
      "https://lifeos.app",
    );

    assertEquals(staleResult, { status: "expired", downloadUrl: null });
    const staleExpireCall = staleArtifactService.__calls.find((state) =>
      state.table === "export_jobs" && state.action === "update"
    );
    assertExists(staleExpireCall);
    assertEquals(
      (staleExpireCall.payload as Record<string, unknown>).status,
      "expired",
    );

    const expiredJobService = createMockSupabaseService((state) => {
      if (
        state.table === "export_artifacts" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: {
            id: JOB_ID,
            status: "expired",
            download_url: null,
            completed_at: null,
            failure_reason: null,
          },
          error: null,
        };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const expiredJobResult = await ensureExportReady(
      expiredJobService as never,
      USER_ID,
      JOB_ID,
      "https://lifeos.app",
    );

    assertEquals(expiredJobResult, { status: "expired", downloadUrl: null });
    assertEquals(
      expiredJobService.__calls.some((state) =>
        state.table === "export_jobs" && state.action === "update"
      ),
      false,
    );
  });
});

Deno.test("ensureExportReady builds a fresh export, redacts sensitive fields, and marks the job ready", async () => {
  await withMockedDate("2026-05-29T12:00:00.000Z", async () => {
    const pagedRows: Record<string, Array<Record<string, unknown>>> = {
      analytics_events: [
        {
          id: "event-1",
          location_lat: 55.03,
          location_lng: 82.92,
          event_name: "opened_app",
        },
      ],
      medical_scans: [
        {
          id: "scan-1",
          image_url: "user/scan-1/original.pdf",
          original_image_url: "user/scan-1/original.pdf",
          processed_data: {
            raw_pdf: "very-secret",
          },
        },
      ],
      notification_log: [
        {
          id: "notification-1",
          device_token: "push-token",
          body: "hi",
        },
      ],
    };

    const service = createMockSupabaseService((state) => {
      if (
        state.table === "export_artifacts" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: {
            id: JOB_ID,
            status: "requested",
            download_url: null,
            completed_at: null,
            failure_reason: null,
          },
          error: null,
        };
      }

      if (
        [
          "users",
          "notification_settings",
          "privacy_settings",
          "onboarding_state",
          "user_baselines",
          "user_health_flags",
        ].includes(state.table) && state.terminal === "maybeSingle"
      ) {
        if (state.table === "users") {
          return {
            data: {
              id: USER_ID,
              email: "user@example.com",
            },
            error: null,
          };
        }
        return { data: null, error: null };
      }

      if (
        state.action === "select" &&
        state.terminal === "then" &&
        state.table === "vector_memory"
      ) {
        return { count: 7, error: null };
      }

      if (
        state.action === "select" &&
        state.terminal === "then" &&
        state.range
      ) {
        const rows = pagedRows[state.table] ?? [];
        return {
          data: rows.slice(state.range.from, state.range.to + 1),
          error: null,
        };
      }

      if (
        state.table === "export_artifacts" &&
        state.action === "upsert" &&
        state.terminal === "then"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "update" &&
        state.terminal === "then"
      ) {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const result = await ensureExportReady(
      service as never,
      USER_ID,
      JOB_ID,
      "https://lifeos.app",
    );

    assertEquals(result.status, "ready");

    const artifactUpsert = service.__calls.find((state) =>
      state.table === "export_artifacts" &&
      state.action === "upsert"
    );
    assertExists(artifactUpsert);
    const artifactPayload = artifactUpsert.payload as Record<string, unknown>;
    const payloadJson = artifactPayload.payload_json as Record<string, unknown>;
    const health = payloadJson.health as Record<string, unknown>;
    const privacy = payloadJson.privacy as Record<string, unknown>;
    const medicalScans = health.medical_scans as Array<Record<string, unknown>>;
    const notificationLog = privacy.notification_log as Array<
      Record<string, unknown>
    >;
    const analyticsEvents = privacy.analytics_events as Array<
      Record<string, unknown>
    >;

    assertEquals(medicalScans[0].image_url, "[REDACTED]");
    assertEquals(medicalScans[0].original_image_url, "[REDACTED]");
    assertEquals(
      (medicalScans[0].processed_data as Record<string, unknown>).raw_pdf,
      "[REDACTED]",
    );
    assertEquals(notificationLog[0].device_token, "[REDACTED]");
    assertEquals(analyticsEvents[0].location_lat, "[REDACTED]");
    assertEquals(
      (privacy.vector_summary as Record<string, unknown>).entry_count,
      7,
    );

    const jobUpdates = service.__calls.filter((state) =>
      state.table === "export_jobs" && state.action === "update"
    );
    assertEquals(jobUpdates.length, 2);
    assertEquals(
      (jobUpdates[0].payload as Record<string, unknown>).status,
      "processing",
    );
    assertEquals(
      (jobUpdates[1].payload as Record<string, unknown>).status,
      "ready",
    );
  });
});

Deno.test("ensureExportReady tolerates missing optional relations and records failures for hard export errors", async () => {
  await withMockedDate("2026-05-29T12:00:00.000Z", async () => {
    const missingRelationService = createMockSupabaseService((state) => {
      if (
        state.table === "export_artifacts" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: {
            id: JOB_ID,
            status: "requested",
            download_url: null,
            completed_at: null,
            failure_reason: null,
          },
          error: null,
        };
      }

      if (
        ["notification_settings", "privacy_settings"].includes(state.table) &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: null,
          error: { code: "42P01", message: `${state.table} does not exist` },
        };
      }

      if (
        ["users", "onboarding_state", "user_baselines", "user_health_flags"]
          .includes(state.table) &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["medical_scans", "analytics_events", "notification_log"].includes(
          state.table,
        ) &&
        state.action === "select" &&
        state.terminal === "then"
      ) {
        return {
          data: null,
          error: { code: "42P01", message: `${state.table} does not exist` },
        };
      }

      if (
        state.table === "vector_memory" &&
        state.action === "select" &&
        state.terminal === "then"
      ) {
        return {
          count: null,
          error: { code: "42P01", message: "vector_memory does not exist" },
        };
      }

      if (
        state.action === "select" &&
        state.terminal === "then" &&
        state.range
      ) {
        return { data: [], error: null };
      }

      if (
        state.table === "export_artifacts" &&
        state.action === "upsert" &&
        state.terminal === "then"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "update" &&
        state.terminal === "then"
      ) {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const missingRelationResult = await ensureExportReady(
      missingRelationService as never,
      USER_ID,
      JOB_ID,
      "https://lifeos.app",
    );

    assertEquals(missingRelationResult.status, "ready");
    const missingRelationArtifact = missingRelationService.__calls.find((
      state,
    ) => state.table === "export_artifacts" && state.action === "upsert");
    assertExists(missingRelationArtifact);
    const missingRelationPayload = missingRelationArtifact.payload as Record<
      string,
      unknown
    >;
    const exportPayload = missingRelationPayload.payload_json as Record<
      string,
      unknown
    >;
    assertEquals(
      (exportPayload.settings as Record<string, unknown>).notification_settings,
      null,
    );
    assertEquals(
      ((exportPayload.privacy as Record<string, unknown>)
        .vector_summary as Record<string, unknown>).entry_count,
      0,
    );

    const failingService = createMockSupabaseService((state) => {
      if (
        state.table === "export_artifacts" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: {
            id: JOB_ID,
            status: "requested",
            download_url: null,
            completed_at: null,
            failure_reason: null,
          },
          error: null,
        };
      }

      if (state.table === "users" && state.terminal === "maybeSingle") {
        return {
          data: null,
          error: {
            message: "x".repeat(600),
          },
        };
      }

      if (
        state.table === "export_jobs" &&
        state.action === "update" &&
        state.terminal === "then"
      ) {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    await assertRejects(
      () =>
        ensureExportReady(
          failingService as never,
          USER_ID,
          JOB_ID,
          "https://lifeos.app",
        ),
      Error,
    );

    const failureUpdate = failingService.__calls.find((state) =>
      state.table === "export_jobs" &&
      state.action === "update" &&
      (state.payload as Record<string, unknown>).status === "failed"
    );
    assertExists(failureUpdate);
    assertEquals(
      String((failureUpdate.payload as Record<string, unknown>).failure_reason)
        .length <= 512,
      true,
    );

    for (
      const writeFailure of [
        {
          label: "artifact",
          shouldFail: (state: MockQueryState) =>
            state.table === "export_artifacts" &&
            state.action === "upsert" &&
            state.terminal === "then",
        },
        {
          label: "job",
          shouldFail: (state: MockQueryState) =>
            state.table === "export_jobs" &&
            state.action === "update" &&
            state.terminal === "then" &&
            (state.payload as Record<string, unknown>).status === "ready",
        },
      ]
    ) {
      const writeFailureService = createMockSupabaseService((state) => {
        if (
          state.table === "export_artifacts" &&
          state.action === "select" &&
          state.terminal === "maybeSingle"
        ) {
          return { data: null, error: null };
        }

        if (
          state.table === "export_jobs" &&
          state.action === "select" &&
          state.terminal === "maybeSingle"
        ) {
          return {
            data: {
              id: JOB_ID,
              status: "requested",
              download_url: null,
              completed_at: null,
              failure_reason: null,
            },
            error: null,
          };
        }

        if (
          [
            "users",
            "notification_settings",
            "privacy_settings",
            "onboarding_state",
            "user_baselines",
            "user_health_flags",
          ].includes(state.table) && state.terminal === "maybeSingle"
        ) {
          return { data: null, error: null };
        }

        if (
          state.table === "vector_memory" &&
          state.action === "select" &&
          state.terminal === "then"
        ) {
          return { count: null, data: null, error: null };
        }

        if (
          state.action === "select" &&
          state.terminal === "then" &&
          state.range
        ) {
          return { data: null, error: null };
        }

        if (
          writeFailure.shouldFail(state)
        ) {
          return {
            data: null,
            error: new Error(`${writeFailure.label} write failed`),
          };
        }

        if (
          state.table === "export_artifacts" &&
          state.action === "upsert" &&
          state.terminal === "then"
        ) {
          return { data: null, error: null };
        }

        if (
          state.table === "export_jobs" &&
          state.action === "update" &&
          state.terminal === "then"
        ) {
          return { data: null, error: null };
        }

        throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
      });

      await assertRejects(
        () =>
          ensureExportReady(
            writeFailureService as never,
            USER_ID,
            JOB_ID,
            "https://lifeos.app",
          ),
        Error,
        `${writeFailure.label} write failed`,
      );

      assertExists(
        writeFailureService.__calls.find((state) =>
          state.table === "export_jobs" &&
          state.action === "update" &&
          (state.payload as Record<string, unknown>).status === "failed"
        ),
      );
    }
  });
});

Deno.test("fetchReadyExportArtifact returns payload when token is valid", async () => {
  const service = createMockSupabaseService((state) => {
    if (
      state.table === "export_artifacts" &&
      state.action === "select" &&
      state.terminal === "maybeSingle"
    ) {
      return {
        data: {
          job_id: JOB_ID,
          user_id: USER_ID,
          download_token: "token-123",
          file_name: "lifeos_export.json",
          content_type: "application/json",
          expires_at: "2099-01-01T00:00:00.000Z",
          payload_json: {
            profile: { email: "user@example.com" },
          },
        },
        error: null,
      };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const result = await fetchReadyExportArtifact(
    service as never,
    USER_ID,
    JOB_ID,
    "token-123",
  );

  assertExists(result);
  assertEquals(result.artifact.file_name, "lifeos_export.json");
  assertEquals(
    (result.payload as Record<string, unknown>).profile,
    { email: "user@example.com" },
  );
});

Deno.test("fetchReadyExportArtifact returns null when lookup fails or nothing matches", async () => {
  const service = createMockSupabaseService((state) => {
    if (
      state.table === "export_artifacts" &&
      state.action === "select" &&
      state.terminal === "maybeSingle"
    ) {
      return {
        data: null,
        error: { message: "read failed" },
      };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const result = await fetchReadyExportArtifact(
    service as never,
    USER_ID,
    JOB_ID,
    "token-123",
  );

  assertEquals(result, null);
});

Deno.test("fetchReadyExportArtifact expires stale artifacts and returns null", async () => {
  await withMockedDate("2026-05-29T12:00:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (
        state.table === "export_artifacts" &&
        state.action === "select" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: {
            job_id: JOB_ID,
            user_id: USER_ID,
            download_token: "token-123",
            file_name: "lifeos_export.json",
            content_type: "application/json",
            expires_at: "2026-05-28T12:00:00.000Z",
            payload_json: { old: true },
          },
          error: null,
        };
      }

      if (state.table === "export_jobs" && state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const result = await fetchReadyExportArtifact(
      service as never,
      USER_ID,
      JOB_ID,
      "token-123",
    );

    assertEquals(result, null);
    const expireCall = service.__calls.find((state) =>
      state.table === "export_jobs" && state.action === "update"
    );
    assertExists(expireCall);
    assertEquals(
      (expireCall.payload as Record<string, unknown>).status,
      "expired",
    );
  });
});
