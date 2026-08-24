export type DeletionJobMode = "scheduled" | "immediate";

export type DeletionJobState =
  | "requested"
  | "scheduled"
  | "auth_deleting"
  | "data_deleting"
  | "vector_verifying"
  | "retry_scheduled"
  | "completed"
  | "failed"
  | "cancelled";

const TRANSITIONS: Record<DeletionJobState, ReadonlySet<DeletionJobState>> = {
  requested: new Set([
    "scheduled",
    "auth_deleting",
    "data_deleting",
    "cancelled",
  ]),
  scheduled: new Set([
    "auth_deleting",
    "data_deleting",
    "retry_scheduled",
    "failed",
    "cancelled",
    "completed",
  ]),
  auth_deleting: new Set([
    "data_deleting",
    "retry_scheduled",
    "failed",
    "completed",
  ]),
  data_deleting: new Set([
    "auth_deleting",
    "vector_verifying",
    "retry_scheduled",
    "failed",
    "completed",
  ]),
  vector_verifying: new Set([
    "auth_deleting",
    "completed",
    "retry_scheduled",
    "failed",
  ]),
  retry_scheduled: new Set([
    "auth_deleting",
    "data_deleting",
    "failed",
    "cancelled",
  ]),
  completed: new Set(),
  failed: new Set(["auth_deleting", "data_deleting"]),
  cancelled: new Set(["requested", "scheduled"]),
};

export function canTransitionDeletionState(
  from: DeletionJobState,
  to: DeletionJobState,
): boolean {
  if (from === to) return true;
  return TRANSITIONS[from].has(to);
}

export function assertDeletionStateTransition(
  from: DeletionJobState,
  to: DeletionJobState,
): void {
  if (!canTransitionDeletionState(from, to)) {
    throw new Error(`invalid_deletion_state_transition:${from}->${to}`);
  }
}

export function deletionStateIsTerminal(state: DeletionJobState): boolean {
  return state === "completed" || state === "failed" || state === "cancelled";
}
