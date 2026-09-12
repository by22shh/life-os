import { serviceRoleClient } from "./supabase.ts";

type Service = ReturnType<typeof serviceRoleClient>;
type Row = Record<string, unknown>;
type VectorSettings = {
  vector_opt_in: boolean;
  ai_processing_consent: boolean;
  vector_cleanup_required?: boolean;
  vector_last_sync_at?: string | null;
  vector_source_cursors?: Record<string, { at: string; id: string }>;
};
const SETTINGS =
  "vector_opt_in,ai_processing_consent,vector_cleanup_required,vector_last_sync_at,vector_source_cursors";
const REQUEST_TIMEOUT_MS = 15_000;
const SOURCE_BATCH_SIZE = 30;
const SOURCES = [
  {
    table: "food_logs",
    type: "food_log",
    date: "logged_date",
    fields: "calories,protein_g,fat_g,carbs_g,fiber_g",
    soft: true,
  },
  {
    table: "workout_sessions",
    type: "workout_session",
    date: "session_date",
    fields: "duration_minutes,total_sets,total_reps,total_volume,trimp_score",
    soft: true,
  },
  {
    table: "physiological_states",
    type: "physiological_state",
    date: "date",
    fields: "recovery_score,sleep_duration_hours,hrv_ms,resting_heart_rate_bpm",
    soft: false,
  },
  {
    table: "health_measurements",
    type: "health_measurement",
    date: "measured_at",
    fields: "value,reference_range_low,reference_range_high",
    soft: true,
  },
  {
    table: "body_composition",
    type: "body_composition",
    date: "measured_at",
    fields: "weight_kg,body_fat_percent,muscle_mass_kg",
    soft: true,
  },
  {
    table: "wellness_checks",
    type: "wellness_check",
    date: "date",
    fields: "energy_level,stress_level,muscle_soreness,wellness_score",
    soft: true,
  },
  {
    table: "supplement_logs",
    type: "supplement_log",
    date: "taken_date",
    fields: "dose_amount,with_food,was_scheduled",
    soft: true,
  },
  {
    table: "insights",
    type: "insight",
    date: "created_at",
    fields: "confidence",
    soft: false,
  },
  {
    table: "experiments",
    type: "experiment",
    date: "created_at",
    fields: "baseline_mean,intervention_mean,effect_size,p_value",
    soft: false,
  },
] as const;

function config() {
  const host = Deno.env.get("PINECONE_INDEX_HOST")?.trim();
  const key = Deno.env.get("PINECONE_API_KEY")?.trim();
  if (!host || !key) throw new Error("vector_memory_not_configured");
  const url = new URL(host.startsWith("https://") ? host : `https://${host}`);
  if (
    url.protocol !== "https:" || !url.hostname.endsWith(".pinecone.io") ||
    url.username || url.password || url.port || url.pathname !== "/"
  ) {
    throw new Error("vector_memory_invalid_index_host");
  }
  return { host: url.origin, key };
}

export function assertVectorMemoryConfigured() {
  config();
  if (!Deno.env.get("OPENROUTER_API_KEY")) {
    throw new Error("vector_embedding_not_configured");
  }
}

async function pinecone(path: string, body: Row): Promise<Row> {
  const { host, key } = config();
  const response = await fetch(`${host}${path}`, {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      "Api-Key": key,
      "Content-Type": "application/json",
      "X-Pinecone-Api-Version": "2025-10",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`vector_provider_error_${response.status}`);
  return await response.json();
}

async function embeddings(texts: string[]): Promise<number[][]> {
  const key = Deno.env.get("OPENROUTER_API_KEY");
  if (!key) throw new Error("vector_embedding_not_configured");
  const response = await fetch("https://openrouter.ai/api/v1/embeddings", {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: Deno.env.get("VECTOR_EMBEDDING_MODEL") ??
        "openai/text-embedding-3-small",
      input: texts,
      encoding_format: "float",
    }),
  });
  if (!response.ok) {
    throw new Error(`vector_embedding_error_${response.status}`);
  }
  const data = await response.json();
  if (!Array.isArray(data.data) || data.data.length !== texts.length) {
    throw new Error("vector_embedding_invalid_response");
  }
  const ordered = [...data.data].sort((a, b) => a.index - b.index);
  const vectors = ordered.map((item, index) => {
    if (
      item.index !== index || !Array.isArray(item.embedding) ||
      !item.embedding.length ||
      !item.embedding.every((n: unknown) =>
        typeof n === "number" && Number.isFinite(n)
      )
    ) throw new Error("vector_embedding_invalid_response");
    return item.embedding as number[];
  });
  if (vectors.some((v) => v.length !== vectors[0].length)) {
    throw new Error("vector_embedding_dimension_mismatch");
  }
  return vectors;
}

async function settings(
  service: Service,
  userId: string,
): Promise<VectorSettings | null> {
  const { data, error } = await service.from("privacy_settings").select(
    SETTINGS,
  )
    .eq("user_id", userId).maybeSingle<VectorSettings>();
  if (error) throw new Error("vector_consent_lookup_failed");
  return data;
}

async function mayWrite(service: Service, userId: string): Promise<boolean> {
  const p = await settings(service, userId);
  if (!p?.vector_opt_in || !p.ai_processing_consent) return false;
  const { data, error } = await service.from("users").select(
    "deletion_in_progress",
  )
    .eq("id", userId).maybeSingle<{ deletion_in_progress: boolean }>();
  if (error) throw new Error("vector_user_lookup_failed");
  return data != null && !data.deletion_in_progress;
}

async function release(
  service: Service,
  userId: string,
  operation: string,
  updates: Row = {},
) {
  const { error } = await service.from("privacy_settings").update({
    ...updates,
    vector_operation_id: null,
    vector_lease_expires_at: null,
  }).eq("user_id", userId).eq("vector_operation_id", operation);
  if (error) throw new Error("vector_operation_release_failed");
}

async function requireLease(
  service: Service,
  userId: string,
  operation: string,
) {
  const { data, error } = await service.from("privacy_settings").select(
    "vector_lease_expires_at",
  )
    .eq("user_id", userId).eq("vector_operation_id", operation)
    .maybeSingle<{ vector_lease_expires_at: string }>();
  if (
    error || !data ||
    Date.parse(data.vector_lease_expires_at) < Date.now() + 30_000
  ) {
    throw new Error("vector_operation_lease_expired");
  }
}

/** Only numeric/boolean derived fields are embedded; never notes, scans or raw text. */
export function derivedVectorSummary(
  sourceType: string,
  date: string,
  fields: Row,
): string {
  const source = SOURCES.find((s) => s.type === sourceType);
  if (!source || !/^\d{4}-\d{2}-\d{2}/.test(date)) {
    throw new Error("vector_source_invalid");
  }
  const facts = source.fields.split(",").flatMap((key) => {
    const value = fields[key];
    return (typeof value === "number" && Number.isFinite(value)) ||
        typeof value === "boolean"
      ? [`${key}=${value}`]
      : [];
  });
  return `${sourceType} ${date.slice(0, 10)}: ${facts.join(", ")}`;
}

export async function syncUserVectorMemory(
  service: Service,
  userId: string,
): Promise<{ synced: number; status: string }> {
  const p = await settings(service, userId);
  if (!p?.vector_opt_in || !p.ai_processing_consent) {
    return { synced: 0, status: "disabled" };
  }
  assertVectorMemoryConfigured();
  const operation = crypto.randomUUID();
  const { data: claimed, error } = await service.rpc("claim_vector_operation", {
    p_user_id: userId,
    p_operation_id: operation,
    p_write: true,
  });
  if (error) {
    throw new Error(
      error.code === "55P03"
        ? "vector_operation_busy"
        : "vector_operation_claim_failed",
    );
  }
  if (!claimed) return { synced: 0, status: "disabled" };
  const startedAt = new Date().toISOString();
  let backlog = false;
  const cursors = { ...p.vector_source_cursors };
  let synced = 0;
  try {
    const documents: Row[] = [];
    const deletedIds: string[] = [];
    for (const source of SOURCES) {
      const { data: previous, error: previousError } = await service.from(
        "vector_memory",
      )
        .select("vector_id,source_id").eq("user_id", userId).eq(
          "source_type",
          source.type,
        )
        .order("updated_at", { ascending: true }).limit(100)
        .returns<Array<{ vector_id: string; source_id: string }>>();
      if (previousError) throw new Error("vector_metadata_lookup_failed");
      if (previous?.length) {
        let liveQuery = service.from(source.table).select("id").eq(
          "user_id",
          userId,
        )
          .in("id", previous.map((v) => v.source_id));
        if (source.soft) liveQuery = liveQuery.is("deleted_at", null);
        const { data: live, error: liveError } = await liveQuery.returns<
          Array<{ id: string }>
        >();
        if (liveError) throw new Error("vector_source_lookup_failed");
        const liveIds = new Set((live ?? []).map((r) => r.id));
        deletedIds.push(
          ...previous.filter((v) => !liveIds.has(v.source_id)).map((v) =>
            v.vector_id
          ),
        );
        // Rotate the bounded sweep, so hard-deleted old sources do not remain
        // indefinitely and reads never repeatedly inspect just the first page.
        const { error: touchedError } = await service.from("vector_memory")
          .update({ updated_at: startedAt }).eq("user_id", userId)
          .in("vector_id", previous.map((v) => v.vector_id));
        if (touchedError) throw new Error("vector_metadata_update_failed");
      }
      let query = service.from(source.table)
        .select(
          `id,updated_at,${source.date},${source.fields}${
            source.soft ? ",deleted_at" : ""
          }`,
        )
        .eq("user_id", userId).lte("updated_at", startedAt)
        .order("updated_at", { ascending: true }).order("id", {
          ascending: true,
        });
      const cursor = cursors[source.type];
      if (cursor) {
        if (
          !Number.isFinite(Date.parse(cursor.at)) ||
          !/^[a-f0-9-]{36}$/i.test(cursor.id)
        ) throw new Error("vector_cursor_invalid");
        query = query.or(
          `updated_at.gt.${cursor.at},and(updated_at.eq.${cursor.at},id.gt.${cursor.id})`,
        );
      }
      const { data: rows, error: sourceError } = await query.limit(
        SOURCE_BATCH_SIZE,
      ).returns<Row[]>();
      if (sourceError) {
        throw new Error(`vector_source_lookup_failed_${source.type}`);
      }
      if ((rows ?? []).length === SOURCE_BATCH_SIZE) backlog = true;
      if (rows?.length) {
        cursors[source.type] = {
          at: String(rows.at(-1)!.updated_at),
          id: String(rows.at(-1)!.id),
        };
      }
      for (const row of rows ?? []) {
        const vectorId = `${userId}:${source.type}:${row.id}`;
        if (source.soft && row.deleted_at) {
          deletedIds.push(vectorId);
          continue;
        }
        const summary = derivedVectorSummary(
          source.type,
          String(row[source.date]),
          row,
        );
        documents.push({
          user_id: userId,
          vector_id: vectorId,
          vector_namespace: userId,
          source_type: source.type,
          source_id: row.id,
          event_date: String(row[source.date]).slice(0, 10),
          summary,
          searchable_text: summary,
        });
      }
    }
    if (deletedIds.length) {
      for (let offset = 0; offset < deletedIds.length; offset += 100) {
        const batch = deletedIds.slice(offset, offset + 100);
        await requireLease(service, userId, operation);
        await pinecone("/vectors/delete", { namespace: userId, ids: batch });
        const { error } = await service.from("vector_memory").delete().eq(
          "user_id",
          userId,
        ).in("vector_id", batch);
        if (error) throw new Error("vector_metadata_delete_failed");
      }
    }
    // Bounded upsert batches stay below Pinecone's 2 MB request limit.
    if (documents.length) {
      if (!await mayWrite(service, userId)) {
        throw new Error("vector_consent_revoked");
      }
      const values = await embeddings(documents.map((d) => String(d.summary)));
      if (!await mayWrite(service, userId)) {
        throw new Error("vector_consent_revoked");
      }
      // Persist the cleanup obligation before external upload, including failures.
      const { error } = await service.from("vector_memory").upsert(documents, {
        onConflict: "vector_id",
      });
      if (error) throw new Error("vector_metadata_upsert_failed");
      const vectors = documents.map((d, i) => ({
        id: d.vector_id,
        values: values[i],
        metadata: { source_type: d.source_type, event_date: d.event_date },
      }));
      let batch: typeof vectors = [];
      let bytes = 0;
      for (let index = 0; index <= vectors.length; index++) {
        const next = vectors[index];
        const size = next
          ? new TextEncoder().encode(JSON.stringify(next)).byteLength
          : 0;
        if (size > 1_500_000) throw new Error("vector_payload_too_large");
        if (batch.length && (!next || bytes + size > 1_500_000)) {
          if (!await mayWrite(service, userId)) {
            throw new Error("vector_consent_revoked");
          }
          await requireLease(service, userId, operation);
          await pinecone("/vectors/upsert", {
            namespace: userId,
            vectors: batch,
          });
          batch = [];
          bytes = 0;
        }
        if (next) {
          batch.push(next);
          bytes += size;
        }
      }
      synced = documents.length;
    }
    if (!await mayWrite(service, userId)) {
      throw new Error("vector_consent_revoked");
    }
    await release(service, userId, operation, {
      vector_last_sync_at: backlog ? null : startedAt,
      vector_source_cursors: cursors,
    });
    return { synced, status: "synced" };
  } catch (error) {
    await release(service, userId, operation);
    if (!await mayWrite(service, userId)) {
      await deleteUserVectorMemory(service, userId);
    }
    throw error;
  }
}

export async function queryUserVectorMemory(
  service: Service,
  userId: string,
  scenario: string,
): Promise<string[]> {
  if (!await mayWrite(service, userId)) return [];
  assertVectorMemoryConfigured();
  const [vector] = await embeddings([scenario.slice(0, 1000)]);
  if (!await mayWrite(service, userId)) return [];
  const result = await pinecone("/query", {
    namespace: userId,
    vector,
    topK: 6,
    includeMetadata: false,
    includeValues: false,
  });
  const ids = Array.isArray(result.matches)
    ? result.matches.flatMap((match: Row) =>
      typeof match.id === "string" && match.id.startsWith(`${userId}:`)
        ? [match.id]
        : []
    )
    : [];
  if (!ids.length || !await mayWrite(service, userId)) return [];
  const { data, error } = await service.from("vector_memory").select(
    "source_type,source_id",
  )
    .eq("user_id", userId).in("vector_id", ids).returns<
    Array<{ source_type: string; source_id: string }>
  >();
  if (error) throw new Error("vector_metadata_lookup_failed");
  const summaries: string[] = [];
  for (const source of SOURCES) {
    const sourceIds = (data ?? []).filter((d) => d.source_type === source.type)
      .map((d) => d.source_id);
    if (!sourceIds.length) continue;
    let query = service.from(source.table).select(
      `${source.date},${source.fields}`,
    ).eq("user_id", userId).in("id", sourceIds);
    if (source.soft) query = query.is("deleted_at", null);
    const { data: liveRows, error } = await query.returns<Row[]>();
    if (error) throw new Error("vector_source_lookup_failed");
    // Resolve each match against current SQL state, never stale/foreign metadata
    // returned by an eventually consistent external index.
    summaries.push(
      ...(liveRows ?? []).map((r) =>
        derivedVectorSummary(source.type, String(r[source.date]), r)
      ),
    );
  }
  return await mayWrite(service, userId) ? summaries : [];
}

/** Delete external data before SQL identity/manifest disappears; fail closed. */
export async function deleteUserVectorMemory(
  service: Service,
  userId: string,
): Promise<void> {
  const p = await settings(service, userId);
  const { count, error } = await service.from("vector_memory").select("id", {
    count: "exact",
    head: true,
  }).eq("user_id", userId);
  if (error) throw new Error("vector_metadata_lookup_failed");
  const configured = Deno.env.get("PINECONE_INDEX_HOST") &&
    Deno.env.get("PINECONE_API_KEY");
  if (!configured && !p?.vector_cleanup_required && !(count ?? 0)) return;
  config();
  const operation = crypto.randomUUID();
  const { data: claimed, error: claimError } = await service.rpc(
    "claim_vector_operation",
    { p_user_id: userId, p_operation_id: operation, p_write: false },
  );
  if (claimError) {
    throw new Error(
      claimError.code === "55P03"
        ? "vector_operation_busy"
        : "vector_operation_claim_failed",
    );
  }
  if (!claimed && p) throw new Error("vector_operation_claim_failed");
  try {
    const { data: manifest, error: manifestError } = await service.from(
      "vector_memory",
    )
      .select("vector_namespace").eq("user_id", userId).neq(
        "vector_namespace",
        userId,
      ).limit(1);
    if (manifestError) throw new Error("vector_metadata_lookup_failed");
    if ((manifest ?? []).length) {
      throw new Error("vector_legacy_namespace_requires_migration");
    }
    await pinecone("/vectors/delete", { namespace: userId, deleteAll: true });
    // Pinecone is eventually consistent. A non-zero result remains retryable,
    // and account deletion never reports completion before verification.
    const stats = await pinecone("/describe_index_stats", {});
    const namespaces = stats.namespaces as
      | Record<string, { vectorCount: number }>
      | undefined;
    if (!namespaces || typeof namespaces !== "object") {
      throw new Error("vector_delete_verification_failed");
    }
    if ((namespaces[userId]?.vectorCount ?? 0) !== 0) {
      throw new Error("vector_delete_pending");
    }
    const { error } = await service.from("vector_memory").delete().eq(
      "user_id",
      userId,
    );
    if (error) throw new Error("vector_metadata_delete_failed");
    if (claimed) {
      await release(service, userId, operation, {
        vector_cleanup_required: false,
        vector_last_sync_at: null,
        vector_source_cursors: {},
      });
    }
  } catch (error) {
    if (claimed) await release(service, userId, operation);
    throw error;
  }
}
