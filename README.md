# ObservableStore

A simple Elm-like Store for SwiftUI, based on [ObservableObject](https://developer.apple.com/documentation/combine/observableobject).

ObservableStore helps you craft more reliable apps by centralizing all of your application state into one place, and giving you a deterministic system for managing state changes and side-effects. All state updates happen through actions passed to an update function. This guarantees your application will produce exactly the same state, given the same actions in the same order. If you’ve ever used [Elm](https://guide.elm-lang.org/architecture/) or [Redux](https://redux.js.org/), you get the gist.

Because `Store` is an [ObservableObject](https://developer.apple.com/documentation/combine/observableobject), it can be used anywhere in SwiftUI that ObservableObject would be used.

Store can be used as a single shared [`EnvironmentObject`](https://developer.apple.com/documentation/swiftui/environmentobject), or you can pass scoped parts of store down to sub-view through:

- Bare properties of `store.state`
- Ordinary SwiftUI bindings
- ViewStores that that provide a component-scoped store for an underlying parent store.

## Example

A minimal example of Store used to increment a count with a button.

```swift
import SwiftUI
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
        action: AppAction,
        environment: AppEnvironment
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
                    store.send(.increment)
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
(State, Action, Environment) -> Update<State, Action>
```

The `Update` returned is a small struct that contains a new state, plus any optional effects and animations associated with the state transition (more about that in a bit).

`state` can be any [`Equatable`](https://developer.apple.com/documentation/swift/equatable) type, typically a struct. Before setting a new state, Store checks that it is not equal to the previous state. New states that are equal to old states are not set, making them a no-op. This means views only recalculate when the state actually changes. Additionally, because state is Equatable, you can make any view that relies on Store, or part of Store, an [EquatableView](https://developer.apple.com/documentation/swiftui/equatableview), so the view’s body will only be recalculated if the values it cares about change.


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
    action: Action,
    environment: Environment
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
    action: Action,
    environment: Environment
) -> Update<State, Action> {
    switch action {
    // ...
    case .authenticate(let credentials):
        return Update(state: state).animation(.default)
    }
}
```

When you specify a transition or animation as part of an Update, Store will use that animation when setting the state for the update.

## Getting and setting state in views

There are a few different ways to work with Store in views.

`Store.state` lets you reference the current state directly within views. It’s read-only, so this is the approach to take if your view just needs to read, and doesn’t need to change state.

```swift
Text(store.state.text)
```

`Store.send(_)` lets you send actions to the store to change state. You might call send within a button action, or event callback, for example.

```swift
Button("Set color to red") {
    store.send(AppAction.setColor(.red))
}
```

## Bindings

`Binding(store:get:tag:)` lets you create a [binding](https://developer.apple.com/documentation/swiftui/binding) that represents some part of the state. The `get` closure reads the state into a value, and the `tag` closure wraps the value set on the binding in an action. The result is a binding that can be passed to any vanilla SwiftUI view, but changes state only through deterministic updates.

```swift
TextField(
    "Username"
    text: Binding(
        store: store,
        get: { state in state.username },
        tag: { username in .setUsername(username) }
    )
)
```

Or, shorthand:

```swift
TextField(
    "Username"
    text: Binding(
        store: store,
        get: \.username,
        tag: .setUsername
    )
)
```

Bottom line, because Store is just an ordinary [ObservableObject](https://developer.apple.com/documentation/combine/observableobject), and can produce bindings, you can write views exactly the same way you write vanilla SwiftUI views. No special magic! Properties, [@Binding](https://developer.apple.com/documentation/swiftui/binding), [@ObservedObject](https://developer.apple.com/documentation/swiftui/observedobject), [@StateObject](https://developer.apple.com/documentation/swiftui/stateobject) and [@EnvironmentObject](https://developer.apple.com/documentation/swiftui/environmentobject) all work as you would expect.


## ViewStore

ViewStore lets you create component-scoped stores from a shared parent store. This allows you to create apps from free-standing deterministic components that all have their own local state, actions, and update functions, but share the same underlying root store. You can think of ViewStore as like a binding, except that it exposes the same StoreProtocol API that Store does.

Imagine we have a stand-alone child component that looks something like this:

```swift
enum ChildAction {
    case increment
}

struct ChildModel: Equatable {
    var count: Int = 0

    static func update(
        state: ChildModel,
        action: ChildAction,
        environment: Void
    ) -> Update<ChildModel, ChildAction> {
        switch action {
        case .increment:
            var model = state
            model.count = model.count + 1
            return Update(state: model)
        }
    }
}

struct ChildView: View {
    var store: ViewStore<ChildModel, ChildAction>

    var body: some View {
        VStack {
            Text("Count \(store.state.count)")
            Button(
                "Increment",
                action: {
                    store.send(ChildAction.increment)
                }
            )
        }
    }
}
```

Now we want to integrate this child component with other components that share the same root store. To create a ViewStore from the root store, we need to specify a way to map from this child component's state and actions to the root store state and actions. This is where `CursorProtocol` comes in. It defines three things:

- A way to `get` a local state from the global state
- A way to `set` a local state on a global state
- A way to `tag` a local action so it becomes a global action

```swift
struct AppChildCursor: CursorProtocol {
    /// Get child state from parent
    static func get(state: ParentModel) -> ChildModel {
        state.child
    }

    /// Set child state on parent
    static func set(state: ParentModel, inner child: ChildModel) -> ParentModel {
        var model = state
        model.child = child
        return model
    }

    /// Tag child action so it becomes a parent action
    static func tag(_ action: ChildAction) -> ParentAction {
        switch action {
        default:
            return .child(action)
        }
    }
}
```

...This gives us everything we need to map from a local scope to the global store. Now we can create a scoped ViewStore from the shared app store and pass it down to our ChildView.

```swift
struct ContentView: View {
    @ObservedObject private var store: Store<AppModel, AppAction, AppEnvironment>

    var body: some View {
        ChildView(
            store: ViewStore(
                store: store,
                cursor: AppChildCursor.self
            )
        )
    }
}
```

ViewStores can also be created from other ViewStores, allowing for infinite hierarchical nesting of components.

One more thing. Because cursors map or wrap child actions into parent actions, the parent update function must handle those actions. Cursors gives us a handy shortcut by synthesizing an `update` function that automatically maps child state and actions to parent state and actions.

```swift
enum AppAction {
    case child(ChildAction)
}

struct AppModel: Equatable {
    var child = ChildModel()

    static func update(
        state: AppModel,
        action: AppAction,
        environment: AppEnvironment
    ) -> Update<AppModel, AppAction> {
        switch {
        case .child(action):
            return AppChildCursor.update(
                with: ChildModel.update,
                state: state,
                action: action,
                environment: ()
            )
        }
    }
}```

This tagging/update pattern gives parent components an opportunity to intercept and handle child actions in special ways.

That's it! You can get state and send actions from the ViewStore, just like any other store, and it will translate local state changes and fx into app-level state changes and fx. Using ViewStore you can compose an app from multiple stand-alone components that each describe their own domain model and update logic.
