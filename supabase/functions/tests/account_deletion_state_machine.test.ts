import {
  assertDeletionStateTransition,
  canTransitionDeletionState,
  deletionStateIsTerminal,
} from "../_shared/account_deletion_state_machine.ts";
import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

Deno.test("account deletion state machine allows expected transitions", () => {
  assertEquals(canTransitionDeletionState("requested", "scheduled"), true);
  assertEquals(canTransitionDeletionState("requested", "auth_deleting"), true);
  assertEquals(canTransitionDeletionState("requested", "data_deleting"), true);
  assertEquals(canTransitionDeletionState("scheduled", "auth_deleting"), true);
  assertEquals(canTransitionDeletionState("scheduled", "data_deleting"), true);
  assertEquals(
    canTransitionDeletionState("scheduled", "retry_scheduled"),
    true,
  );
  assertEquals(canTransitionDeletionState("scheduled", "failed"), true);
  assertEquals(
    canTransitionDeletionState("auth_deleting", "data_deleting"),
    true,
  );
  assertEquals(canTransitionDeletionState("auth_deleting", "completed"), true);
  assertEquals(
    canTransitionDeletionState("data_deleting", "vector_verifying"),
    true,
  );
  assertEquals(canTransitionDeletionState("data_deleting", "completed"), true);
  assertEquals(
    canTransitionDeletionState("vector_verifying", "completed"),
    true,
  );
  assertEquals(
    canTransitionDeletionState("retry_scheduled", "auth_deleting"),
    true,
  );
  assertEquals(
    canTransitionDeletionState("retry_scheduled", "data_deleting"),
    true,
  );
  assertEquals(canTransitionDeletionState("failed", "data_deleting"), true);
});

Deno.test("account deletion state machine rejects invalid transitions", () => {
  assertEquals(canTransitionDeletionState("completed", "auth_deleting"), false);
  assertEquals(canTransitionDeletionState("cancelled", "completed"), false);

  assertThrows(() =>
    assertDeletionStateTransition("completed", "auth_deleting")
  );
});

Deno.test("account deletion state machine marks terminal states", () => {
  assertEquals(deletionStateIsTerminal("requested"), false);
  assertEquals(deletionStateIsTerminal("retry_scheduled"), false);
  assertEquals(deletionStateIsTerminal("completed"), true);
  assertEquals(deletionStateIsTerminal("failed"), true);
  assertEquals(deletionStateIsTerminal("cancelled"), true);
});
