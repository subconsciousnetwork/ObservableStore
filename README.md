# ObservableStore

A simple Elm-like Store for SwiftUI, based on [ObservableObject](https://developer.apple.com/documentation/combine/observableobject).

Like Elm or Redux, `ObservableStore.Store` offers reliable unidirectional state and effects management. All state updates happen through actions passed to an update function. This guarantees your application will produce exactly the same state, given the same actions in the same order.

Because `Store` is an [ObservableObject](https://developer.apple.com/documentation/combine/observableobject), it can be used anywhere in SwiftUI that ObservableObject would be used.

Store is meant to be used as part of a single app-wide, or major-view-wide component. It deliberately does not solve for nested components or nested stores. Following Elm, deeply nested components are avoided. Instead, it is designed for apps that use a single store, or perhaps one store per major view. Instead of decomposing an app into many stateful components, ObservableStore favors decomposing an app into many stateless views that share the same store and actions. Sub-views can be passed data through bare properties of `store.state`, or bindings, which can be created with `store.binding`, or share the store globally, through [`EnvironmentObject`](https://developer.apple.com/documentation/swiftui/environmentobject). See <https://guide.elm-lang.org/architecture/> and <https://guide.elm-lang.org/webapps/structure.html> for more about this philosophy.

## Example

A minimal example of Store used to increment a count with a button.

```swift
import SwiftUI
import os
import Combine
import ObservableStore

/// Actions
enum AppAction {
    case increment
}

/// Services like API methods go here
struct AppEnvironment {
}

/// App state
struct AppState: Equatable {
    var count = 0

    /// State update function
    static func update(
        model: AppState,
        environment: AppEnvironment,
        action: AppAction
    ) -> Update<AppState, AppAction> {
        switch action {
        case .increment:
            var model = self
            model.count = model.count + 1
            return Update(state: model)
        }
    }
}

struct AppView: View {
    @StateObject var store = Store(
        update: AppState.update,
        state: AppState(),
        environment: AppEnvironment()
    )

    var body: some View {
        VStack {
            Text("The count is: \(store.state.count)")
            Button(
                action: {
                    // Send `.increment` action to store,
                    // updating state.
                    store.send(action: .increment)
                },
                label: {
                    Text("Increment")
                }
            )
        }
    }
}
```

## Store, state, updates, and actions

A `Store` is a source of truth for a state. It's an `ObservableObject`. You can use it in a view via `@ObservedObject` or `@StateObject` to power view rendering.

Store exposes a single [`@Published`](https://developer.apple.com/documentation/combine/published) property, `state`, which represents your application state. All updates and effects to this state happen through actions sent to `store.send`.

`state` is read-only, and cannot be updated directly. Instead, like Elm, or Redux, all `state` changes happen through a single `update` function, with the signature:

```
(State, Environment, Action) -> Update<State, Action>
```

The `Update` returned is a small struct that contains a new state, plus any effects this state change should generate (more about that in a bit).

`state` is modeled as an [`Equatable`](https://developer.apple.com/documentation/swift/equatable) type, typically a struct. Updates only mutate the `state` property on `store` when they are not equal. This means returning the same state twice is a no-op, and SwiftUI view body recalculations are only triggered if the state actually changes. Since `state` is `Equatable`, you can also make `Store`-based views [EquatableViews](https://developer.apple.com/documentation/swiftui/equatableview), wherever appropriate.

## Effects

 Updates are also able to produce asyncronous effects via [Combine](https://developer.apple.com/documentation/combine) publishers. This lets you schedule asyncronous things like HTTP requests, or database calls, in response to actions. Using effects, you can model everything via a deterministic sequence of actions, even asyncronous side-effects.
 
Effects are modeled as [Combine Publishers](https://developer.apple.com/documentation/combine/publishers) which publish actions and never fail.

For convenience, ObservableStore defines a typealias for effect publishers:

```swift
public typealias Fx<Action> = AnyPublisher<Action, Never>
```

The most common way to produce effects is by exposing methods on `Environment` that produce effects publishers. For example, an asyncronous call to an authentication API service might be implemented in `Environment`, where an effects publisher is used to signal whether authentication was successful.

```swift
struct Environment {
    // ...
    func authenticate(credentials: Credentials) -> AnyPublisher<Action, Never> {
      // ...
    }
}
```

The update function can pass this effect through `Update(state:fx:)`

```swift
func update(
    state: State,
    environment: Environment,
    action: Action
) -> Update<State, Action> {
    switch action {
    // ...
    case .authenticate(let credentials):
        return Update(
            state: state,
            fx: environment.authenticate(credentials: credentials)
        )
    }
}
```

Store will manage the lifecycle of any publishers passed through `fx` this way, piping the actions they produce back into the store, producing new states.
