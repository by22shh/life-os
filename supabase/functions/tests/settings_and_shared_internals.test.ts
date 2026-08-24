import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { __accountDeletionTestHooks } from "../_shared/account_deletion.ts";
import { __corsTestHooks } from "../_shared/cors.ts";
import {
  __datetimeTestHooks,
  localDateInTimeZone,
  representativeTimestampForLocalDate,
  safeTimeZone,
  utcOffsetMinutesAt,
} from "../_shared/datetime.ts";
import { __supplementLogHandlerTestHooks } from "../_shared/supplement_log_handler.ts";
import { captureEdgeHandler } from "./_edge_runtime_harness.ts";

async function loadEdgeModule<T>(modulePath: string): Promise<T> {
  await captureEdgeHandler(modulePath);
  return await import(new URL(modulePath, import.meta.url).href) as T;
}

Deno.test("shared internal hooks cover storage, cors, datetime, and supplement utilities", () => {
  const deletion = __accountDeletionTestHooks;
  assertEquals(deletion.chunkArray([], 2), []);
  assertEquals(deletion.chunkArray([1, 2, 3], 2), [[1, 2], [3]]);
  assertEquals(deletion.isAuthPrincipalMissing({ status: 404 }), true);
  assertEquals(
    deletion.isAuthPrincipalMissing({ message: "User not found" }),
    true,
  );
  assertEquals(deletion.isAuthPrincipalMissing({ message: "boom" }), false);
  assertEquals(deletion.isAuthPrincipalMissing({}), false);
  assertEquals(deletion.extractStorageObjectPath(""), null);
  assertEquals(deletion.extractStorageObjectPath("https://%"), null);
  assertEquals(deletion.extractStorageObjectPath("not a url"), null);
  assertEquals(
    deletion.extractStorageObjectPath(
      "https://project.supabase.co/medical-scans/auth/scan/file.jpg",
    ),
    null,
  );
  assertEquals(
    deletion.extractStorageObjectPath(
      "https://project.supabase.co/storage/v1/object/public/medical-scans/%E0%A4%A",
    ),
    null,
  );
  assertEquals(deletion.sanitizeStorageObjectPath("medical-scans/"), null);
  assertEquals(deletion.sanitizeStorageObjectPath("medical-scans"), null);
  assertEquals(
    deletion.sanitizeStorageObjectPath("medical-scans/auth/scan/file"),
    "auth/scan/file",
  );
  assertEquals(
    deletion.normalizeStorageObjectPaths(
      ["auth/scan/b", "auth/scan/a", null, "auth/scan/a"],
      "auth",
    ),
    ["auth/scan/a", "auth/scan/b"],
  );

  const cors = __corsTestHooks;
  assertEquals(cors.isValidAbsoluteUrl("https://lifeos.app"), true);
  assertEquals(cors.isValidAbsoluteUrl("https://%"), false);
  assertEquals(cors.isValidAbsoluteUrl("ftp://lifeos.app"), false);
  assertEquals(cors.isAppleAppStoreHost("apps.apple.com"), true);
  assertEquals(cors.isAppleAppStoreHost("example.com"), false);
  assertEquals(
    cors.isAppStoreSearchUrl("https://apps.apple.com/us/search?term=Life%20OS"),
    true,
  );
  assertEquals(
    cors.isAppStoreSearchUrl("https://apps.apple.com/us/app/id1234567890"),
    false,
  );
  assertEquals(cors.normalizeAppStoreId(" id1234567890 "), "1234567890");
  assertEquals(
    cors.directAppStoreUrl("1234567890"),
    "https://apps.apple.com/app/id1234567890",
  );
  assertEquals(__datetimeTestHooks.LOCAL_DATE_PATTERN.test("2026-06-01"), true);
  assertEquals(__datetimeTestHooks.TIME_INPUT_PATTERN.test("07:05:30"), true);
  assertEquals(safeTimeZone(" Mars/Olympus "), "UTC");
  assertEquals(safeTimeZone("UTC"), "UTC");
  const utcTs = representativeTimestampForLocalDate("2026-06-01", "UTC");
  assertEquals(localDateInTimeZone(utcTs, "UTC"), "2026-06-01");
  assertEquals(utcOffsetMinutesAt(utcTs, "UTC"), 0);

  const supplement = __supplementLogHandlerTestHooks;
  assertEquals(supplement.isUUID("550e8400-e29b-41d4-a716-446655440000"), true);
  assertEquals(supplement.isUUID("bad"), false);
  assertEquals(supplement.safeTimeZone("Mars/Olympus"), "UTC");
  assertEquals(supplement.normalizeWallClockTime("7:05:30"), "07:05");
  assertEquals(supplement.normalizeWallClockTime("30:05"), null);
  assertEquals(
    supplement.formatLocalDate(new Date("2026-06-01T23:30:00.000Z"), "UTC"),
    "2026-06-01",
  );

  const RealDateTimeFormat = Intl.DateTimeFormat;
  Object.defineProperty(Intl, "DateTimeFormat", {
    configurable: true,
    value: class {
      constructor(..._args: unknown[]) {}
      format(_date: Date) {
        return "fallback";
      }
      formatToParts(_date: Date) {
        return [];
      }
    },
  });
  try {
    assertEquals(
      supplement.formatLocalDate(new Date("2026-06-01T23:30:00.000Z"), "UTC"),
      "1970-01-01",
    );
  } finally {
    Object.defineProperty(Intl, "DateTimeFormat", {
      configurable: true,
      value: RealDateTimeFormat,
    });
  }
});

Deno.test("notification settings internal hooks cover normalization and fetch branches", async () => {
  const mod = await loadEdgeModule<
    typeof import("../api/settings/notifications/index.ts")
  >(
    "../api/settings/notifications/index.ts",
  );
  const hooks = mod.__notificationSettingsTestHooks;

  assertEquals(hooks.readErrorCode({ code: "23505" }), "23505");
  assertEquals(hooks.readErrorCode(null), null);
  assertEquals(hooks.readErrorCode("bad"), null);
  assertEquals(hooks.isUniqueViolation({ code: "23505" }), true);
  assertEquals(hooks.isUniqueViolation({ code: "other" }), false);

  assertEquals(
    hooks.normalizePayload({
      morning_brief_enabled: true,
      positive_enabled: false,
      nudges_enabled: true,
      celebration_enabled: false,
      critical_only: true,
      morning_brief_time_local: "7:05",
      quiet_hours_start: "23:15",
      quiet_hours_end: "6:30",
      max_positive_per_day: 9,
      max_nudges_per_day: -1,
      max_celebration_per_day: 8,
      max_total_per_day: 0,
      control_level: "guardian",
      focus_control_enabled: true,
    }),
    {
      morning_brief_enabled: true,
      positive_enabled: false,
      nudges_enabled: true,
      celebration_enabled: false,
      critical_only: true,
      morning_brief_time_local: "07:05",
      quiet_hours_start: "23:15",
      quiet_hours_end: "06:30",
      max_positive_per_day: 3,
      max_nudges_per_day: 0,
      max_celebration_per_day: 2,
      max_total_per_day: 1,
      control_level: "guardian",
      focus_control_enabled: true,
    },
  );
  assertEquals(
    hooks.normalizePayload({
      morning_brief_time_local: "bad",
      quiet_hours_start: "",
      quiet_hours_end: "99:99",
      max_positive_per_day: 1.8,
      max_nudges_per_day: 1.2,
      max_celebration_per_day: 0.2,
      max_total_per_day: 5.9,
      control_level: "advisory",
      focus_control_enabled: false,
    }),
    {
      max_positive_per_day: 1,
      max_nudges_per_day: 1,
      max_celebration_per_day: 0,
      max_total_per_day: 5,
      control_level: "advisory",
      focus_control_enabled: false,
    },
  );

  const existingRow = {
    id: "settings-1",
    user_id: "user-1",
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
    control_level: "guardian",
    focus_control_enabled: true,
    focus_control_last_granted_at: null,
    created_at: "2026-06-01T00:00:00.000Z",
    updated_at: "2026-06-01T00:00:00.000Z",
  };

  const existingService = {
    from(_table: string) {
      return {
        select() {
          return {
            eq() {
              return {
                maybeSingle: () =>
                  Promise.resolve({ data: existingRow, error: null }),
              };
            },
          };
        },
      };
    },
    rpc: () =>
      Promise.resolve({
        data: [{ flag_key: "guardian_mode_enabled", enabled: false }],
        error: null,
      }),
  };
  assertEquals(
    await hooks.fetchOrCreateSettings(existingService as never, "user-1"),
    existingRow as never,
  );
  const resolvedFlags = await hooks.resolveFeatureFlags(
    existingService as never,
    "user-1",
  );
  assertEquals(resolvedFlags.length > 0, true);

  let insertCount = 0;
  const createService = {
    from(_table: string) {
      return {
        select() {
          return {
            eq() {
              return {
                maybeSingle: () =>
                  Promise.resolve({
                    data: insertCount > 0 ? existingRow : null,
                    error: null,
                  }),
              };
            },
          };
        },
        insert() {
          insertCount += 1;
          return {
            select() {
              return {
                single: () =>
                  Promise.resolve({ data: existingRow, error: null }),
              };
            },
          };
        },
        upsert() {
          return {
            select() {
              return {
                single: () =>
                  Promise.resolve({
                    data: {
                      ...existingRow,
                      control_level: "protective",
                      focus_control_enabled: false,
                    },
                    error: null,
                  }),
              };
            },
          };
        },
      };
    },
    rpc: existingService.rpc,
  };
  assertEquals(
    await hooks.fetchOrCreateSettings(createService as never, "user-1"),
    existingRow as never,
  );
  const downgraded = await hooks.enforceGuardianFeatureFlag(
    createService as never,
    existingRow as never,
    [{ flag_key: "guardian_mode_enabled", enabled: false }] as never,
  );
  assertEquals(downgraded.control_level, "protective");
  assertEquals(downgraded.focus_control_enabled, false);
  assertEquals(
    hooks.toPublicSettings(existingRow as never).control_level,
    "guardian",
  );
  const unchanged = await hooks.enforceGuardianFeatureFlag(
    createService as never,
    {
      ...existingRow,
      control_level: "protective",
      focus_control_enabled: false,
    } as never,
    [{ flag_key: "guardian_mode_enabled", enabled: false }] as never,
  );
  assertEquals(unchanged.control_level, "protective");

  const featureFlagError = await assertRejects(() =>
    hooks.resolveFeatureFlags({
      rpc() {
        return Promise.resolve({ data: null, error: { message: "rpc_down" } });
      },
    } as never, "user-1")
  );
  assertEquals((featureFlagError as { message?: string }).message, "rpc_down");

  const notificationError = await assertRejects(() =>
    hooks.fetchSettingsByUserId({
      from() {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: () =>
                    Promise.resolve({
                      data: null,
                      error: { message: "db down" },
                    }),
                };
              },
            };
          },
        };
      },
    } as never, "user-1")
  );
  assertEquals((notificationError as { message?: string }).message, "db down");

  const createRaceFailure = await assertRejects(() =>
    hooks.fetchOrCreateSettings({
      from() {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: () =>
                    Promise.resolve({ data: null, error: null }),
                };
              },
            };
          },
          insert() {
            return {
              select() {
                return {
                  single: () =>
                    Promise.resolve({
                      data: null,
                      error: { code: "23505", message: "dup" },
                    }),
                };
              },
            };
          },
        };
      },
    } as never, "user-1")
  );
  assertEquals((createRaceFailure as { message?: string }).message, "dup");
});

Deno.test("privacy settings internal hooks cover normalization and side-effect branches", async () => {
  const mod = await loadEdgeModule<
    typeof import("../api/settings/privacy/index.ts")
  >(
    "../api/settings/privacy/index.ts",
  );
  const hooks = mod.__privacySettingsTestHooks;
  assertEquals(hooks.readErrorCode({ code: "23505" }), "23505");
  assertEquals(hooks.readErrorCode(undefined), null);
  assertEquals(hooks.readErrorCode("bad"), null);
  assertEquals(hooks.isUniqueViolation({ code: "23505" }), true);
  assertEquals(
    hooks.normalizePayload({
      menstrual_local_only: true,
      medical_scan_local_only: false,
      vector_opt_in: true,
      analytics_consent: true,
      cloud_ocr_enabled: false,
      cloud_backup_enabled: true,
    }),
    {
      menstrual_local_only: true,
      medical_scan_local_only: false,
      vector_opt_in: true,
      analytics_consent: true,
      cloud_ocr_enabled: false,
      cloud_backup_enabled: true,
    },
  );
  assertEquals(
    hooks.normalizePayload({
      medical_scan_local_only: true,
    }),
    {
      medical_scan_local_only: true,
    },
  );

  const row = {
    id: "privacy-1",
    user_id: "user-1",
    menstrual_local_only: true,
    medical_scan_local_only: false,
    vector_opt_in: false,
    analytics_consent: false,
    cloud_ocr_enabled: true,
    cloud_backup_enabled: true,
    created_at: "2026-06-01T00:00:00.000Z",
    updated_at: "2026-06-01T00:00:00.000Z",
  };

  const existingService = {
    from(table: string) {
      if (table === "privacy_settings") {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: () =>
                    Promise.resolve({ data: row, error: null }),
                };
              },
            };
          },
        };
      }
      if (table === "user_health_flags") {
        return {
          delete() {
            return {
              eq() {
                return Promise.resolve({ error: null });
              },
            };
          },
        };
      }
      if (table === "medical_scans") {
        return {
          select() {
            return {
              eq() {
                return {
                  returns: () => Promise.resolve({ data: [], error: null }),
                };
              },
            };
          },
          update() {
            return {
              eq() {
                return Promise.resolve({ error: null });
              },
            };
          },
        };
      }
      throw new Error(`unexpected table ${table}`);
    },
    schema() {
      return {
        from() {
          return {
            select() {
              return {
                eq() {
                  return {
                    in() {
                      return Promise.resolve({ data: [], error: null });
                    },
                  };
                },
              };
            },
          };
        },
      };
    },
    storage: {
      from() {
        return {
          remove: () => Promise.resolve({ error: null }),
        };
      },
    },
  };

  assertEquals(
    await hooks.fetchOrCreateSettings(existingService as never, "user-1"),
    row,
  );
  assertEquals(hooks.toPublicSettings(row as never).cloud_backup_enabled, true);
  await hooks.applyPrivacySideEffects(
    existingService as never,
    "user-1",
    "auth-1",
    row as never,
  );
  assertEquals(
    hooks.toPublicSettings({ ...row, cloud_backup_enabled: undefined } as never)
      .cloud_backup_enabled,
    false,
  );

  const noCleanupService = {
    from(table: string) {
      if (table === "privacy_settings") {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: () =>
                    Promise.resolve({ data: row, error: null }),
                };
              },
            };
          },
        };
      }
      if (table === "medical_scans") {
        return {
          select() {
            return {
              eq() {
                return {
                  returns: () => Promise.resolve({ data: [], error: null }),
                };
              },
            };
          },
          update() {
            return {
              eq() {
                return Promise.resolve({ error: null });
              },
            };
          },
        };
      }
      if (table === "user_health_flags") {
        throw new Error("cleanup should be skipped");
      }
      throw new Error(`unexpected table ${table}`);
    },
    schema: existingService.schema,
    storage: existingService.storage,
  };
  await hooks.applyPrivacySideEffects(
    noCleanupService as never,
    "user-1",
    "auth-1",
    { ...row, cloud_backup_enabled: true } as never,
  );

  const privacyError = await assertRejects(() =>
    hooks.fetchPrivacyByUserId({
      from() {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: () =>
                    Promise.resolve({
                      data: null,
                      error: { message: "db broken" },
                    }),
                };
              },
            };
          },
        };
      },
    } as never, "user-1")
  );
  assertEquals((privacyError as { message?: string }).message, "db broken");

  const privacyRaceFailure = await assertRejects(() =>
    hooks.fetchOrCreateSettings({
      from() {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: () =>
                    Promise.resolve({ data: null, error: null }),
                };
              },
            };
          },
          insert() {
            return {
              select() {
                return {
                  single: () =>
                    Promise.resolve({
                      data: null,
                      error: { code: "23505", message: "dup-privacy" },
                    }),
                };
              },
            };
          },
        };
      },
    } as never, "user-1")
  );
  assertEquals(
    (privacyRaceFailure as { message?: string }).message,
    "dup-privacy",
  );
});
