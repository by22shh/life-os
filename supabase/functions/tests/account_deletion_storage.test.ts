import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { normalizeMedicalScanStoragePath } from "../_shared/account_deletion.ts";

Deno.test("normalizeMedicalScanStoragePath keeps owned raw storage paths", () => {
  const authUserId = "11111111-1111-4111-8111-111111111111";
  assertEquals(
    normalizeMedicalScanStoragePath(
      `${authUserId}/22222222-2222-4222-8222-222222222222/original.pdf`,
      authUserId,
    ),
    `${authUserId}/22222222-2222-4222-8222-222222222222/original.pdf`,
  );
});

Deno.test("normalizeMedicalScanStoragePath strips bucket prefix and signed URL shape", () => {
  const authUserId = "11111111-1111-4111-8111-111111111111";
  const objectPath =
    `${authUserId}/22222222-2222-4222-8222-222222222222/original.heic`;

  assertEquals(
    normalizeMedicalScanStoragePath(`medical-scans/${objectPath}`, authUserId),
    objectPath,
  );

  assertEquals(
    normalizeMedicalScanStoragePath(
      `https://example.supabase.co/storage/v1/object/sign/medical-scans/${objectPath}?token=abc`,
      authUserId,
    ),
    objectPath,
  );
});

Deno.test("normalizeMedicalScanStoragePath rejects foreign or malformed paths", () => {
  const authUserId = "11111111-1111-4111-8111-111111111111";

  assertEquals(normalizeMedicalScanStoragePath(null, authUserId), null);
  assertEquals(normalizeMedicalScanStoragePath("", authUserId), null);
  assertEquals(normalizeMedicalScanStoragePath("/", authUserId), null);
  assertEquals(
    normalizeMedicalScanStoragePath("medical-scans/", authUserId),
    null,
  );
  assertEquals(
    normalizeMedicalScanStoragePath(`${authUserId}`, authUserId),
    null,
  );
  assertEquals(
    normalizeMedicalScanStoragePath(
      "33333333-3333-4333-8333-333333333333/scan/original.pdf",
      authUserId,
    ),
    null,
  );
  assertEquals(
    normalizeMedicalScanStoragePath(
      "medical-scans/../11111111-1111-4111-8111-111111111111/scan/original.pdf",
      authUserId,
    ),
    null,
  );
  assertEquals(
    normalizeMedicalScanStoragePath(
      "https://example.com/not-storage/original.pdf",
      authUserId,
    ),
    null,
  );
  assertEquals(
    normalizeMedicalScanStoragePath(
      `https://example.supabase.co/medical-scans/${authUserId}/scan/original.pdf`,
      authUserId,
    ),
    null,
  );
  assertEquals(
    normalizeMedicalScanStoragePath(
      `https://example.supabase.co/storage/v1/not-object/medical-scans/${authUserId}/scan/original.pdf`,
      authUserId,
    ),
    null,
  );
});
