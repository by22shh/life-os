import {
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  isLocalDate,
  localDateInTimeZone,
  normalizeWallClockTime,
  representativeTimestampForLocalDate,
  safeTimeZone,
  utcOffsetMinutesAt,
} from "../_shared/datetime.ts";

function seededRandom(seed = 0x1234abcd): () => number {
  let state = seed >>> 0;
  return () => {
    state = (1664525 * state + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

function expectedValidDate(year: number, month: number, day: number): boolean {
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day;
}

Deno.test("isLocalDate property test: valid/invalid YYYY-MM-DD inputs", () => {
  const random = seededRandom(0x0badf00d);

  for (let i = 0; i < 5_000; i += 1) {
    const year = 1900 + Math.floor(random() * 220);
    const month = 1 + Math.floor(random() * 12);
    const day = 1 + Math.floor(random() * 31);
    const value = `${String(year).padStart(4, "0")}-${
      String(month).padStart(2, "0")
    }-${String(day).padStart(2, "0")}`;

    assertEquals(isLocalDate(value), expectedValidDate(year, month, day));
  }

  const malformed = [
    "",
    "2026-2-3",
    "2026/02/03",
    "abcd-ef-gh",
    "2026-00-01",
    "2026-01-00",
    "2026-13-01",
    "2026-12-32",
    "99999-01-01",
  ];
  for (const value of malformed) {
    assertEquals(isLocalDate(value), false);
  }
});

Deno.test("normalizeWallClockTime property test: canonicalizes valid HH:mm and HH:mm:ss", () => {
  const random = seededRandom(0x5ca1ab1e);

  for (let i = 0; i < 5_000; i += 1) {
    const hours = Math.floor(random() * 24);
    const minutes = Math.floor(random() * 60);
    const seconds = Math.floor(random() * 60);
    const useSeconds = random() > 0.5;
    const input = useSeconds
      ? `${hours}:${String(minutes).padStart(2, "0")}:${
        String(seconds).padStart(2, "0")
      }`
      : `${hours}:${String(minutes).padStart(2, "0")}`;

    const expected = `${String(hours).padStart(2, "0")}:${
      String(minutes).padStart(2, "0")
    }`;
    assertEquals(normalizeWallClockTime(input), expected);
    assertEquals(normalizeWallClockTime(`  ${input}  `), expected);
  }
});

Deno.test("normalizeWallClockTime rejects malformed and out-of-range values", () => {
  const invalidValues: unknown[] = [
    null,
    undefined,
    123,
    {},
    [],
    "",
    "24:00",
    "23:60",
    "23:59:60",
    "-1:00",
    "12:5",
    "ab:cd",
    "12:00 pm",
  ];

  for (const value of invalidValues) {
    assertEquals(normalizeWallClockTime(value), null);
  }

  const random = seededRandom(0xabcdef01);
  for (let i = 0; i < 1_000; i += 1) {
    const hours = 24 + Math.floor(random() * 100);
    const minutes = 60 + Math.floor(random() * 100);
    const value = `${hours}:${String(minutes).padStart(2, "0")}`;
    assertEquals(normalizeWallClockTime(value), null);
  }

  // Sanity check that the test above is not accidentally rejecting everything.
  assertNotEquals(normalizeWallClockTime("00:00"), null);
});

Deno.test("datetime timezone helpers normalize zones and local date mapping", () => {
  const utcDate = new Date("2026-03-14T23:30:00.000Z");

  assertEquals(safeTimeZone("Asia/Tokyo"), "Asia/Tokyo");
  assertEquals(safeTimeZone("  "), "UTC");
  assertEquals(safeTimeZone("Mars/Olympus"), "UTC");

  assertEquals(localDateInTimeZone(utcDate, "UTC"), "2026-03-14");
  assertEquals(localDateInTimeZone(utcDate, "Asia/Tokyo"), "2026-03-15");
  assertEquals(localDateInTimeZone(utcDate, "Mars/Olympus"), "2026-03-14");

  assertEquals(
    utcOffsetMinutesAt(new Date("2026-03-15T00:00:00.000Z"), "Asia/Tokyo"),
    540,
  );
  assertEquals(
    utcOffsetMinutesAt(new Date("2026-03-15T00:00:00.000Z"), "UTC"),
    0,
  );

  const representative = representativeTimestampForLocalDate(
    "2026-03-15",
    "Asia/Tokyo",
  );
  assertEquals(localDateInTimeZone(representative, "Asia/Tokyo"), "2026-03-15");

  const fallbackRepresentative = representativeTimestampForLocalDate(
    "2026-03-14",
    "Mars/Olympus",
  );
  assertEquals(
    localDateInTimeZone(fallbackRepresentative, "UTC"),
    "2026-03-14",
  );
});
