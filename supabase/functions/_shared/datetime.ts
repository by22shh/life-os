const LOCAL_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_INPUT_PATTERN = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/;

export function isLocalDate(value: string): boolean {
  const trimmed = value.trim();
  const match = LOCAL_DATE_PATTERN.exec(trimmed);
  if (!match) return false;

  const parsed = new Date(`${trimmed}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime())) return false;
  return parsed.toISOString().slice(0, 10) === trimmed;
}

export function normalizeWallClockTime(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;

  const match = TIME_INPUT_PATTERN.exec(trimmed);
  if (!match) return null;

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3] ?? "0");
  if (
    hours < 0 || hours > 23 || minutes < 0 || minutes > 59 || seconds < 0 ||
    seconds > 59
  ) {
    return null;
  }

  return `${String(hours).padStart(2, "0")}:${
    String(minutes).padStart(2, "0")
  }`;
}

export function localDateInTimeZone(date: Date, timeZone: string): string {
  const safeZone = safeTimeZone(timeZone);
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: safeZone,
  }).format(date);
}

export function utcOffsetMinutesAt(date: Date, timeZone: string): number {
  const safeZone = safeTimeZone(timeZone);
  const formatter = new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
    timeZone: safeZone,
  });
  const entries = Object.fromEntries(
    formatter
      .formatToParts(date)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, part.value]),
  );

  const asUtc = Date.UTC(
    Number(entries.year ?? "1970"),
    Number(entries.month ?? "1") - 1,
    Number(entries.day ?? "1"),
    Number(entries.hour ?? "0"),
    Number(entries.minute ?? "0"),
    Number(entries.second ?? "0"),
  );
  return Math.round((asUtc - date.getTime()) / 60_000);
}

export function representativeTimestampForLocalDate(
  date: string,
  timeZone: string,
): Date {
  const safeZone = safeTimeZone(timeZone);
  let candidate = new Date(`${date}T12:00:00.000Z`);
  let offsetMinutes = utcOffsetMinutesAt(candidate, safeZone);
  candidate = new Date(candidate.getTime() - offsetMinutes * 60_000);
  const stabilizedOffsetMinutes = utcOffsetMinutesAt(candidate, safeZone);
  if (stabilizedOffsetMinutes !== offsetMinutes) {
    candidate = new Date(
      candidate.getTime() + (offsetMinutes - stabilizedOffsetMinutes) * 60_000,
    );
    offsetMinutes = stabilizedOffsetMinutes;
  }

  if (localDateInTimeZone(candidate, safeZone) != date) {
    candidate = new Date(candidate.getTime() + 12 * 60 * 60_000);
    candidate = new Date(
      candidate.getTime() - utcOffsetMinutesAt(candidate, safeZone) * 60_000,
    );
  }
  return candidate;
}

export function safeTimeZone(value: unknown): string {
  const candidate = typeof value === "string" ? value.trim() : "";
  if (!candidate) return "UTC";
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: candidate }).format(
      new Date(),
    );
    return candidate;
  } catch {
    return "UTC";
  }
}

export const __datetimeTestHooks = {
  LOCAL_DATE_PATTERN,
  TIME_INPUT_PATTERN,
};
