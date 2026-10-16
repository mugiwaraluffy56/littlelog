// Checks the relay's wire code against the fixtures the Swift tests also use.
// Run with `npm run check:contract` (Node strips the TypeScript types itself).
import { deepStrictEqual } from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildRequestFrame, decodeResponseFrame, deviceRoute } from "../src/frames.ts";

const fixtures = JSON.parse(readFileSync(new URL("./frames.json", import.meta.url), "utf8"));

// Request: what the relay sends the Mac.
const { input, frame } = fixtures.request;
deepStrictEqual(
  buildRequestFrame({ ...input, headers: new Headers(input.headers), body: new TextEncoder().encode(input.body) }),
  frame,
);

// Response: the Mac's frame is decoded, and headers outside the allow-list are dropped.
const decoded = decodeResponseFrame(JSON.stringify(fixtures.response.frame));
deepStrictEqual(decoded && { ...decoded, body: new TextDecoder().decode(decoded.body) }, {
  id: fixtures.response.mac.id,
  status: fixtures.response.mac.status,
  headers: Object.entries(fixtures.response.mac.headers),
  body: fixtures.response.mac.body,
});
const withSecret = { ...fixtures.response.frame, headers: { ...fixtures.response.frame.headers, "X-Secret": "nope", "Set-Cookie": "a=b" } };
deepStrictEqual(decodeResponseFrame(JSON.stringify(withSecret))?.headers, Object.entries(fixtures.response.mac.headers));
deepStrictEqual(decodeResponseFrame(JSON.stringify({ ...fixtures.response.frame, status: 99 }))?.status, 502);
deepStrictEqual(decodeResponseFrame("not json"), null);
deepStrictEqual(decodeResponseFrame(JSON.stringify({ type: "request", id: "x" })), null);

// Routes.
for (const { path, device, routed } of fixtures.routes) {
  deepStrictEqual(deviceRoute(path), device === null ? null : { device, path: routed }, path);
}

console.log("relay contract ok");
