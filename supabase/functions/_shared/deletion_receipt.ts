import { serviceRoleClient } from "./supabase.ts";
import type { DeletionJobRow } from "./account_deletion.ts";

type Service = ReturnType<typeof serviceRoleClient>;
export async function deletionReceiptHash(token: string): Promise<string> {
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
  );
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export async function issueDeletionReceipt(
  service: Service,
  job: DeletionJobRow,
  suppliedToken?: string | null,
) {
  if (!job.audit_log_id) {
    throw new Error("deletion_receipt_audit_binding_missing");
  }
  if (suppliedToken != null && !/^[0-9a-f]{64}$/.test(suppliedToken)) {
    throw new Error("invalid_deletion_receipt");
  }
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = suppliedToken ??
    Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  const tokenHash = await deletionReceiptHash(token);
  if (suppliedToken) {
    const { data, error } = await service.from("account_deletion_receipts")
      .select("job_id,audit_log_id,expires_at").eq("token_hash", tokenHash)
      .maybeSingle<
        { job_id: string; audit_log_id: string; expires_at: string }
      >();
    if (error) throw new Error("deletion_receipt_lookup_failed");
    if (data) {
      if (data.job_id !== job.id || data.audit_log_id !== job.audit_log_id) {
        throw new Error("deletion_receipt_binding_conflict");
      }
      if (Date.parse(data.expires_at) <= Date.now()) {
        throw new Error("deletion_receipt_expired");
      }
      return {
        deletion_receipt: token,
        deletion_receipt_expires_at: data.expires_at,
      };
    }
  }
  const expiresAt = new Date(Date.now() + 60 * 24 * 60 * 60 * 1000)
    .toISOString();
  const { error } = await service.from("account_deletion_receipts").insert({
    token_hash: tokenHash,
    job_id: job.id,
    audit_log_id: job.audit_log_id,
    state: job.state,
    expires_at: expiresAt,
  });
  if (error) throw new Error("deletion_receipt_issue_failed");
  return { deletion_receipt: token, deletion_receipt_expires_at: expiresAt };
}

export async function readDeletionReceipt(
  service: Service,
  token: string,
): Promise<string | null> {
  if (!/^[0-9a-f]{64}$/.test(token)) return null;
  const { data, error } = await service.from("account_deletion_receipts")
    .select("state,expires_at").eq(
      "token_hash",
      await deletionReceiptHash(token),
    )
    .maybeSingle<{ state: string; expires_at: string }>();
  if (error) throw new Error("deletion_receipt_lookup_failed");
  if (
    !data || !Number.isFinite(Date.parse(data.expires_at)) ||
    Date.parse(data.expires_at) <= Date.now()
  ) return null;
  return data.state;
}
