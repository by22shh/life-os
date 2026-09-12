import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

Deno.test("lab marker reads exclude sync tombstones while normal table pulls retain them", async () => {
  const handler = await captureEdgeHandler("../api/labs/index.ts");

  await withMockedEdgeRuntime({
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/medical_scans") return jsonResponse([]);
        if (url.pathname === "/rest/v1/health_measurements") {
          assertEquals(url.searchParams.get("deleted_at"), "is.null");
          return jsonResponse([]);
        }
        return undefined;
      },
    ],
  }, async (calls) => {
    const response = await handler(
      new Request(
        "http://localhost/functions/v1/api-labs/markers?marker_id=ferritin",
        { headers: { Authorization: "Bearer valid-token" } },
      ),
    );

    assertEquals(response.status, 200);
    assertEquals(await response.json(), { marker_id: "ferritin", history: [] });
    assertEquals(
      calls.fetches.some((call) =>
        call.url.pathname === "/rest/v1/health_measurements" &&
        call.url.searchParams.get("deleted_at") === "is.null"
      ),
      true,
    );
  });
});
