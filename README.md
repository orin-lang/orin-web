# orin-web

A web framework library for [Orin](https://github.com/orin-lang/orin-lang): routing, typed requests and responses, middleware,
server-sent events, a socket-free testing client, and an HTTP/1.1 server, on top of `std:http`, `std:net` and `std:json`.

```ts
import { Host, withNet } from "std:host";
import { NetGrant } from "std:net";
import { Router, Request, Response, WebError, ServerConfig, defaultServerConfig, serve, jsonObject, jsonMember, jsonString } from "orin-web";

function main(host: Host): void {
  let app = new Router();
  app.get("/hello/:name", (req: Request): Result<Response, WebError> => {
    const who = req.param("name").unwrapOr("world");
    return Response.json(200, jsonObject([jsonMember("hello", jsonString(who))]));
  });
  withNet(host, net => {
    serve(net, app, ServerConfig { ...defaultServerConfig(), port: 8080 }, h => {});
  });
}
```

```
$ curl localhost:8080/hello/ada
{"hello":"ada"}
```

Status: version 0.1, pre-release, like the language it is written in. The server and `std:net` are unstable until the std I/O freeze.

## What is in it

| Area | API |
|---|---|
| Routing | `Router` with `get post put patch delete head options any route`; patterns `/users/:id` and `/files/*rest`; most-specific-wins; automatic `405` + `Allow`, `HEAD` from `GET`, `OPTIONS`; route groups with `mount(prefix, sub)`; `onNotFound`, `onError` |
| Request | `Request`: `method path segments query queryAll queryInt header mediaType bearerToken body bodyText bodyJson param paramInt attr`; `decodeBody(req, decoder)` |
| Response | `Response.text html json bytes empty redirect stream sse`; `withStatus withHeader withAddedHeader withContentType withBody` |
| Errors | `WebError` with a kind and a status (`badRequest unauthorized forbidden notFound unprocessable internalError statusError`); handlers return `Result<Response, WebError>` so they can use `?` |
| Middleware | `logger recover bearerAuth bearerToken cors limitBody`, `withMiddleware` for one route, `chain` |
| Static | `staticResponse`, `assetsHandler`, `textAsset`, `contentTypeFor` |
| Events | `Response.sse(next)`, `SseEvent`, `sseData`, `sseEvent`, `sseEncode`, `parseSseEvents` |
| JSON | `jsonObject jsonMember jsonArray jsonString jsonInt jsonBool jsonNull` for building `std:json` values |
| Testing | `TestClient` (`get post put patch delete head options send postJson withHeader`), `testRequest`, `readEvents`, `assertStatus assertBody assertHeader assertNoHeader` |
| Server | `serve(net, app, config, ready)`, `ServerConfig`, `defaultServerConfig`, `ServerHandle` |

## Using it

orin-web is an Orin package. Add it as a dependency (it is not on a registry yet):

```sh
orin add --path ../orin-web                                          # a checkout next to your project
orin add --git https://github.com/orin-lang/orin-web --rev COMMIT       # or a pinned commit
```

```ts
import { Router, Request, Response, WebError } from "orin-web";
```

Everything the package exports comes from `src/module.or`; the files behind it are private.

### Handlers and errors

A handler is `(req: Request) => Result<Response, WebError>`. Failures that are the client's business are values, not traps, so
the usual `?` works:

```ts
function createUser(req: Request): Result<Response, WebError> {
  const body = decodeBody(req, decodeNewUser)?;        // 400 if not JSON, 422 if the wrong shape
  const id = req.paramInt("org")?;                     // 404 if the id is not a number
  if (body.name.length == 0) {
    return Err(unprocessable("name must not be empty"));
  }
  return Response.json(201, userJson(body));
}
```

A `WebError` leaving a handler is rendered by the router's error handler (by default JSON `{"error": "...", "status": 422}`);
replace it with `app.onError((req, e) => ...)`. A *trap* (index out of range, `unwrap` of `None`, a failed assertion) is not an
error value in Orin: it ends the process. Return `Err` for every failure that is not a bug.

### Routing

```ts
let api = new Router();
api.use(bearerToken("secret", "admin"));         // middleware of the group
api.get("/todos", listTodos);
api.get("/todos/stream", streamTodos);           // a literal beats ...
api.delete("/todos/:id", removeTodo);            // ... a parameter

let app = new Router();
app.use(logger((line: string) => console.error(line)));
app.use(cors(defaultCors()));
app.get("/health", health);
app.mount("/api", api);                          // GET /api/todos, DELETE /api/todos/7, ...
```

Patterns are matched by segment. `:name` captures one segment, a final `*name` captures the rest (`/files/*path` matches
`/files/a/b.txt` with `path = "a/b.txt"`). Captures are percent-decoded; `%2F` stays inside one segment. Trailing slashes are
ignored. The most specific match wins (literal, then parameter, then wildcard); the first registration breaks ties. A path that
exists only for other methods gets `405` with an `Allow` field. [docs/design.md](docs/design.md) has the full rules.

`Router` is a value: build it with the mutating methods in `main` (or in a function that returns it), then only read it.

### Middleware

```ts
type Middleware = (req: Request, next: Handler) => Result<Response, WebError>;
```

A middleware may answer without calling `next`, pass a changed copy of the request (`req.withAttr("principal", who)`), and change
the response or the error coming back. The first one added with `use` is the outermost. A group's middleware wraps only the
group's routes; `withMiddleware(mw, handler)` wraps one route.

| Middleware | Does |
|---|---|
| `logger(sink)` | one line `GET /path -> 200` per request through your `sink` |
| `recover(render)` | turns an `Err` from inside into the response `render` makes |
| `bearerAuth(verify)` / `bearerToken(secret, name)` | `401` + `WWW-Authenticate` unless a valid bearer token; sets the `principal` attribute |
| `cors(config)` | `Access-Control-*` fields, preflight answers; `CorsConfig { ...defaultCors(), origins: [...] }` |
| `limitBody(n)` | `413` above `n` body bytes |

### Responses

```ts
Response.text(200, "ok")
Response.html(200, markup)                       // markup is a string: the output of any renderer
Response.json(201, value)?                       // Result: the writer can refuse (limits, invalid UTF-8)
Response.redirect(303, "/login")?
Response.empty(204).withHeader("Cache-Control", "no-store")
```

Headers are validated by `std:http`'s `Headers`: a value with a CR or LF cannot be set, so a response can not be split.
`withHeader` traps on an invalid name or value (use it for values the program wrote); `tryWithHeader` returns a `Result` (use it
for values that came from a request).

### Server-sent events

```ts
app.get("/events", (req: Request): Result<Response, WebError> => {
  const events = channel<SseEvent>(64);          // a producer task sends here
  const rx = events.rx;
  return Ok(Response.sse(() => rx.recv()));      // None ends the stream
});
```

The body of a streamed response is a *pull source*, `() => Option<Bytes>` (`Response.sse` adapts events). The server calls it
until it answers `None`, so it may block, typically on a channel receive. A stream is sent with chunked coding and ends its
connection; it occupies one worker for as long as it runs. [`examples/todo-api`](examples/todo-api) has a complete use.

### Testing without a socket

`TestClient` drives `Router.handle`, the code path a server uses, so a test sees the same middleware, statuses and error bodies:

```ts
@Test
function creatingATodo(): void {
  const client = new TestClient(buildApp()).withHeader("Authorization", "Bearer secret");
  const res = client.post("/api/todos", "{\"title\":\"milk\"}");
  assertStatus(res, 201);
  assertHeader(res, "Location", "/api/todos/1");
}
```

`readEvents(res, n)` reads up to `n` events from a streamed response. For tests over real sockets see `tests/server_test.or`.

### Serving

```ts
function main(host: Host): void {
  withNet(host, net => {                          // the authority comes from main(host)
    const r = serve(net, app, ServerConfig { ...defaultServerConfig(), address: "127.0.0.1", port: 8080 },
      (h: ServerHandle) => console.error("listening on port " + h.port.toString()));
  });
}
```

`serve` takes a `NetGrant`, narrows it to the one address and port with `std:net`'s `useListener`, and can open no other socket.
It runs a bounded pool of worker tasks (`workers`, `queue`), enforces `HttpLimits` and per-request deadlines, and returns when
`maxConnections` were served or `ServerHandle.stop.cancel()` is called. State shared between requests lives in an owner task that
handlers reach through a channel, as in [`examples/todo-api`](examples/todo-api): Orin tasks share no mutable state.

### With orin-ui

orin-web does not depend on orin-ui. A response takes a string, so a handler that renders a view to HTML returns it as is:

```ts
app.get("/", (req: Request): Result<Response, WebError> => Ok(Response.html(200, renderPage(view()))));
```

where `renderPage` is whatever turns your orin-ui view into markup. The same goes for orin-ui's patch stream: an event stream is a
`Response.sse(next)` whose source yields the patches.

## WebAssembly (`wasm32-orbit`)

The router, requests, responses, middleware, JSON, SSE encoding, assets and `TestClient` are pure Orin and build and run on
`wasm32-orbit` and `wasm64-orbit`. `std:net` does not exist there (the build fails with E0523), so **`serve` cannot be used**;
`examples/edge` is an app that is driven by a host instead: it builds with `orin build --target=wasm32-orbit` and runs under the
Orbit host. A program that imports orin-web but never calls `serve` builds for wasm (unused code is pruned).
Streamed responses and anything that blocks on a channel for another task are limited by the one-task-at-a-time model of the
target ([docs/wasm.md](https://github.com/orin-lang/orin-lang/blob/main/docs/wasm.md)). Details: [docs/design.md](docs/design.md).

## Examples

| | |
|---|---|
| [`examples/todo-api`](examples/todo-api) | a JSON service: bearer-protected group, CORS, logging, an owner task for state, an event stream, assets. Native. |
| [`examples/edge`](examples/edge) | the same building blocks without a socket, driven line by line; builds for `wasm32-orbit`. |

## Develop

```sh
orin test                  # the library's tests: unit tests and loopback-socket tests
tools/ci.sh                # tests, both examples' tests, the wasm32-orbit build of examples/edge
```

Layout: `src/module.or` (the public face), `src/*.or` (one concern per file), `tests/*_test.or`, `docs/design.md`,
`docs/compiler-issues.md`.

## License

MIT, see [LICENSE](LICENSE).
