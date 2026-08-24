export interface APNsDispatchRequest {
  pushToken: string;
  environment: "development" | "production";
  title: string;
  body: string;
  deepLink?: string;
  interruptionLevel?: "passive" | "active" | "time-sensitive";
}

export interface APNsDispatchSummary {
  configured: boolean;
  attempted: number;
  sent: number;
  failed: number;
  invalidTokens: string[];
}

interface APNsConfig {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  bundleId: string;
}

export async function dispatchAPNsNotifications(
  requests: APNsDispatchRequest[],
): Promise<APNsDispatchSummary> {
  const config = loadAPNsConfig();
  if (!config) {
    return {
      configured: false,
      attempted: requests.length,
      sent: 0,
      failed: 0,
      invalidTokens: [],
    };
  }

  if (requests.length === 0) {
    return {
      configured: true,
      attempted: 0,
      sent: 0,
      failed: 0,
      invalidTokens: [],
    };
  }

  const bearerToken = await createBearerToken(config);
  let sent = 0;
  let failed = 0;
  const invalidTokens: string[] = [];

  for (const request of requests) {
    const endpoint = request.environment === "development"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";

    const response = await fetch(`${endpoint}/3/device/${request.pushToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${bearerToken}`,
        "apns-topic": config.bundleId,
        "apns-push-type": "alert",
        "apns-priority": request.interruptionLevel === "time-sensitive"
          ? "10"
          : "5",
      },
      body: JSON.stringify({
        aps: {
          alert: {
            title: request.title,
            body: request.body,
          },
          sound: "default",
          "interruption-level": request.interruptionLevel ?? "active",
        },
        deep_link: request.deepLink ?? null,
      }),
    });

    if (response.ok) {
      sent += 1;
      continue;
    }

    failed += 1;
    let reason = "";
    try {
      const payload = await response.json();
      if (typeof payload?.reason === "string") {
        reason = payload.reason;
      }
    } catch {
      // ignore malformed error payload
    }

    if (
      reason === "BadDeviceToken" ||
      reason === "DeviceTokenNotForTopic" ||
      reason === "Unregistered" ||
      response.status === 410
    ) {
      invalidTokens.push(request.pushToken);
    }
  }

  return {
    configured: true,
    attempted: requests.length,
    sent,
    failed,
    invalidTokens,
  };
}

function loadAPNsConfig(): APNsConfig | null {
  const teamId = Deno.env.get("APNS_TEAM_ID")?.trim() ?? "";
  const keyId = Deno.env.get("APNS_KEY_ID")?.trim() ?? "";
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY_P8")?.trim() ?? "";
  const bundleId = Deno.env.get("APNS_BUNDLE_ID")?.trim() ?? "";

  if (!teamId || !keyId || !privateKeyPem || !bundleId) {
    return null;
  }

  return {
    teamId,
    keyId,
    privateKeyPem,
    bundleId,
  };
}

async function createBearerToken(config: APNsConfig): Promise<string> {
  const header = {
    alg: "ES256",
    kid: config.keyId,
  };
  const payload = {
    iss: config.teamId,
    iat: Math.floor(Date.now() / 1_000),
  };

  const signingInput = `${base64urlEncode(JSON.stringify(header))}.${
    base64urlEncode(JSON.stringify(payload))
  }`;
  const key = await importPrivateKey(config.privateKeyPem);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64urlEncode(signature)}`;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const normalized = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const binary = Uint8Array.from(
    atob(normalized),
    (char) => char.charCodeAt(0),
  );
  return await crypto.subtle.importKey(
    "pkcs8",
    binary,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function base64urlEncode(value: string | ArrayBuffer): string {
  const bytes = typeof value === "string"
    ? new TextEncoder().encode(value)
    : new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll(
    "=",
    "",
  );
}
