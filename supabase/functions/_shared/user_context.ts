import { handleCors } from "./cors.ts";
import { enforceRateLimit, type RateLimitTier } from "./rate_limit.ts";
import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  serviceRoleClient,
} from "./supabase.ts";

export interface UserContext {
  authUserId: string;
  userId: string;
  timezone: string | null;
  service: ReturnType<typeof serviceRoleClient>;
}

export type UserContextResult =
  | { ok: true; context: UserContext }
  | { ok: false; response: Response };

export function handleCorsPreflight(request: Request): Response | null {
  return handleCors(request);
}

export async function resolveUserContext(
  request: Request,
  tier: RateLimitTier,
  options: { allowOutboxReplayExemption?: boolean } = {},
): Promise<UserContextResult> {
  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return {
      ok: false,
      response: jsonWithRequest(request, { error: "unauthorized" }, 401),
    };
  }

  const userClient = anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) {
    return {
      ok: false,
      response: jsonWithRequest(request, { error: "unauthorized" }, 401),
    };
  }

  const service = serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id,timezone")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string; timezone: string | null }>();

  if (userLookupError) {
    return {
      ok: false,
      response: jsonWithRequest(request, {
        error: "user_lookup_failed",
        detail: userLookupError.message,
      }, 500),
    };
  }
  if (!userRow) {
    return {
      ok: false,
      response: jsonWithRequest(request, { error: "user_not_found" }, 404),
    };
  }

  const rateLimited = await enforceRateLimit(
    request,
    userRow.id,
    tier,
    options,
  );
  if (rateLimited) {
    return { ok: false, response: rateLimited };
  }

  return {
    ok: true,
    context: {
      authUserId: authData.user.id,
      userId: userRow.id,
      timezone: userRow.timezone,
      service,
    },
  };
}
