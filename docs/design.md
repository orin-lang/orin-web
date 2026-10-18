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

## The annotation model

The functional API above is the engine. The annotation layer is a **front end that generates calls into it**: nothing at run time knows
about annotations. `@Controller`, `@Service` and `@Application` are user annotations (ADR-0046) with pure processors in orin-web
(`src/controller.or`, `src/service.or`, `src/application.or`); the compiler runs each over the modules that use it and compiles what
they return into a companion module next to the source module (`beans.or` gets `beans.gen`, which `orin expand` prints).

```
 beans.or  --@Service-->   Services, ServicesDeps, buildServices
           --@Controller-> ControllerDeps, registerControllers, registerControllersFrom, handler functions, JSON codecs
           --@Application> buildApp
                                |
                     calls into Router, Middlewares, bind*, respond*, dec*/enc*   (src/wiring.or, bind.or, respond.or, codec.or)
```

The runtime helpers are ordinary, tested functions (`bindPathInt`, `respondResult`, `decodeBodyWith`, `wireController`, `useAll`...).
The generated code is deliberately thin: it names which helper reads which parameter, which encoder writes which type, and in which
order to create things. A reader can check it against the annotations by reading `orin expand`.

### What each processor reads and checks

**`@Service`** reads the services of a module and the parameters of their `create` factory. A dependency is resolved *by type*: a
service is known under its class name or the interface it is registered as (`@Service("TodoRepository")`). A dependency that no
service of the module provides becomes a field of `ServicesDeps`, named like the parameter, which the application supplies (a channel
to an owner task, a configuration value, a service of another module). The processor orders the services topologically and reports,
as compile errors at the class: a missing `create`, a `create` that does not return the class, two services for one type, a
dependency on a class of this module that is not a service, two services declaring the same external name with different types, and a
cycle, spelled out (`dependency cycle among services: A -> B -> C -> A`).

**`@Controller`** reads the methods that carry a route annotation (`@Get`, `@Post`, `@Put`, `@Patch`, `@Delete`) and decides for
every parameter where its value comes from:

1. a parameter of type `Request` receives the request;
2. a parameter listed in `@Path`, `@Query`, `@Header` is read from there (`name` or `name=wire name`, comma-separated);
3. the parameter named by `@Body("p")`, or the only still-unbound parameter for a bare `@Body`, is the decoded JSON body;
4. a parameter named like a path parameter of the route is that path parameter;
5. anything else is a compile error at the method ("parameter `limit` of list is not bound").

It also checks that `@Path` names a parameter of the pattern, that a method has one route, that results are `Response`, a value,
`Option`, `void` or a `Result<_, WebError>` of those, and that every type that has to be read from or written as JSON is supported
(`string`, `int`, `bool`, `JsonValue`, arrays, `Option`, records of those, unions of tags, aliases of those, and records may
contain themselves). The error names the type and points at the method.

The mapping of results: `Response` as is; `T` written as JSON with status 200 (`@Status` to change it); `Option<T>` is a 404 for `None`;
`void` and `Result<void, _>` are 204; `Result<T, WebError>` passes the error on, which the router renders. A bad path or query value
is a 400 that names the parameter, a body that is not JSON is a 400, and a body of the wrong shape is a 422 whose text names the path
(`/tags/1: wrong type: expected string, found number`), never the value.

**`@Application`** generates `buildApp(deps: ServicesDeps, mws: Middlewares): Router` for a module that holds both services and
controllers: it builds the services, passes them to `registerControllersFrom`, and returns the router.

### Dependency injection without a container at run time

The "container" is the straight-line code in `buildServices`: each service is created once, after the services it needs, and handed
down by plain function arguments. The services live in a record (`Services`) so that a controller registration can pick them by
field. There is no lookup by name or type at run time, no reflection, and no global state. Singleton semantics are Orin's: a service
is a value, so what a controller holds is a copy of it. A service that must share state with others holds a channel end to an owner task
(`examples/todo-api`: `OwnerTodoRepository` holds a `Sender<Command>`), the same pattern as in the functional API.

### The generated code for one example

`tests/annotated` and `examples/todo-api` use this in full; this is a small module and what `orin expand` prints for it (hygienic
names `__gN_...` are the compiler's; imports are abbreviated):

```ts
// beans.or
@Service
export class TodoService {
  constructor(private prefix: string) {}
  static create(prefix: string): TodoService { return new TodoService(prefix); }
  find(id: int): Result<Todo, WebError> { .. }
}

@Controller("/todos")
export class TodoController {
  constructor(private todos: TodoService) {}
  static create(todos: TodoService): TodoController { return new TodoController(todos); }

  @Get("/:id")
  find(id: int): Result<Todo, WebError> { return this.todos.find(id); }
}

@Application
export type App = {};
```

```ts
// companion module ./beans.gen

import { Router, Middlewares, newRouter, Request, Response, WebError, addRoute, bindPathInt, jsonInt, jsonMember, jsonObject,
         jsonString, mountGroup, respondResult, wireController } from "orin-web";
import { JsonValue } from "std:json";
import { Todo } from "./model";

// generated for `@Application` on `App`
export function buildApp(deps: ServicesDeps, mws: Middlewares): Router {
  const services = buildServices(deps);
  return registerControllersFrom(newRouter(), services, mws);
}

// generated for `@Controller` on `TodoController`
function __g20004_enc_eTodo(v: Todo): JsonValue {
  return jsonObject([jsonMember("id", jsonInt(v.id)), jsonMember("title", jsonString(v.title))]);
}

function __g20002_h_TodoController_find(c: TodoController, req: Request): Result<Response, WebError> {
  const __g20003_a_id = bindPathInt(req, "id")?;
  return respondResult(200, c.find(__g20003_a_id), __g20004_enc_eTodo);
}

export type ControllerDeps = { todoService: TodoService; };

export function registerControllers(router: Router, deps: ControllerDeps, mws: Middlewares): Router {
  let r = router;
  const __g20000_c_TodoController = TodoController.create(deps.todoService);
  let __g20001_g_TodoController = newRouter();
  __g20001_g_TodoController = addRoute(__g20001_g_TodoController, "GET", "/:id",
    wireController(__g20000_c_TodoController, __g20002_h_TodoController_find));
  r = mountGroup(r, "/todos", __g20001_g_TodoController);
  return r;
}

export function registerControllersFrom(router: Router, svc: Services, mws: Middlewares): Router {
  return registerControllers(router, ControllerDeps { todoService: svc.todoService }, mws);
}

// generated for `@Service` on `TodoService`
export type Services = { todoService: TodoService; };
export type ServicesDeps = { prefix: string; };

export function buildServices(deps: ServicesDeps): Services {
  const __g30000_todoService = TodoService.create(deps.prefix);
  return Services { todoService: __g30000_todoService };
}
```

and the use:

```ts
import { buildApp, ServicesDeps } from "./beans.gen";
const app = buildApp(ServicesDeps { prefix: "first" }, newMiddlewares());     // a Router
app.handle(request);                  // or serve(net, app, config, ready), or new TestClient(app)
```

### Layouts: one module, or several

A companion is generated per source module, and a module that uses processor annotations cannot import the companion of another
module (ADR-0046: one round of expansion, E0520/E0521). So there are two layouts.

* **One module** holds the services and the controllers, with `@Application`: `buildApp` does everything.
* **Several modules** (`examples/todo-api`: `repository.or`, `service.or`, `controller.or`): each companion builds its own part, and a
  small module *without annotations* connects them in dependency order (`wiring.or`):

  ```ts
  const repos = repositories.buildServices(repositories.ServicesDeps { commands: commands });
  const svcs = services.buildServices(services.ServicesDeps { repo: repos.todoRepository });
  let app = controllers.registerControllers(newRouter(), controllers.ControllerDeps { todoService: svcs.todoService }, mws);
  ```

  Every line is checked by the compiler, so a forgotten or mistyped dependency does not compile, but the lines are written by hand.

### Middleware

`@Use("name, other")` and `@Auth` (= `@Use("auth")`) name middleware, because annotation arguments are constants and a middleware is a
function value. The names are bound at start-up in a `Middlewares` registry (`newMiddlewares().with("auth", bearerToken(..))`)
that is passed to the generated registration. On a controller, the middleware wrap every route of the controller (a group router
with `use`); on a method, that route only (`withMiddleware`). An unknown name stops the program at start-up with the controller,
method and name, like a malformed route pattern. Global middleware (`logger`, `cors`) are added to the router with `Router.use`.

### Why binding is declared on the method

Orin annotations can target declarations, methods and fields, not parameters, so `@Path("id")` cannot sit next to the parameter it
binds. The method carries the bindings by parameter name instead (`@Query("page, size=pageSize")`), and the common cases need no
annotation at all (path parameters by name). The cost is that a rename must change two places; the processor reports a binding that
names no parameter, so a stale annotation does not compile.

### Why `static create`

Generated code cannot instantiate a class: `std:meta` has no `new` expression, and a record literal of a class is refused outside its
body. So each bean has a static factory whose parameters are its dependencies, forwarding to the constructor. The processor reads
the factory, not the constructor, because it is the only code the generated container can call. See `docs/compiler-issues.md` for the
proposal that removes this line.

### Cost

Each processor is built into a helper executable by the compiler. On `tests/annotated` (three processors, one module) the first
`orin check` takes about 13.5 s and later ones 0.8 s, because the helpers and their outputs are cached under `.orin/processors`; an edit of
the annotated module re-runs the processors but reuses the helpers. The generated code is ordinary code and adds nothing at run time
beyond the helper calls it makes.

### Testing generated code

`orin test` cannot expand companion modules (docs/annotation-processors.md, "Limits"), so there are three kinds of tests:
the processors as pure functions (`tests/processor_test.or`: an `Input` in, declarations and diagnostics out), the runtime helpers
(`tests/binding_test.or`), and programs that use the generated code and trap on failure (`tests/annotated`, `examples/todo-api
selftest`, run by `tools/ci.sh`), plus `tests/compile-fail`, which compiles broken modules and checks the error text.

## WebAssembly (`wasm32-orbit`)

Checked against `orin 0.x` built from the repository at the time of writing.

| | Status |
|---|---|
| `Router`, `Request`, `Response`, middleware, JSON builders, assets, SSE encoding, `TestClient` | builds and runs (`examples/edge`, 290 KB module, run under `tools/wasm_run.mjs`) |
| the annotation layer (generated container, routes, bindings, codecs) | builds and runs: `tests/annotated` passes all its checks as a `wasm32-orbit` module (processors run at compile time, on the host) |
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
| `src/response.or` | `Response`, `ResponseBody` |
| `src/sse.or` | `SseEvent`, encoding and parsing |
| `src/jsonbuild.or` | constructors for `std:json` values |
| `src/router.or` | `Router`, `Handler`, `Middleware`, pattern parsing and matching, `chain`, `withMiddleware` |
| `src/middleware.or` | `logger recover bearerAuth bearerToken limitBody cors` |
| `src/assets.or` | `Asset`, `assetsHandler`, `staticResponse`, `contentTypeFor` |
| `src/testing.or` | `TestClient`, `testRequest`, `readEvents`, assertions |
| `src/server.or` | `serve`, `ServerConfig`, `ServerHandle` |
| `src/annotations.or` | `@Get @Post @Put @Patch @Delete @Status @Path @Query @Header @Body @Use @Auth` (metadata, read by the controller processor) |
| `src/service.or`, `src/controller.or`, `src/application.or` | `@Service`, `@Controller`, `@Application` with their processors |
| `src/gen_codec.or`, `src/metautil.or` | processor side: encoder and decoder generation, helpers (compile-time only) |
| `src/bind.or`, `src/respond.or`, `src/codec.or`, `src/wiring.or` | runtime side: what the generated code calls |

## Possible next steps

Cookies and sessions; `application/x-www-form-urlencoded` and multipart bodies; content negotiation (`Accept`); ETag and
conditional requests for assets; a typed-extractor layer on top of `decodeBody`; WebSocket upgrade; a `ClockGrant` parameter for
`Date` headers and access-log durations; a request-id middleware; an `OpenAPI` generator through an annotation processor
(`@Route` as in `examples/routes` of the Orin repository could register handlers at compile time).
