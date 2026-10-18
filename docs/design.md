# orin-web design

orin-web is a library for HTTP applications in Orin. It follows the conventions of the standard library (ADR-0048: names,
`Result` errors, grants first) and keeps three layers apart so that most of it runs where sockets do not exist.

```
              main(host)                       a test                    a wasm32-orbit host
                  |                               |                              |
   withNet(host, net => serve(net, app, ..))    TestClient               yourAdapter(request)
                  |                               |                              |
                  +-------------------------------+------------------------------+
                                                  |
                                   Router.handle(Request): Response          <- pure
                                                  |
                       middleware -> dispatch (patterns) -> Handler -> Result<Response, WebError>
```

| Layer | Files | Needs |
|---|---|---|
| Values: `Request`, `Response`, `WebError`, `SseEvent`, JSON builders | `request.or response.or error.or sse.or jsonbuild.or` | `std:http` (types only), `std:url`, `std:json`, `std:bytes` |
| Application: `Router`, middleware, assets, `TestClient` | `router.or middleware.or assets.or testing.or` | nothing beyond the values; **no grant** |
| Transport: `serve` | `server.or` | `std:net`, `std:task`, a `NetGrant` |

Only the transport layer has authority. Everything below it holds no grant: it cannot open a socket or read a file whatever it
is given. `orin effects` on `examples/edge` shows exactly that: the only effects that come from orin-web are the ambient
`Process.Exit` (a malformed route pattern stops the program at start-up) and `Unknown.FunctionValue` (handlers are function
values, which the analysis cannot follow); there is no `Net`, `Fs` or `Process.Spawn`. That is the capability model doing its job,
and it is why the application layer runs unchanged in tests and on `wasm32-orbit`.

## Decisions

### A request and a response are values

Orin has value semantics: `const b = a` copies, and nothing is shared. So `Request` and `Response` are classes with private
fields whose methods never mutate; `withHeader`, `withAttr`, `withParams`, `withStatus` return a changed copy (ADR-0048 4.1). A
middleware that adds a principal to a request cannot disturb the code that holds the original. `Router` is the one class with
mutating methods (`get`, `use`, `mount`, ...), as ADR-0048 4.1 allows: it is built with `let`, then only read.

orin-web has its own `Request` and `Response` instead of using the ones of `std:http` because those are wire messages with
strict invariants: an HTTP/1.1 request must carry exactly one `Host`, a response must have a consistent `Content-Length`, a
`204` must have no body. A handler should not have to satisfy framing rules, and a test should not have to invent a `Host`. The
server converts at the edge: it reads a `std:http` request into a `Request` (`Request.tryNew`), and writes a `Response` with
`std:http`'s serializer after setting `Content-Length` itself (a handler's own `Content-Length`, `Transfer-Encoding` and
`Connection` fields are dropped, so a handler cannot produce an ambiguous message).

`Headers` is `std:http`'s class, reused: it already validates names and values, so a header containing a line break cannot be
constructed, and response splitting is impossible by construction.

### A handler returns `Result<Response, WebError>`

ADR-0048 3 distinguishes a value that may be absent (`Option`), a failure the caller handles (`Result`) and a caller bug (trap).
A malformed body, a missing resource and a missing credential are the middle case, so they are `Err(WebError)`, and `?` makes
handlers read top to bottom:

```ts
const body = decodeBody(req, decodeNewTodo)?;
const todo = oneTodo(ask(state, OpAdd, 0, body.title))?;
```

`WebError` has a `kind` (`BadRequest`, `NotFound`, ..., `Other(code)`), a `detail` for the client, and `headers` that the error
handler copies into the response (`Allow` on 405, `WWW-Authenticate` on 401, CORS fields). The renderer is `webErrorMessage`
(ADR-0048 3.1.3); the status is `webErrorStatus`.

A trap is not caught. Orin has no exceptions and no unwinding; a trap ends the process. `recover` therefore means "turn a
returned `Err` into a response at this point of the chain". Handlers should return `Err` for everything that is not a bug.

### Routing

A pattern is split into segments at parse time; a request path is split and percent-decoded once, in `Request.tryNew`
(so `/files/a%2Fb` is the two-segment-looking but one-segment path `["files", "a/b"]`, and a malformed escape is a `400` before
any handler runs).

Segment kinds: literal, `:param` (one non-empty segment), and a final `*rest` (zero or more segments, joined with `/`). Empty
segments are ignored on both sides, so a trailing slash does not matter.

Selection, for a request `(method, path)`:

1. Collect the routes whose pattern matches the path.
2. Among those with the request's method, take the most specific. Specificity is compared segment by segment from the left: a
   literal beats a parameter, a parameter beats the end of the pattern, and the end of the pattern beats a wildcard. So for
   `/files/readme`, the route `/files/readme` beats `/files/:name`, which beats `/files/*rest`; for the path `/files`, the
   route `/files` beats `/files/*rest` (a wildcard matches zero segments too). Equal shapes: the earlier registration wins.
3. `HEAD` with no `HEAD` route uses the `GET` route (the server drops the body and keeps `Content-Length`).
4. Otherwise, if some route matched the path: `OPTIONS` gets `204` with `Allow`; any other method gets `405` with `Allow`.
5. Otherwise: the `onNotFound` handler, or a `404`.

The rules are by segment, never by string prefix, so `/api` does not match `/apix`. A malformed pattern (no leading `/`, a
wildcard that is not last, a repeated parameter name) is a programming error in the route table, not a failure of a request:
`route` prints the pattern and exits with status 101 at start-up (a trap).

**Groups.** `mount(prefix, sub)` copies the routes of `sub` under `prefix`, wrapping each handler in `sub`'s middleware at
mount time. The prefix may hold parameters (`/orgs/:org`). The not-found and error handlers of `sub` are not carried over: they
belong to the router that answers the request. A callback style (`app.group("/x", g => g.get(..))`) was left out on purpose:
parameters are immutable in Orin, so a callback could not add routes to `g`.

### Middleware

```ts
type Middleware = (req: Request, next: Handler) => Result<Response, WebError>;
```

The chain is built with closures, so a middleware is an ordinary function and a configured one is a function that returns a
function (`cors(config)`). `Router.use` adds to the router's chain, outermost first. Errors travel outward as `Err` values
and middleware that must decorate error responses (CORS, logging) handle both arms; CORS puts its fields in `WebError.headers`,
which the error handler copies into the rendered response, so a `404` still carries `Access-Control-Allow-Origin`.

Closures capture by value and cannot mutate what they capture. So a middleware has no counters or caches of its own; anything
stateful is an owner task reached through a channel (see below), exactly like application state.

`bearerAuth(verify)` leaves the choice of token store to the caller; `bearerToken(secret, name)` compares a shared secret
in constant time (it visits every byte of the longer string; this is best effort, not a proof of constant time).

### Streaming bodies and server-sent events

A response body is `FixedBody(Bytes)` or `StreamBody(() => Option<Bytes>)`. A pull source was chosen over a push sink because
a sink would have to carry the connection (`Stream`), which is a resource handle and cannot be captured by a closure or stored
in a class (E0452/E0483). A pull source closes over only values, usually a channel end, so the producer is an ordinary task and
the handler stays testable: `TestClient` returns the `Response` and `readEvents(res, n)` pulls events from it with no socket.

`Response.sse(next)` encodes `SseEvent`s (`event`, `id`, `retry`, multi-line `data`; CR and LF in `event` and `id` are
dropped so that a payload cannot forge fields). The server sends a stream with chunked coding (HTTP/1.0: up to close),
`Connection: close`, and ends the connection afterwards. It skips empty chunks, since an empty chunk would end the body.

Limits, stated plainly: the source may block for as long as it likes, a client that goes away is noticed at the next write, and a
stream holds a worker for its whole life. Size `workers` for the number of streams you expect.

### The server

`serve` follows `examples/http_server.or` of the Orin repository: the calling task only accepts; accepted connections are
moved into a bounded channel; a pool of `workers` tasks reads requests with the incremental `RequestParser`, calls
`Router.handle`, and writes the response. The accepting task runs in a nested scope so that `ServerHandle.stop` (the scope's
`CancelToken`) stops it without cancelling the workers: they finish what they hold.

Authority comes from the caller: `serve(net: NetGrant, ...)`. The listener is bound with `useListener(net, address, port, ..)`,
which narrows the grant to that one address and port; the program cannot open another socket. The default address is
`127.0.0.1`.

Bounds (all in `ServerConfig`, with `defaultServerConfig()`): `workers` (1..256) and `queue` (1..4096); `HttpLimits` for
the start line, header count and size, body size (1 MiB); deadlines for an idle connection, for one whole request, and for each
send; requests per connection. Malformed or oversize requests are answered (`400`, `408`, `413`, `414`, `431`, `505`) through
`Router.fail`, so the application's error handler renders them too, then the connection is shut down gracefully (FIN, bounded
drain) so the client sees the answer and not a reset.

The router is moved into each worker, which is a copy. A handler is a closure whose captures are values, so this is safe; and
it means there is no hidden shared state. State that must be shared lives in an **owner task** that handlers reach through a
`Sender` they captured (the pattern of `examples/projects/notes-service` and `examples/todo-api`). Orin gives every request to
the owner one at a time, which makes it atomic without locks.

Not done: TLS, HTTP/2, `Expect: 100-continue`, pipelined response ordering beyond sequential keep-alive, a `Date` header
(`serve` has no `ClockGrant`; one could be added as a parameter), compression, multipart bodies, cookies and sessions,
WebSockets. Reverse proxies cover most of these.

### Static content

`staticResponse(res)` and `assetsHandler(assets, index, cacheControl)` serve content that is part of the program. Serving a
directory is deliberately absent: it needs an `FsGrant`, a grant is a resource handle, and a handler (a closure) cannot capture one
(E0452). The program reads the files in `main`, where it holds the grant, and passes the bytes in as `Asset`s.

### Testing

`TestClient` calls `Router.handle`, the function the server calls, so there is no second code path. It applies default headers,
turns an invalid target into the same `400` the server would send, and strips the body of a `HEAD` response. `tests/server_test.or`
covers the transport with real loopback sockets: the server runs in a task of the test, the test is the client; it checks
keep-alive, `HEAD`, error statuses, malformed requests and a chunked event stream byte for byte.

### Composition with orin-ui

orin-web does not import orin-ui and never will. The seam is a string: `Response.html(status, markup)`. A handler renders an
orin-ui view with the HTML renderer of orin-ui and returns the markup; a live view's patch stream is a `Response.sse(next)` whose
source yields the patches (and `parseSseEvents` decodes them in a test). Both libraries therefore depend only on the standard
library and can evolve separately.

## WebAssembly (`wasm32-orbit`)

Checked against `orin 0.x` built from the repository at the time of writing.

| | Status |
|---|---|
| `Router`, `Request`, `Response`, middleware, JSON builders, assets, SSE encoding, `TestClient` | builds and runs (`examples/edge`, 290 KB module, run under `tools/wasm_run.mjs`) |
| `serve` and anything on `std:net` | **not available**: the build fails with E0523 naming `Stream.Write` and the call path from `main` |
| a package that imports orin-web but does not call `serve` | builds: unused code is pruned, so the `std:net` imports in `server.or` cost nothing |
| tasks and channels (`Response.sse` fed by a producer task, the owner-task pattern) | run one task at a time to completion; a handler that waits on a task which is itself waiting on the first (ping-pong over bounded channels) ends the module with `wasm32-orbit: deadlock` |
| `std:io` stdin | builds; stdin is at end of input today, so `examples/edge` answers its built-in requests |
| `wasm64-orbit` | `examples/edge` builds too; not run (needs Node 24 or Orbit) |

Orbit Cloud runs a module as a job, service or queue consumer and gives a consumer its message on stdin. A wasm deployment of
an orin-web app is therefore a *driver* around `Router.handle`: it decodes a request from the host, calls `handle`, and encodes
the response, which is what `examples/edge`'s `handleLine` does with a line protocol. An HTTP front end for Orbit services needs
a host-provided network or request capability that does not exist in the target yet.

## Module map

| File | Contents |
|---|---|
| `src/module.or` | the public face (explicit export list) |
| `src/error.or` | `WebError`, kinds, constructors, `webErrorStatus`, `webErrorMessage` |
| `src/request.or` | `Request`, `RequestParts`, `decodeBody` |
| `src/response.or` | `Response`, `Body` |
| `src/sse.or` | `SseEvent`, encoding and parsing |
| `src/jsonbuild.or` | constructors for `std:json` values |
| `src/router.or` | `Router`, `Handler`, `Middleware`, pattern parsing and matching, `chain`, `withMiddleware` |
| `src/middleware.or` | `logger recover bearerAuth bearerToken limitBody cors` |
| `src/assets.or` | `Asset`, `assetsHandler`, `staticResponse`, `contentTypeFor` |
| `src/testing.or` | `TestClient`, `testRequest`, `readEvents`, assertions |
| `src/server.or` | `serve`, `ServerConfig`, `ServerHandle` |

## Possible next steps

Cookies and sessions; `application/x-www-form-urlencoded` and multipart bodies; content negotiation (`Accept`); ETag and
conditional requests for assets; a typed-extractor layer on top of `decodeBody`; WebSocket upgrade; a `ClockGrant` parameter for
`Date` headers and access-log durations; a request-id middleware; an `OpenAPI` generator through an annotation processor
(`@Route` as in `examples/routes` of the Orin repository could register handlers at compile time).
