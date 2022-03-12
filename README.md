# ObservableStore

A simple Elm-like Store for SwiftUI, based on [ObservableObject](https://developer.apple.com/documentation/combine/observableobject).

ObservableStore helps you craft more reliable apps by centralizing all of your application state into one place, and making all changes to state deterministic. If you’ve ever used [Elm](https://guide.elm-lang.org/architecture/) or [Redux](https://redux.js.org/), you get the gist. All state updates happen through actions passed to an update function. This guarantees your application will produce exactly the same state, given the same actions in the same order.

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
        state: AppState,
        environment: AppEnvironment,
        action: AppAction
    ) -> Update<AppState, AppAction> {
        switch action {
        case .increment:
            var model = state
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

## State, updates, and actions

A `Store` is a source of truth for application state. It's an [ObservableObject](https://developer.apple.com/documentation/combine/observableobject), so you can use it anywhere in SwiftUI that you would use an ObservableObject—as an [@ObservedObject](https://developer.apple.com/documentation/swiftui/observedobject), a [@StateObject](https://developer.apple.com/documentation/swiftui/stateobject), or [@EnvironmentObject](https://developer.apple.com/documentation/swiftui/environmentobject).

Store exposes a single [`@Published`](https://developer.apple.com/documentation/combine/published) property, `state`, which represents your application state. `state` is read-only, and cannot be updated directly. Instead, like Elm or Redux, all `state` changes happen through a single `update` function, with the signature:

```
(State, Environment, Action) -> Update<State, Action>
```

The `Update` returned is a small struct that contains a new state, plus any optional effects and animations associated with the state transition (more about that in a bit).

`state` can be any [`Equatable`](https://developer.apple.com/documentation/swift/equatable) type, typically a struct. Before setting a new state, Store checks that it is not equal to the previous state. New states that are equal to old states are not set, making them a no-op. This means views only recalculate when the state actually changes. Additionally, because state is Equatable, you can make any view that relies on Store, or part of Store, an [EquatableView](https://developer.apple.com/documentation/swiftui/equatableview), so the view’s body will only be recalculated if the values it cares about change.

## Getting and setting state in views

There are a few different ways to work with Store in views.

`Store.state` lets you reference the current state directly within views. It’s read-only, so this is the approach to take if your view just needs to read, and doesn’t need to change state.

```swift
Text(store.state.text)
```

`Store.send(action:)` lets you send actions to the store to change state. You might call send within a button action, or event callback, for example.

```swift
Button("Set color to red") {
    store.send(action: AppAction.setColor(.red))
}
```

`Store.binding(get:tag:animation:)` lets you create a [binding](https://developer.apple.com/documentation/swiftui/binding) that represents some part of the state. A get function reads the state into a value, a tag function turns a value set on the binding into an action. The result is a binding that can be passed to any vanilla SwiftUI view, yet changes state only through deterministic updates.

```swift
TextField(
    "Username"
    text: store.binding(
        get: { state in state.username },
        tag: { username in .setUsername(username) }
    )
)
```

Or, shorthand:

```swift
TextField(
    "Username"
    text: store.binding(
        get: \.username,
        tag: .setUsername
    )
)
```

You can also create bindings for sub-properties, just like with any other SwiftUI binding. Here's an example of creating a binding to a deep property of the state:

```swift
TextField(
    "Bio"
    text: store
        .binding(
            get: { state in state.settings },
            tag: { settings in .setSettings(settings) }
        )
        .profile
        .bio
)
```

Bottom line, because Store is just an ordinary [ObservableObject](https://developer.apple.com/documentation/combine/observableobject), and can produce bindings, you can write views exactly the same way you write vanilla SwiftUI views. No special magic! Properties, [@Binding](https://developer.apple.com/documentation/swiftui/binding), [@ObservedObject](https://developer.apple.com/documentation/swiftui/observedobject), [@StateObject](https://developer.apple.com/documentation/swiftui/stateobject) and [@EnvironmentObject](https://developer.apple.com/documentation/swiftui/environmentobject) all work as you would expect.

## Effects

 Updates are also able to produce asyncronous effects via [Combine](https://developer.apple.com/documentation/combine) publishers. This lets you schedule asyncronous things like HTTP requests or database calls in response to actions. Using effects, you can model everything via a deterministic sequence of actions, even asyncronous side-effects.
 
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

You can subscribe to an effects publisher by returning it as part of an Update:

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

Store will manage the lifecycle of any publishers returned by an Update, piping the actions they produce back into the store, producing new states, and cleaning them up when they complete.

## Animations

You can also drive explicit animations as part of an Update.

Use `Update.animation` to set an explicit [Animation](https://developer.apple.com/documentation/swiftui/animation) for this state update.

```swift
func update(
    state: State,
    environment: Environment,
    action: Action
) -> Update<State, Action> {
    switch action {
    // ...
    case .authenticate(let credentials):
        return Update(state: state).animation(.default)
    }
}
```

Alternatively, you can use the lower-level `Update.transaction` API to set the [Transaction](https://developer.apple.com/documentation/swiftui/transaction) for this state update:

```swift
func update(
    state: State,
    environment: Environment,
    action: Action
) -> Update<State, Action> {
    switch action {
    // ...
    case .authenticate(let credentials):
        return Update(state: state)
            .transaction(
                Transaction(animation: .default)
            )
    }
}
```
