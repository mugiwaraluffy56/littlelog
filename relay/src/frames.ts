// The wire contract between the relay and the littlelog app on a Mac. Everything here is pure
// (no Cloudflare APIs) so `contract/check.mjs` can run it directly against the shared fixtures
// in `contract/frames.json`, which the app's tests (Tests/RelayContractTests.swift) also read.

const DEVICE_ID_PATTERN = "[0-9a-f]{32}";
export const DEVICE_ID = new RegExp(`^${DEVICE_ID_PATTERN}$`);

export const FORWARDED_REQUEST_HEADERS = ["accept", "authorization", "content-type", "mcp-protocol-version", "user-agent"];
export const RETURNED_RESPONSE_HEADERS = ["allow", "cache-control", "content-type", "location", "www-authenticate"];

export interface RequestFrame {
  type: "request";
  id: string;
  method: string;
  path: string;
  query: string;
  headers: Record<string, string>;
  body: string;
}

export interface ResponseFrame {
  type: "response";
  id: string;
  status: number;
  headers: Record<string, string>;
  body: string;
}

export interface DeviceRoute {
  device: string;
  path: string;
}

export interface DecodedResponse {
  id: string;
  status: number;
  headers: [string, string][];
  body: Uint8Array;
}

/// `/d/<device>/rest` and RFC 8414/9728 path-inserted discovery, `/.well-known/<name>/d/<device>/rest`.
export function deviceRoute(pathname: string): DeviceRoute | null {
  const direct = pathname.match(new RegExp(`^/d/(${DEVICE_ID_PATTERN})(/.*)?$`));
  if (direct?.[1]) return { device: direct[1], path: direct[2] ?? "/" };
  const discovery = pathname.match(new RegExp(`^/\\.well-known/([a-z-]+)/d/(${DEVICE_ID_PATTERN})(/.*)?$`));
  if (discovery?.[1] && discovery[2]) {
    return { device: discovery[2], path: `/.well-known/${discovery[1]}${discovery[3] ?? ""}` };
  }
  return null;
}

/// What the Mac receives for one HTTP request that reached the relay.
export function buildRequestFrame(input: {
  id: string;
  method: string;
  path: string;
  query: string;
  host: string;
  prefix: string;
  headers: { get(name: string): string | null };
  body: Uint8Array;
}): RequestFrame {
  const headers: Record<string, string> = {
    host: input.host,
    "x-forwarded-proto": "https",
    "x-forwarded-prefix": input.prefix,
  };
  for (const name of FORWARDED_REQUEST_HEADERS) {
    const value = input.headers.get(name);
    if (value !== null) headers[name] = value;
  }
  return {
    type: "request",
    id: input.id,
    method: input.method,
    path: input.path,
    query: input.query,
    headers,
    body: toBase64(input.body),
  };
}

/// Reads the Mac's answer, keeping only headers that are safe to return to ChatGPT.
export function decodeResponseFrame(text: string): DecodedResponse | null {
  let frame: ResponseFrame;
  try {
    frame = JSON.parse(text) as ResponseFrame;
  } catch {
    return null;
  }
  if (frame.type !== "response" || typeof frame.id !== "string") return null;
  const headers: [string, string][] = [];
  for (const [name, value] of Object.entries(frame.headers ?? {})) {
    if (RETURNED_RESPONSE_HEADERS.includes(name.toLowerCase())) headers.push([name, String(value)]);
  }
  const status = Number.isInteger(frame.status) && frame.status >= 200 && frame.status <= 599 ? frame.status : 502;
  try {
    return { id: frame.id, status, headers, body: fromBase64(frame.body ?? "") };
  } catch {
    return null;
  }
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
}

export function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}
