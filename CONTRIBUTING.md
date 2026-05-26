# Contributing to `swift-lifetime`

Thanks for the interest. This is a small, focused package — contributions
that fit its scope are welcome.

## Scope

`swift-lifetime` is about making **ownership and async teardown
explicit** for Swift Concurrency. Contributions that fit:

- Bug fixes (cancellation correctness, leaks, missed teardown).
- Documentation: README, DocC catalogs, articles, code examples.
- New types or APIs that earn their keep at the boundaries
  `TaskGroup` + `defer` do not cover.
- Performance improvements with benchmark evidence.

Contributions that do **not** fit, and will likely be closed:

- General-purpose concurrency utilities with no ownership story.
- Sweeping renames or style refactors without a concrete win.
- New modules that only marginally extend the existing surface.

If you are unsure whether something fits, open an issue with the
proposal before writing code. A short discussion saves both sides time.

## Requirements

- **Swift 6.2+ in Swift 6 language mode.** The package compiles with
  `defaultIsolation(.none)`, `strictMemorySafety`, and the
  `NonisolatedNonsendingByDefault` upcoming feature.
- **Platforms: macOS 15+, iOS 18+, tvOS 18+, watchOS 11+.** The floor
  is driven by `Synchronization.Mutex`. No PR may lower this.

## Setting up locally

The package is plain SwiftPM. Clone, then:

```bash
swift build
swift test
```

To run a single test by name:

```bash
swift test --filter ScopeTests/cancel_drains_resources
```

### Linux

Run the package against an upstream `swift:latest` Linux toolchain via
the bundled Docker helper:

```bash
./linux.sh                # interactive shell inside the container
./linux.sh run swift test # run the suite once and exit
./linux.sh reset          # tear the container down
```

The script mounts the working tree into the container, so files you
edit on the host are visible inside immediately.

### Pre-commit hooks

The repo uses [`prek`](https://prek.j178.dev) to run `swift-format
format` on staged Swift files. Install it once:

```bash
mise install     # picks up prek from mise.toml
prek install     # registers the git hook
```

If `prek` is not on your path, you can run formatting manually with
`swift format format -i Path/To/File.swift`.

## Code style

- The project formats with `swift-format` configured by
  `.swift-format.json`. `lineLength` is 100. Run `swift format
  format -i .` before committing if your editor does not.
- All public declarations must have `///` documentation. The
  `AllPublicDeclarationsHaveDocumentation` and
  `BeginDocumentationCommentWithOneLineSummary` rules are on; CI will
  reject undocumented public API.
- The README's "Reference vs value types" section spells out when a
  type should be a `final class` versus a `struct`. Follow it.
- Prefer typed throws (`throws(ScopeError)`) over untyped throws when
  the error set is fixed and small.
- No `print()` in shipped code. Use comments or test traces only.

## Tests

- New tests use [Swift Testing](https://github.com/apple/swift-testing)
  (`import Testing`, `@Test`, `#expect`). XCTest is allowed only when
  unavoidable (e.g. UI-test glue).
- Cancellation paths require an awaited assertion: a test that calls
  `cancel()` and does not await something observable downstream of the
  teardown is incomplete.
- Time-sensitive logic must use the `AsyncSleeper` injection point
  (see `LifetimePolicies/AsyncSleeper`). Tests should not call
  `Task.sleep` directly.
- Coverage:

  ```bash
  swift test --enable-code-coverage
  ```

  There is no hard percentage floor today, but new public API
  without a paired test is grounds for review push-back.

## Benchmarks

Performance-sensitive changes must run the benchmark suite in
release mode:

```bash
swift run -c release LifetimeBenchmarks
```

The benchmark suite has built-in regression thresholds. If a change
shifts a number, update the README benchmark table in the same PR and
explain the shift in the PR description.

## Commit messages

- One change per commit. Mixed-purpose commits get split before merge.
- Subject under 72 chars, imperative mood (`fix:`, `docs:`,
  `refactor:`, `feat:`, `perf:`). Follow the existing log.
- The body should explain *why*, not *what* — the diff is the *what*.

## Pull requests

- PRs target `main`.
- Pass `swift build`, `swift test`, and `swift-format lint` locally
  before opening.
- Reference any related issue in the description.
- Expect review feedback. Small PRs land faster than large ones.

## Security

Do not file public issues for suspected vulnerabilities. See
[`SECURITY.md`](./SECURITY.md).

## License

By contributing, you agree your contribution is licensed under the
package's [MIT license](./LICENSE).
