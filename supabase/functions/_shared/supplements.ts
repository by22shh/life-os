export interface UserSupplementRow {
  id: string;
  catalog_id: string | null;
  custom_name: string | null;
  frequency: string;
  scheduled_times: string[] | null;
  days_of_week: number[] | null;
  started_at: string;
  ended_at: string | null;
  active: boolean;
}

export interface SupplementLogRow {
  id: string;
  user_supplement_id: string | null;
  supplement_name: string;
  scheduled_time: string | null;
  taken_at: string;
  taken_date: string;
}

export interface SupplementScheduleSlot {
  time: string;
  supplements: Array<{
    name: string;
    taken: boolean;
    log_id: string | null;
  }>;
}

export interface SupplementDayResult {
  scheduled_count: number;
  taken_count: number;
  adherence_today_percent: number;
  schedule: SupplementScheduleSlot[];
  unscheduled_logs: Array<{
    time: string;
    name: string;
    log_id: string;
  }>;
}

export function buildSupplementDayResult(
  date: string,
  supplements: UserSupplementRow[],
  logs: SupplementLogRow[],
  catalogNameById: Map<string, string>,
): SupplementDayResult {
  const planned = supplements.filter((row) =>
    isSupplementScheduledOnDate(row, date)
  );

  const slotMap = new Map<
    string,
    Array<{ supplementId: string; name: string }>
  >();
  for (const supplement of planned) {
    const times = normalizedScheduledTimes(supplement);
    if (times.length === 0) continue;
    const name = supplementDisplayName(supplement, catalogNameById);
    for (const time of times) {
      const list = slotMap.get(time) ?? [];
      list.push({ supplementId: supplement.id, name });
      slotMap.set(time, list);
    }
  }

  const usedLogIds = new Set<string>();
  let takenCount = 0;

  const schedule = Array.from(slotMap.entries())
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([time, supplementsAtTime]) => {
      return {
        time,
        supplements: supplementsAtTime.map((entry) => {
          const matchingLog = logs.find((log) => {
            if (usedLogIds.has(log.id)) return false;
            const logTime = normalizeDbTime(log.scheduled_time);
            if (logTime !== time) return false;

            const byId = log.user_supplement_id != null &&
              log.user_supplement_id === entry.supplementId;
            const byName = normalizeName(log.supplement_name) ===
              normalizeName(entry.name);
            return byId || byName;
          });

          if (matchingLog) {
            usedLogIds.add(matchingLog.id);
            takenCount += 1;
          }

          return {
            name: entry.name,
            taken: matchingLog != null,
            log_id: matchingLog?.id ?? null,
          };
        }),
      };
    });

  const unscheduledLogs = logs
    .filter((log) => !usedLogIds.has(log.id))
    .map((log) => ({
      time: normalizeDbTime(log.scheduled_time) ?? log.taken_at.slice(11, 16),
      name: log.supplement_name,
      log_id: log.id,
    }))
    .sort((a, b) => a.time.localeCompare(b.time));

  const scheduledCount = schedule.reduce(
    (acc, slot) => acc + slot.supplements.length,
    0,
  );

  return {
    scheduled_count: scheduledCount,
    taken_count: takenCount,
    adherence_today_percent: scheduledCount > 0
      ? Math.round((takenCount / scheduledCount) * 100)
      : 0,
    schedule,
    unscheduled_logs: unscheduledLogs,
  };
}

export function supplementStatus(
  scheduledCount: number,
  adherencePercent: number,
): "no_data" | "complete" | "incomplete" {
  if (scheduledCount <= 0) return "no_data";
  return adherencePercent >= 80 ? "complete" : "incomplete";
}

export function isSupplementScheduledOnDate(
  row: UserSupplementRow,
  date: string,
): boolean {
  if (!row.active) return false;
  if (row.started_at > date) return false;
  if (row.ended_at != null && row.ended_at < date) return false;

  const days = normalizedDaysOfWeek(row.days_of_week);
  const dow = dayOfWeek(date);

  if (row.frequency === "weekly") {
    if (days.length === 0) return false;
    return days.includes(dow);
  }

  if (days.length > 0 && !days.includes(dow)) {
    return false;
  }

  if (row.frequency === "as_needed") {
    return false;
  }

  return true;
}

export function normalizedScheduledTimes(row: UserSupplementRow): string[] {
  const raw = Array.isArray(row.scheduled_times) ? row.scheduled_times : [];
  const normalized = raw
    .map((value) => normalizeDbTime(value))
    .filter((value): value is string => value != null);

  const unique = Array.from(new Set(normalized));
  return unique.sort((a, b) => a.localeCompare(b));
}

function supplementDisplayName(
  row: UserSupplementRow,
  catalogNameById: Map<string, string>,
): string {
  const custom = row.custom_name?.trim();
  if (custom) return custom;
  if (row.catalog_id && catalogNameById.has(row.catalog_id)) {
    return catalogNameById.get(row.catalog_id) ?? "Supplement";
  }
  return "Supplement";
}

function normalizedDaysOfWeek(value: number[] | null): number[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => Number.isInteger(item) && item >= 0 && item <= 6)
    .map((item) => Number(item));
}

function dayOfWeek(date: string): number {
  const parsed = Date.parse(`${date}T00:00:00.000Z`);
  if (!Number.isFinite(parsed)) return 0;
  return new Date(parsed).getUTCDay();
}

export function normalizeDbTime(
  value: string | null | undefined,
): string | null {
  if (typeof value !== "string") return null;
  const match = value.trim().match(/^(\d{1,2}):(\d{2})(?::\d{2})?$/);
  if (!match) return null;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (
    !Number.isInteger(hours) || !Number.isInteger(minutes) ||
    hours < 0 || hours > 23 || minutes < 0 || minutes > 59
  ) {
    return null;
  }
  return `${String(hours).padStart(2, "0")}:${
    String(minutes).padStart(2, "0")
  }`;
}

function normalizeName(value: string): string {
  return value.trim().toLowerCase();
}
