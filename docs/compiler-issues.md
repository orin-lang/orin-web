# Compiler and std issues met while building orin-web

The first part is about `std:meta` and annotation processors, met while building the annotation layer (`@Controller`, `@Service`).
The second part is what turned up building the functional API.

# Part 1: annotation processors (`std:meta`, ADR-0046)

Nothing here blocked the feature: each limit has a workaround that is in the code and documented in docs/design.md. They decide how
close to Spring the result can get, so each comes with a concrete proposal.

## P1. Generated code cannot instantiate a class (no `new` expression) -- the largest gap

`std:meta`'s `MExpr` has calls, methods, fields, record literals, but no `new C(args)`. A call `C(args)` is E0300 ("create instances
with `new C(...)`"), a record literal of a class is E0408 ("cannot be built with a record literal outside its own body; use
`new A(..)`"), and `call("new A", ..)` is rejected by the output decoder ("`new A` is not an identifier").

*Consequence.* A container that creates beans cannot call their constructors. Every `@Service` and `@Controller` needs a one-line
`static create(deps..): C { return new C(deps..); }`, and the processor reads that factory's parameters as the dependencies, not the
constructor's. The ceremony is one line per bean and a rename in two places.

*Proposal.* Add `MENew(className: string, typeArgs: MType[], args: MExpr[])` to `std:meta` (builder `newExpr(cls, args)`, JSON tag
`"new"`). The AST already has `ENew(Ident, TypeExpr[], Expr[])` (compiler/syntax/ast.or:235) and `compiler/meta/fromjson.or` needs one
more case next to `"call"`. The checker's existing rules apply unchanged (private constructors, generic classes). Then `@Service`
classes need no factory and the processor reads `ctorParams`, which the input already has.

## P2. Annotations cannot target parameters

ADR-0046 §1: targets are `function`, `method`, `class`, `type`, `interface`, `field`, `const`. `@Path("id")`, `@Query("page")`,
`@Header("x")` next to the parameter they bind (the Spring shape) are therefore impossible. orin-web puts the binding on the method by
parameter name: `@Query("page, size=pageSize")`. A path parameter needs no annotation (bound by name). The result is correct and
checked (a binding naming no parameter is a compile error), but it is not the declaration-next-to-the-parameter people expect, and a
rename touches two places.

*Proposal.* Add the target `param` to `@Annotation(..)`, parse annotations on parameters (the parser already handles them on fields),
and give `MParam` an `annotations: MAnnotation[]` field (default `[]`) so that `MMethodView.params`, `MDeclView.ctorParams` and
function parameters carry them. `MParam` is also the type of generated parameters, so builders keep `param(name, ty)`.

## P3. A processor sees only the declarations that carry its own annotation, and classes are opaque elsewhere

`Input.decls` are the declarations annotated with the processor's annotation, in one module; `Input.types` lists every other named
type that occurs, with its shape only for records, unions and aliases -- a class or interface is `MSOpaque` (compiler/meta/snapshot.or,
`shapeJson`). There is one processor per annotation, run separately.

*Consequence.* No processor can see the whole dependency graph. `@Service` and `@Controller` are different annotations, so the
service processor does not see controllers and vice versa; a class that is only mentioned (a dependency type) has no constructor, methods
or implemented interfaces in the input. The cross-link is done by naming conventions (`Services`, `ControllerDeps`,
`registerControllersFrom`, fields named `lowerCamel(type)`) that the type checker verifies on the generated code. That is why a controller
that needs a missing service fails as "unknown type `Services`" or a missing field, not as a message about the controller, and why
`@Application` assumes one module holds both sides.

*Proposal (any one of the first two removes most of it).*
(a) Let a processor be registered for several annotations of one module, `@Processor(Controller, Service)`, receiving all their
declarations in one `Input` (and tell it which annotation each declaration carries -- `annotations` already does).
(b) Give classes and interfaces a shape in `Input.types` -- constructor parameters, methods with their annotations, `implements` -- so
that a processor can follow a dependency into its declaration.
(c) Add `MDeclView.implements: string[]` (not available today), so that "which classes implement `TodoRepository`" can be answered.

## P4. Generated code cannot be composed across modules

A module that uses processor annotations must not import any `.gen` module (E0521), and a companion cannot import another companion
(E0520). So the generated pieces of the repository, service and controller modules cannot be connected by generated code; the
connection (`examples/todo-api/src/wiring.or`, four lines) is hand-written in a module without annotations. The compiler checks each
line, but it is the part of a Spring application that people expect to be automatic.

*Proposal.* A second kind of processor that runs once per package (or per module that imports the companions of others), after the
per-module expansion, with an `Input` that lists the exports of every companion (names and types of `Services`, `ControllerDeps`,
`ServicesDeps`...). Or allow companion-to-companion imports in module dependency order (one round per layer; the existing cycle check
already forbids the dangerous case).

## P5. `orin test` cannot expand generated code

`orin test` without a file loads the entry graph; if it reaches an import of a `.gen` module the result is E0300 (documented under
"Limits" in docs/annotation-processors.md). `orin test tests/store_test.or` with an explicit file works. So generated code is tested by
programs that trap on failure (`tests/annotated`, `examples/todo-api` `selftest`), not by `@Test` functions, and a package such as
`examples/todo-api` cannot use bare `orin test` at all.

*Proposal.* Make `orin test` expand processors like `orin build` does (it already builds an executable with the checker, MIR and the C
backend).

## P6. Smaller things

* **No `MEArrow`.** Generated code cannot create a closure, so every handler is a top-level function and a runtime helper
  (`wireController(c, method)`) closes over the controller. *Proposal:* an arrow expression in `MExpr` (parameters with types, a block or
  expression body).
* **No `static` flag on `MMethodView`.** The processor finds the factory by the name `create`; an instance method called `create` is
  caught only by the type checker. *Proposal:* `static: bool` on `MMethodView`.
* **Annotation spans.** A diagnostic points at an item (`MRef`) -- orin-web points at the method for binding errors, which reads well --
  but not at an annotation or one of its arguments (`@Query("rati0")` is reported at the method). *Proposal:* refs for annotations.
* **`MConst` for `Option` arguments** arrives as `MCSome(MCString(..))` / `MCNone` while a `string` field is a bare `MCString`. Fine,
  but `annotationString` in `src/metautil.or` has to handle both because a processor cannot know which a field is. A helper in
  `std:meta` (`constStringOpt`) would do.
* **Sources of types in other modules.** `MTypeShape.source` is a module label such as `./model`; orin-web uses it as the import path for
  record types of other modules that the controller module does not itself import. This works for files next to each other; the label
  is relative to the package, which is not the importing file when modules are nested in directories. Not exercised.
* **The cost of a processor is one helper executable per annotation.** Measured on `tests/annotated`
  (three processors): `orin check` takes 13.5 s with a cold `.orin/processors` cache and 0.8 s warm. The helper is rebuilt when a
  processor changes (so for every edit of orin-web itself), not when the annotated module changes.

## What worked well

Hygienic names, the typed output builders, E0522 diagnostics that point at a method, `orin expand` as the review tool, the output
cache, and the guarantee that generated code is checked like hand-written code (it caught every convention violation above with a
message that names the generating annotation). The processors are pure functions, so they are unit-tested by building an `Input`.

# Part 2: the functional API

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
