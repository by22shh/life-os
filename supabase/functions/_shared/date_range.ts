import { isLocalDate } from "./datetime.ts";

const MS_PER_DAY = 86_400_000;

export interface DateRange {
  from: string;
  to: string;
  days: number;
}

export function parseLocalDateParam(
  request: Request,
  key: string,
): string | null {
  const value = new URL(request.url).searchParams.get(key)?.trim() ?? "";
  if (!value) return null;
  return isLocalDate(value) ? value : null;
}

export function parseRequiredLocalDate(
  request: Request,
  key: string,
): DateRange | null {
  const date = parseLocalDateParam(request, key);
  if (!date) return null;
  return { from: date, to: date, days: 1 };
}

export function parseLocalDateRange(
  request: Request,
  maxDays: number,
): DateRange | null {
  const params = new URL(request.url).searchParams;
  const from = params.get("from")?.trim() ?? "";
  const to = params.get("to")?.trim() ?? "";
  if (!isLocalDate(from) || !isLocalDate(to)) return null;

  const fromMs = Date.parse(`${from}T00:00:00.000Z`);
  const toMs = Date.parse(`${to}T00:00:00.000Z`);
  if (!Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs < fromMs) {
    return null;
  }

  const days = Math.floor((toMs - fromMs) / MS_PER_DAY) + 1;
  if (days <= 0 || days > maxDays) return null;

  return { from, to, days };
}

export function enumerateLocalDates(from: string, to: string): string[] {
  const dates: string[] = [];
  const fromMs = Date.parse(`${from}T00:00:00.000Z`);
  const toMs = Date.parse(`${to}T00:00:00.000Z`);
  for (let current = fromMs; current <= toMs; current += MS_PER_DAY) {
    dates.push(new Date(current).toISOString().slice(0, 10));
  }
  return dates;
}

export function safeTimeZone(value: string | null | undefined): string {
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

export function localDateToday(timezone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: safeTimeZone(timezone),
  }).format(new Date());
}

export function pathnameTail(pathname: string): string[] {
  const segments = pathname.split("/").filter(Boolean);
  const apiSegmentIndex = segments.findIndex((segment) =>
    segment.startsWith("api-")
  );
  if (apiSegmentIndex >= 0) {
    return segments.slice(apiSegmentIndex + 1);
  }
  return segments;
}

export function isoFromDateOnly(date: string): string {
  return `${date}T00:00:00.000Z`;
}
