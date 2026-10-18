# Full-stack apps: an orin-web server and an orin-ui client, one set of types

Status: the contract below is what orin-web implements (`src/client.or`, `src/controller.or`); orin-ui's browser runtime consumes it.
Sections marked **orin-ui** are what the runtime has to do. Questions and changes: edit this file.

```
app/
  shared/    records, enums and the API contract; compiled into both sides; depends on orin-web only for the pure client types
  server/    @Service / @Controller classes, main(host) with serve(); depends on shared
  client/    orin-ui program, compiled to wasm; depends on shared; never imports the server
```

## 1. The typed API between them

A `@Controller` (class or interface) generates, besides the server routes, a **pure client**: functions that return an
`ApiRequest<Result<T, ApiError>>`. It is a *value that describes* one HTTP call and how to read its answer. Nothing in it performs I/O,
so it builds for `wasm32-orbit`, `wasm32-web` and native, and it is testable without a network.

```ts
// shared/src/todo.or
export type Todo = { id: int; title: string; done: bool; };
export type NewTodo = { title: string; };

@Controller("/api/todos")
export interface TodoApi {
  @Get("/")       list(): Result<Todo[], WebError>;
  @Get("/:id")    find(id: int): Result<Todo, WebError>;
  @Post("/") @Body @Status(201)   add(todo: NewTodo): Result<Todo, WebError>;
  @Delete("/:id") remove(id: int): Result<void, WebError>;
}
// generated into shared/src/todo.gen:
//   export function todoList(): ApiRequest<Result<Todo[], ApiError>>
//   export function todoFind(id: int): ApiRequest<Result<Todo, ApiError>>
//   export function todoAdd(todo: NewTodo): ApiRequest<Result<Todo, ApiError>>
//   export function todoRemove(id: int): ApiRequest<Result<void, ApiError>>
//   export type TodoClient = { list: () => ApiRequest<..>; find: (id: int) => ..; .. }   and   todoClient(): TodoClient
```

### 1.1 The request value (the part orin-ui consumes)

All of these are exported from `"orin-web"`.

```ts
export type NameValue = { name: string; value: string; };       // a header field, or a query field (decoded text)

export type ApiRequest<T> = {
  method: string;                     // "GET", "POST", "PUT", "PATCH", "DELETE"
  path: string;                       // "/api/todos/7": path parameters substituted and percent-encoded, no query, no origin
  query: NameValue[];                 // in order; repeated names allowed; values are decoded text (encode them when building the URL)
  headers: NameValue[];               // always "Accept: application/json"; "Content-Type: application/json" when there is a body
  body: Option<string>;               // JSON text (UTF-8), None for no body
  decode: (response: ApiResponse) => T;   // pure: status + body text -> the typed result
};

export type ApiResponse = { status: int; headers: NameValue[]; body: string; };

export type ApiError = {
  status: int;                        // the HTTP status, or 0 when there was no response (network failure, abort)
  code: string;                       // machine-readable: "not_found", "unprocessable", "unauthorized", "network_error", "bad_response", ...
  message: string;                    // for people
  details: FieldError[];              // for 422: one entry per invalid field
};
export type FieldError = { path: string; message: string; };      // path is a JSON pointer such as "/title" or "/tags/1"
```

Helpers (pure):

| Function | |
|---|---|
| `wireOf(req): WireRequest` | the data the shim needs: `{ method, url, headers, body }`; `url` is `path` + `?` + the encoded query |
| `decodeWith(req, response): T` | `req.decode(response)` |
| `mapRequest(req, f): ApiRequest<U>` | change the result type |
| `withHeader(req, name, value)`, `withBaseUrl(req, "https://api.example")`, `withCsrf(req, headerName, token)` | adjust a request |
| `networkError(message): ApiError` | for a call that got no response (`status: 0`, `code: "network_error"`) |
| `apiErrorMessage(e): string` | one line, for logs |
| `encodeWireRequest(w): string`, `decodeApiResponse(text): Result<ApiResponse, string>` | the JSON the shim exchanges (below) |

### 1.2 What the runtime does (**orin-ui**)

1. A command is made from a request and a message constructor: `Http.send(req: ApiRequest<R>, toMsg: (R) => Msg)` (the name is orin-ui's).
2. The runtime calls `wireOf(req)`, passes `encodeWireRequest(...)` to the JS shim, and the shim does `fetch(url, { method, headers, body,
   credentials: "same-origin" })`. The shim must not interpret the body.
3. When the fetch settles the shim hands back `{"status":200,"headers":[["content-type","application/json"]],"body":"<text>"}` (JSON,
   decoded by `decodeApiResponse`). If there was no response at all (offline, CORS, abort) the runtime builds the result itself:
   `req.decode` is **not** called; use `Err(networkError(reason))` of the request's result type. In the generated types that is
   `Result<T, ApiError>`, so the runtime constructs `Err(networkError(..))` and gives it to `toMsg`. For a request made with
   `mapRequest` to a non-`Result` type, the program maps; use `decodeWith(req, ApiResponse { status: 0, headers: [], body: "" })`:
   every decoder turns status 0 into `Err(networkError("no response"))`.
4. Otherwise `toMsg(req.decode(response))` is the message that is fed back into `update`.

The wire format of the shim:

```json
{"method":"POST","url":"/api/todos?x=1","headers":[["Accept","application/json"],["Content-Type","application/json"]],"body":"{\"title\":\"milk\"}"}
```
and the reply `{"status":201,"headers":[["content-type","application/json"]],"body":"{\"id\":1,...}"}` (header names as the browser reports them;
orin-web compares them case-insensitively).

## 2. Wire conventions

* **JSON only.** Requests with a body send `Content-Type: application/json`; responses are `application/json`. An `Accept` that excludes JSON
  is not negotiated (the server answers JSON).
* **Types on the wire** (the same code on both sides, generated from the type): `string`, `int` (a JSON integer within +-2^53), `bool`,
  `T[]`, `Option<T>` (`null` or absent is `None` on input; written as `null`), records (an object with the field names; unknown fields
  are rejected on input), unions of tags (a string with the variant name), `JsonValue` (as is). Not supported: floats, classes, unions
  with payloads. A processor reports an unsupported type at the method or type.
* **Error envelope**, for every non-2xx the server produces (router, handlers, binding, middleware):

  ```json
  {"error":{"status":422,"code":"unprocessable","message":"title: wrong type: expected string, found number","details":[{"path":"/title","message":"expected string, found number"}]}}
  ```
  `details` is always present (empty except for 422 with field errors). Codes: `bad_request` 400, `unauthorized` 401, `forbidden` 403,
  `not_found` 404, `method_not_allowed` 405, `not_acceptable` 406, `payload_too_large` 413, `unsupported_media_type` 415,
  `unprocessable` 422, `internal` 500, or the code a handler sets. The generated client decodes it into `ApiError`; a non-2xx without an
  envelope (a proxy page) becomes `code: "http_error"`, a 2xx that does not decode `code: "bad_response"`.
* **Status mapping of the controller layer:** `Option::None` -> 404; `void` -> 204; `@Status(n)` for success; client: an `Option<T>` result
  is `Ok(None)` on 404.
* **Cookies and same-origin.** The boot shell and the API are served by the same origin, so `fetch` with `credentials: "same-origin"`
  sends the session cookie and no CORS is involved. CORS (`cors(config)`) is for a client on another origin: set `credentials: true` and
  list the exact origin (`*` is not valid with credentials).
* **CSRF.** orin-web does not issue tokens; orin-auth's `CsrfProtection` does (cookie `__Host-csrf` + header `X-CSRF-Token`, or a custom
  header mode). orin-web provides the hooks: `csrfGuard(check)` (a middleware that runs `check` for unsafe methods), `withCsrf(req, name,
  token)` on the client side, and `cors` already allows and exposes the configured header names. The client reads the token the server
  put in the boot shell (`<meta name="csrf-token" content="...">`, see `bootShell`) or in a readable cookie and adds it to every unsafe
  request with `withCsrf`.

## 3. Serving the client

`staticSite(config)` serves the compiled client from memory: the `.wasm` (`Content-Type: application/wasm`), the orin-ui JS shim, CSS,
images, and `index.html`.

* Files whose name contains a content hash (`app.3f9a1c2b.wasm`, `shim.8a7d6e5f.js`: a dot, 8 to 64 hex digits, a dot) are sent with
  `Cache-Control: public, max-age=31536000, immutable`; every other file with `no-cache` and an `ETag` (`If-None-Match` answers 304).
* `index.html` is the **boot shell**, the only HTML the server produces: `bootShell(config)` writes it (title, stylesheet, the wasm and
  shim URLs, the CSRF meta tag). A path that is not a file and not under the API prefix falls back to the shell, so client-side routes
  survive a reload.
* `loadAssets(fs, dir)` reads a build directory into `Asset`s at start-up (the file-system grant is used in `main`, a handler cannot hold one).

## 4. Testing

`TestClient` drives the server; `clientCall(client, req)` sends an `ApiRequest` through it and runs `req.decode` on the real response, so a
test can say `clientCall(c, todoFind(7))` and get a `Result<Todo, ApiError>`. That is the round trip the shared types make safe.

## 5. TODO (browser)

* **orin-ui runtime:** the `Http` command described in 1.2, the JS shim, and `wasm32-web` as a build target; until then the typed client
  is exercised by the tests only. See `examples/todo-api` (`client/` placeholder).
