# Boot

Boot is a lifecycle-oriented dependency framework for Swift applications.

Its core model is:

- `Scope` owns lifetime.
- `Scoped<Value>` is a handle for resolving a dependency inside a scope.
- `Component<Exports>` is a child scope plus its exported dependencies.
- `Owned<Value>` is an explicit owner handle for runtime values that need teardown.

## Guarantees

- `Scope.cancel()` is idempotent.
- shared dependencies resolve once per scope and are torn down when the scope ends
- `Component` cancellation cascades through the component scope
- `.detached` is a supported dependency-resolution mode
- Boot preserves its own dependency-resolution context across `.detached` work so cycle detection and dependency labelling still work

Standard detached-task semantics are still unchanged:

- detached work does not inherit parent-task cancellation
- detached work does not inherit parent-task priority
- detached work does not inherit unrelated task-local values

## Ownership

`entities.factory(...)` now returns `Owned<Value>` handles rather than bare values.

```swift
let factory = try scope.entities.factory(name: "Socket") {
  SocketConnection()
} tearDown: { socket in
  await socket.close()
}

let socket = try await factory.make()
await socket.cancel()
```

`Owned` is the ownership unit:

- it conforms to `CancellableType`
- `cancel()` is idempotent
- dropping the last unadopted handle auto-cancels it

To assign ownership to a scope, adopt the handle:

```swift
let owned = try await factory.make()
try scope.onShutdown(cancel: owned)
```

That is the standard way to say "this runtime value now belongs to this scope."

`Component` already behaves as an owner handle because it conforms to `CancellableType` and cancels its child scope.

## Shared And Instance Bindings

```swift
let config = try scope.entities.instance(AppConfig.live)

let client = try scope.entities.shared(.detached, name: "APIClient") {
  APIClient(config: try await config.get())
} tearDown: { client in
  await client.shutdown()
}
```

Use `shared` for one value per scope. Use `instance` for an already-created value. Use `factory` when Boot should hand back an explicit owner handle.

## Components

```swift
struct SessionDependency: Dependency {
  struct Input: Sendable {
    let token: String
  }

  let sessionID: Scoped<String>

  init(with requirement: Input, in scope: Scope) async throws {
    sessionID = try scope.entities.instance(requirement.token, name: "SessionID")
  }
}

let makeSession = try scope.components.factory(SessionDependency.self)
let session = try await makeSession(.init(token: "abc"))
await session.cancel()
```

Use `components.shared(...)` when a scope should lazily own a single child component. Use `components.factory(...)` when callers should explicitly own the child component handle.

## SwiftUI

`BootSwiftUI` provides:

- `@Mount` for optional component presentation
- `Mounting<D>` as the projected lifecycle model

`@Mount` can be declarative over a `Scoped<Component<D>>`:

```swift
struct RootView: View {
  @Mount private var app: Component<AppDependency>?

  init(source: Scoped<Component<AppDependency>>) {
    _app = Mount(source)
  }

  var body: some View {
    Group {
      if let app {
        AppScreen(component: app)
      } else {
        ProgressView()
      }
    }
  }
}
```

The projected value exposes mount state and actions:

```swift
struct DesktopView: View {
  @Mount private var session: Component<SessionDependency>?

  var body: some View {
    Group {
      if session != nil {
        SessionScreen(mounting: $session)
      }
    }
    .task {
      if let next = try? await makeSession() {
        await $session.replace(with: next)
      }
    }
  }
}
```

`Mounting<D>` provides:

- `phase`
- `component`
- `error`
- `isMounted`
- `unmount()`
- `replace(with:)`

Replacement cancels and fully awaits the old component before the new one is published.

## Testing

The package uses Swift Testing. Current coverage includes:

- shared and factory lifecycle behavior
- detached dependency-context propagation
- owner-handle teardown and scope adoption
- BootSwiftUI mount lifecycle and replacement behavior
