# Compiler and std issues met while building orin-web

Found with the toolchain built from `orin-lang/orin-lang` main on 2026-10-18 (`orin` launcher, C backend). Nothing here blocked the
work. Each item says what happened, what orin-web does instead, and whether it looks like a bug or a missing feature.

## Missing features that shaped the API

1. **No `export * from`.** `export * from "./x"` is E0200. `src/module.or` lists every export by name, so adding a function means
   editing two files. *Missing feature.*
2. **`Result` has no combinators.** There is no `map`, `mapErr` or `unwrapOr` on `Result` (only `isOk isErr unwrap unwrapErr`), and `?`
   works on `Result` only, not `Option`. Converting an error type takes four lines (see `Response.redirect`). *Missing feature
   (documented in reference chapter 3, but it makes `Result`-returning application code wordy).*
3. **Closures cannot capture a grant or a resource** (E0452/E0483), by design. Consequences: a `Handler` cannot serve files from
   a directory (it would need an `FsGrant`); the streamed body of a response cannot hold the connection; `serve` has no way to give
   handlers a clock. orin-web serves assets that the program reads in `main`, and streams through pull sources over channels. *By
   design; recorded because it decides what a web framework can offer.*
4. **Built-in functions cannot be used as function values** (`console.error` as a sink, `parseInt` as a decoder), so the
   `logger` sink is written `(line: string) => console.error(line)`. *Known limitation (docs/known-limitations.md).*
5. **A class cannot have a static method and an instance method with the same name** (E0304 "duplicate method"). `Response.text(status,
   text)` (static constructor) and the accessor for the body text therefore could not both be `text`; the accessors are
   `bodyText()` and `bodyBytes()`. *Limitation.*
6. **Top-level `const` initializers must be literals** (E0408): no array constants. Static tables are functions
   (`demo(): string[]` in `examples/edge`). *Known limitation.*
7. **`from` is a reserved word everywhere**, also as a local variable name (E0200 "expected identifier, found `from`"). *Surprising
   but consistent with TypeScript's contextual keyword in reverse; harmless.*
8. **Strings have no `lastIndexOf`, `toLowerCase` or `replace`** (ADR-0048 7.4 plans them). orin-web uses `std:http`'s `toLowerAscii`
   (documented there as internal) and splits on `"."` for extensions. *Missing feature.*
9. **Helpers that ADR-0048 7.3 calls internal are the only way to write HTTP.** `toLowerAscii`, `eqIgnoreCase`, `hexString` and
   `standardReason` of `std:http` are marked "Internal" in `docs/std.md` but are exported, and orin-web needs them (case-insensitive
   header names, chunk sizes, reason phrases). When they move to `std:http/internal` they will need a public replacement.
   *API in transition.*

## Behaviour worth knowing

10. **Where a trap is the only option, there is no message channel.** A bad route pattern must stop the program at start-up;
    `Router.route` prints to stderr and calls `exit(101)` itself because `std:test`'s `fail` is the only std helper that does that and
    it belongs to tests. A `std:process` function `abort(message)` would serve libraries. *Missing feature.*
11. **`orin fetch` is required after adding a path dependency**, and `orin check`/`test` then say "Lockfile is out of date. Run `orin
    fetch`" without naming which dependency changed. Works as documented. The diagnostic paths for code in a path dependency read
    `src/../../../src/server.or` (relative to the dependent's `src`). *Cosmetic.*
12. **wasm32-orbit has no `std:net`**, so no `serve` there; see docs/design.md. The effect analysis reports it well (E0523 with the full
    call path), including through closures. *As documented.*
13. **`orin test` has no `--release`** (`Unknown test option`), so the tests only run with the dev profile and checked contracts.
    *Missing option; docs/cli.md does not promise it.*

No compiler crash, wrong code or wrong diagnostic was found. The only workaround that touches correctness is item 5's renaming.
