import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";
import { dispatchAPNsNotifications } from "../_shared/apns.ts";

const TEST_PRIVATE_KEY_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgEZ4EdAofaTvllXHM
rXV1oXLHePAl/fvvW56/8Byf4BmhRANCAAT2XmyoVEwxdrwIe93r/aEXa2DRG7ex
JYjUyyxHnqHxeRLqgQecEnMj145Rh7TaLH1c3rxBKwXkH5MU0zZCGdmB
-----END PRIVATE KEY-----`;

async function withEnv(
  entries: Record<string, string | undefined>,
  fn: () => Promise<void>,
) {
  const previous = new Map<string, string | undefined>();
  for (const key of Object.keys(entries)) {
    previous.set(key, Deno.env.get(key));
    const value = entries[key];
    if (value === undefined) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, value);
    }
  }

  try {
    await fn();
  } finally {
    for (const [key, value] of previous.entries()) {
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
  }
}

Deno.test("APNs dispatch reports unconfigured state when credentials are missing", async () => {
  await withEnv({
    APNS_TEAM_ID: undefined,
    APNS_KEY_ID: undefined,
    APNS_PRIVATE_KEY_P8: undefined,
    APNS_BUNDLE_ID: undefined,
  }, async () => {
    const summary = await dispatchAPNsNotifications([{
      pushToken: "token",
      environment: "development",
      title: "Title",
      body: "Body",
    }]);

    assertEquals(summary, {
      configured: false,
      attempted: 1,
      sent: 0,
      failed: 0,
      invalidTokens: [],
    });
  });
});

Deno.test("APNs dispatch sends payloads, honors priority, and classifies invalid tokens", async () => {
  await withEnv({
    APNS_TEAM_ID: "TEAM123",
    APNS_KEY_ID: "KEY123",
    APNS_PRIVATE_KEY_P8: TEST_PRIVATE_KEY_P8,
    APNS_BUNDLE_ID: "com.lifeos.app",
  }, async () => {
    const previousFetch = globalThis.fetch;
    const requests: Request[] = [];

    globalThis.fetch = ((
      input: Request | URL | string,
      init?: RequestInit,
    ) => {
      const request = input instanceof Request
        ? input
        : new Request(String(input), init);
      requests.push(request);

      if (request.url.includes("/token-good")) {
        return Promise.resolve(new Response(null, { status: 200 }));
      }
      if (request.url.includes("/token-gone")) {
        return Promise.resolve(
          new Response(JSON.stringify({ reason: "Unregistered" }), {
            status: 410,
            headers: { "Content-Type": "application/json" },
          }),
        );
      }
      return Promise.resolve(new Response("gateway timeout", { status: 504 }));
    }) as typeof fetch;

    try {
      const summary = await dispatchAPNsNotifications([
        {
          pushToken: "token-good",
          environment: "development",
          title: "Morning brief",
          body: "Ready for the day",
          deepLink: "lifeos://home",
        },
        {
          pushToken: "token-gone",
          environment: "production",
          title: "Recovery alert",
          body: "Time to slow down",
          interruptionLevel: "time-sensitive",
        },
        {
          pushToken: "token-unknown",
          environment: "production",
          title: "Nudge",
          body: "Take a walk",
          interruptionLevel: "passive",
        },
      ]);

      assertEquals(summary, {
        configured: true,
        attempted: 3,
        sent: 1,
        failed: 2,
        invalidTokens: ["token-gone"],
      });

      assertEquals(requests.length, 3);
      assertEquals(
        requests[0].url,
        "https://api.sandbox.push.apple.com/3/device/token-good",
      );
      assertEquals(
        requests[1].url,
        "https://api.push.apple.com/3/device/token-gone",
      );

      const successPayload = await requests[0].clone().json();
      assertEquals(successPayload, {
        aps: {
          alert: {
            title: "Morning brief",
            body: "Ready for the day",
          },
          sound: "default",
          "interruption-level": "active",
        },
        deep_link: "lifeos://home",
      });
      assertEquals(
        requests[0].headers.get("apns-topic"),
        "com.lifeos.app",
      );
      assertEquals(
        requests[0].headers.get("apns-priority"),
        "5",
      );
      assertEquals(
        requests[1].headers.get("apns-priority"),
        "10",
      );
      assertEquals(
        requests[2].headers.get("authorization")?.startsWith("bearer "),
        true,
      );
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
});

Deno.test("APNs dispatch short-circuits empty request list when configured", async () => {
  await withEnv({
    APNS_TEAM_ID: "TEAM123",
    APNS_KEY_ID: "KEY123",
    APNS_PRIVATE_KEY_P8:
      "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
    APNS_BUNDLE_ID: "com.lifeos.app",
  }, async () => {
    const summary = await dispatchAPNsNotifications([]);

    assertEquals(summary, {
      configured: true,
      attempted: 0,
      sent: 0,
      failed: 0,
      invalidTokens: [],
    });
  });
});
