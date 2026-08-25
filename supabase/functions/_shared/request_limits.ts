export const MAX_JSON_BODY_BYTES = 1_000_000;

export type JsonBodyResult =
  | { ok: true; body: unknown }
  | { ok: false; reason: "body_too_large" | "invalid_json" };

/**
 * Parses a JSON request body while enforcing a hard byte-size ceiling before
 * and after reading, so oversized payloads are rejected before they can be
 * persisted or forwarded to upstream providers.
 */
export async function readJsonBody(
  request: Request,
  maxBytes: number = MAX_JSON_BODY_BYTES,
): Promise<JsonBodyResult> {
  const declaredLength = Number(request.headers.get("content-length") ?? "");
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    return { ok: false, reason: "body_too_large" };
  }

  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return { ok: false, reason: "invalid_json" };
  }

  if (new TextEncoder().encode(raw).byteLength > maxBytes) {
    return { ok: false, reason: "body_too_large" };
  }

  try {
    return { ok: true, body: JSON.parse(raw) };
  } catch {
    return { ok: false, reason: "invalid_json" };
  }
}
