// littlelog relay: gives the littlelog app on a Mac a public HTTPS address for ChatGPT.
//
// The Mac keeps one WebSocket open to its own Durable Object. Requests that arrive at
// https://<relay>/d/<device>/... are passed to the Mac over that socket and its answer is
// returned unchanged. The relay stores nothing but a hash of each device's secret; sign-in
// (OAuth) and every tool call are handled by the app on the Mac.

import { DurableObject } from "cloudflare:workers";

export interface Env {
  DEVICES: DurableObjectNamespace<DeviceRelay>;
}

const DEVICE_ID = /^[0-9a-f]{32}$/;
const MAX_BODY_BYTES = 1024 * 1024;
// Sign-in waits up to 90 s for the person at the Mac to click Allow.
const REQUEST_TIMEOUT_MS = 100_000;
const FORWARDED_REQUEST_HEADERS = ["accept", "authorization", "content-type", "mcp-protocol-version", "user-agent"];
const RETURNED_RESPONSE_HEADERS = ["allow", "cache-control", "content-type", "location", "www-authenticate"];

interface RequestFrame {
  type: "request";
  id: string;
  method: string;
  path: string;
  query: string;
  headers: Record<string, string>;
  body: string;
}

interface ResponseFrame {
  type: "response";
  id: string;
  status: number;
  headers: Record<string, string>;
  body: string;
}

interface DeviceRoute {
  device: string;
  path: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/connect") {
      const device = request.headers.get("x-littlelog-device") ?? "";
      if (!DEVICE_ID.test(device)) return text("Unknown device", 400);
      return env.DEVICES.get(env.DEVICES.idFromName(device)).fetch(request);
    }

    const route = deviceRoute(url.pathname);
    if (!route) {
      return url.pathname === "/"
        ? text("littlelog relay. Copy your ChatGPT link from the littlelog menu bar icon.", 200)
        : text("Not found", 404);
    }
    const forwarded = new Request(request);
    forwarded.headers.set("x-relay-path", route.path);
    forwarded.headers.set("x-relay-prefix", `/d/${route.device}`);
    return env.DEVICES.get(env.DEVICES.idFromName(route.device)).fetch(forwarded);
  },
} satisfies ExportedHandler<Env>;

/// `/d/<device>/rest` and RFC 8414/9728 path-inserted discovery, `/.well-known/<name>/d/<device>/rest`.
function deviceRoute(pathname: string): DeviceRoute | null {
  const direct = pathname.match(/^\/d\/([0-9a-f]{32})(\/.*)?$/);
  if (direct?.[1]) return { device: direct[1], path: direct[2] ?? "/" };
  const discovery = pathname.match(/^\/\.well-known\/([a-z-]+)\/d\/([0-9a-f]{32})(\/.*)?$/);
  if (discovery?.[1] && discovery[2]) {
    return { device: discovery[2], path: `/.well-known/${discovery[1]}${discovery[3] ?? ""}` };
  }
  return null;
}

export class DeviceRelay extends DurableObject<Env> {
  private readonly pending = new Map<string, (response: Response) => void>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keep-alive pings are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() === "websocket") {
      return this.attachMac(request);
    }
    return this.forward(request);
  }

  /// The first connection claims the device id; later ones must present the same secret.
  private async attachMac(request: Request): Promise<Response> {
    const secret = bearer(request.headers.get("authorization"));
    if (!secret || secret.length < 32) return text("Missing device secret", 401);
    const presented = await sha256(secret);
    const stored = await this.ctx.storage.get<string>("secretHash");
    if (stored === undefined) {
      await this.ctx.storage.put("secretHash", presented);
    } else if (!equalStrings(stored, presented)) {
      return text("Wrong device secret", 403);
    }

    for (const previous of this.ctx.getWebSockets()) {
      previous.close(1012, "Replaced by a newer connection");
    }
    const [client, server] = Object.values(new WebSocketPair()) as [WebSocket, WebSocket];
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async forward(request: Request): Promise<Response> {
    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_BODY_BYTES) return text("Request body too large", 413);

    const socket = this.ctx.getWebSockets()[0];
    if (!socket) return offline(request.method, request.headers.get("x-relay-path"), body);

    const url = new URL(request.url);
    const headers: Record<string, string> = {
      host: url.host,
      "x-forwarded-proto": "https",
      "x-forwarded-prefix": request.headers.get("x-relay-prefix") ?? "",
    };
    for (const name of FORWARDED_REQUEST_HEADERS) {
      const value = request.headers.get(name);
      if (value !== null) headers[name] = value;
    }
    const frame: RequestFrame = {
      type: "request",
      id: crypto.randomUUID(),
      method: request.method,
      path: request.headers.get("x-relay-path") ?? "/",
      query: url.search.slice(1),
      headers,
      body: toBase64(new Uint8Array(body)),
    };

    return new Promise<Response>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(frame.id);
        resolve(text("littlelog on your Mac didn't answer in time", 504));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(frame.id, (response) => {
        clearTimeout(timer);
        resolve(response);
      });
      try {
        socket.send(JSON.stringify(frame));
      } catch {
        this.pending.delete(frame.id);
        clearTimeout(timer);
        resolve(offline(request.method, frame.path, body));
      }
    });
  }

  async webSocketMessage(_socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    let frame: ResponseFrame;
    try {
      frame = JSON.parse(message) as ResponseFrame;
    } catch {
      return;
    }
    if (frame.type !== "response" || typeof frame.id !== "string") return;
    const resolve = this.pending.get(frame.id);
    if (!resolve) return;
    this.pending.delete(frame.id);

    const headers = new Headers();
    for (const [name, value] of Object.entries(frame.headers ?? {})) {
      if (RETURNED_RESPONSE_HEADERS.includes(name.toLowerCase())) headers.set(name, String(value));
    }
    const status = Number.isInteger(frame.status) && frame.status >= 200 && frame.status <= 599 ? frame.status : 502;
    const bytes = fromBase64(frame.body ?? "");
    const noBody = status === 204 || status === 205 || status === 304;
    resolve(new Response(noBody ? null : bytes, { status, headers }));
  }

  async webSocketClose(socket: WebSocket, code: number, reason: string): Promise<void> {
    socket.close(code, reason);
    this.failPendingIfDisconnected();
  }

  async webSocketError(): Promise<void> {
    this.failPendingIfDisconnected();
  }

  private failPendingIfDisconnected(): void {
    if (this.ctx.getWebSockets().length > 0) return;
    for (const resolve of this.pending.values()) {
      resolve(text("littlelog on your Mac disconnected", 502));
    }
    this.pending.clear();
  }
}

/// While the Mac is away, tool calls get a readable answer instead of a transport error.
function offline(method: string, path: string | null, body: ArrayBuffer): Response {
  const message = "littlelog is offline: the Mac is asleep, or littlelog isn't running with ChatGPT access turned on.";
  if (method === "POST" && path === "/mcp") {
    try {
      const rpc = JSON.parse(new TextDecoder().decode(body)) as { id?: unknown; method?: unknown };
      if (rpc.id !== undefined && rpc.method === "tools/call") {
        return Response.json({
          jsonrpc: "2.0",
          id: rpc.id,
          result: { content: [{ type: "text", text: message }], isError: true },
        });
      }
    } catch {
      // Not JSON-RPC; fall through to the plain response.
    }
  }
  return text(message, 503);
}

function text(message: string, status: number): Response {
  return new Response(message, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

function bearer(header: string | null): string | null {
  if (!header?.toLowerCase().startsWith("bearer ")) return null;
  const token = header.slice("bearer ".length).trim();
  return token.length > 0 ? token : null;
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function equalStrings(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}
