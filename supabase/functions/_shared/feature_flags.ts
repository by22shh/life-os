export const FEATURE_FLAG_CACHE_TTL_SECONDS = 3600;

export const DEFAULT_FEATURE_FLAGS = {
  ai_food_photo_enabled: true,
  ai_voice_logging_enabled: true,
  ai_lab_ocr_enabled: true,
  ai_insights_enabled: true,
  openrouter_available: true,
  guardian_mode_enabled: true,
  batch_recipes_enabled: true,
} as const;

export type SupportedFeatureFlagKey = keyof typeof DEFAULT_FEATURE_FLAGS;

export interface ResolvedFeatureFlagRow {
  flag_key: string;
  enabled: boolean;
  variant: string | null;
}

export function mergeResolvedFeatureFlags(
  rows: ResolvedFeatureFlagRow[] | null | undefined,
): ResolvedFeatureFlagRow[] {
  const merged = new Map<string, ResolvedFeatureFlagRow>();

  for (const [flagKey, enabled] of Object.entries(DEFAULT_FEATURE_FLAGS)) {
    merged.set(flagKey, {
      flag_key: flagKey,
      enabled,
      variant: null,
    });
  }

  for (const row of rows ?? []) {
    merged.set(row.flag_key, {
      flag_key: row.flag_key,
      enabled: row.enabled,
      variant: row.variant ?? null,
    });
  }

  return Array.from(merged.values()).sort((lhs, rhs) =>
    lhs.flag_key.localeCompare(rhs.flag_key)
  );
}

export function isFeatureFlagEnabled(
  rows: ResolvedFeatureFlagRow[] | null | undefined,
  flagKey: SupportedFeatureFlagKey,
): boolean {
  const resolved = rows?.find((row) => row.flag_key === flagKey);
  return resolved?.enabled ?? DEFAULT_FEATURE_FLAGS[flagKey];
}
