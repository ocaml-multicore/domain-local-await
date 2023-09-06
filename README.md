[API reference](https://ocaml-multicore.github.io/domain-local-await/doc/domain-local-await/Domain_local_await/index.html)

# **domain-local-await** &mdash; Scheduler independent blocking

A low level mechanism intended for writing higher level libraries that need to
block in a scheduler friendly manner.

A library that needs to suspend and later resume the current thread of execution
may simply call
[`prepare_for_await`](https://ocaml-multicore.github.io/domain-local-await/doc/domain-local-await/Domain_local_await/index.html#val-prepare_for_await)
to obtain a pair of
[`await`](https://ocaml-multicore.github.io/domain-local-await/doc/domain-local-await/Domain_local_await/index.html#type-t.await)
and
[`release`](https://ocaml-multicore.github.io/domain-local-await/doc/domain-local-await/Domain_local_await/index.html#type-t.release)
operations for the purpose.

To provide an efficient and scheduler friendly implementation of the mechanism,
schedulers may install an implementation by wrapping the scheduler main loop
with a call to
[`using`](https://ocaml-multicore.github.io/domain-local-await/doc/domain-local-await/Domain_local_await/index.html#val-using).
The implementation is then stored in a domain, and optionally thread, local
variable. The overhead that this imposes on a scheduler should be insignificant.

An application can the choose to use schedulers that provide the necessary
implementation. An implementation that works with plain domains and threads is
provided as a default.

The end result is effective interoperability between schedulers and concurrent
programming libraries.

## Contents

- [Example: Concurrency-safe lazy](#example-concurrency-safe-lazy)
- [Example: Scheduler-friendly Mutex](#example-scheduler-friendly-mutex)
- [Example: Awaitable atomic locations](#example-awaitable-atomic-locations)
- [References](#references)

## Example: Concurrency-safe lazy

At the time of writing this, the documentation of the Stdlib `Lazy` module
includes the following note:

> Note: `Lazy.force` is not concurrency-safe. If you use this module with
> multiple fibers, systhreads or domains, then you will need to add some locks.

Let's build a draft of a concurrency-safe version of lazy using atomics and
domain-local-await!

First we need to require the library:

<!--
```ocaml
# #thread
# #require "domain_shims"
```
-->

```ocaml
# #require "domain-local-await"
```

Here is a pair of types to represent the internal state of a lazy computation:

```ocaml
type 'a state =
  | Fun of (unit -> 'a)
  | Run of (unit -> unit) list
  | Val of 'a
  | Exn of exn

type 'a lazy_t = 'a state Atomic.t
```

A lazy computation starts as a thunk:

```ocaml
# let from_fun th = Atomic.make (Fun th)
val from_fun : (unit -> 'a) -> 'a state Atomic.t = <fun>
```

Or can be directly constructed with the given value:

```ocaml
# let from_val v = Atomic.make (Val v)
val from_val : 'a -> 'a state Atomic.t = <fun>
```

The interesting bits are in the `force` implementation:

```ocaml
# let rec force t =
    match Atomic.get t with
    | Val v -> v
    | Exn e -> raise e
    | Fun th as before ->
      if Atomic.compare_and_set t before (Run []) then
        let result =
          match th () with
          | v -> Val v
          | exception e -> Exn e
        in
        match Atomic.exchange t result with
        | (Val _ | Exn _ | Fun _) ->
          failwith "impossible"
        | Run waiters ->
          List.iter ((|>) ()) waiters;
          force t
      else
        force t
    | Run waiters as before ->
      let dla = Domain_local_await.prepare_for_await () in
      let after = Run (dla.release :: waiters) in
      if Atomic.compare_and_set t before after then
        match dla.await () with
        | () ->
          force t
        | exception cancelation_exn ->
          let rec cleanup () =
            match Atomic.get t with
            | (Val _ | Exn _ | Fun _) ->
              ()
            | Run waiters as before ->
              let after = Run (List.filter ((!=) dla.release) waiters) in
              if not (Atomic.compare_and_set t before after) then
                cleanup ()
          in
          cleanup ();
          raise cancelation_exn
      else
        force t
val force : 'a state Atomic.t -> 'a = <fun>
```

First `force` examines the state of the lazy computation. In case the result is
already known, the value is returned or the exception is raised. Otherwise
either the computation is started or the current thread of execution is
suspended using domain-local-await. Once the thunk returns, the lazy is updated
with the new state, any awaiters are released, and then all the `force` attempts
will retry to examine the result. Notice also that the above `force`
implementation is careful to perform a `cleanup` in case the `await` call raises
an exception, which indicates cancellation.

Let's then try it by creating a lazy computation and forcing it from two
different domains:

```ocaml
# let hello =
    from_fun (fun () ->
    Unix.sleepf 0.25;
    "Hello!")
val hello : string state Atomic.t = <abstr>

# let other = Domain.spawn (fun () -> force hello)
val other : string Domain.t = <abstr>

# force hello
- : string = "Hello!"

# Domain.join other
- : string = "Hello!"
```

Hello, indeed!

Note that the above implementation of lazy is intentionally kept relatively
simple. It could be optimized slightly to reduce allocations and proper
propagation of exception backtraces should be implemented. It could also be
useful to have a scheduler independent mechanism to get a unique id
corresponding to the current fiber, systhread, or domain and store that in the
lazy state to be able to give an error in case of recursive forcing.

## Example: Scheduler-friendly Mutex

At the time of writing this, the Stdlib `Mutex` implementation does not take
into account the possibility of having an effects based scheduler and simply
blocks the current domain (or (sys)thread) without giving a potential scheduler
the opportunity to schedule another fiber on the domain.

Let's build a draft of a scheduler-friendly mutex using atomics and
domain-local-await.

Here is a pair of types to represent a mutex:

```ocaml
type state =
  | Unlocked
  | Locked of (unit -> unit) list

type mutex = state Atomic.t
```

Essentially, a mutex is either unlocked or locked with a list of awaiters.

To construct a mutex we simply allocate a new atomic:

```ocaml
# let mutex () = Atomic.make Unlocked
val mutex : unit -> state Atomic.t = <fun>
```

The `unlock` operation just marks the mutex as unlocked and then wakes up all
the awaiters:

```ocaml
# let rec unlock t =
    match Atomic.exchange t Unlocked with
    | Unlocked -> invalid_arg "mutex: already unlocked"
    | Locked awaiters -> List.iter ((|>) ()) awaiters
val unlock : state Atomic.t -> unit = <fun>
```

The `lock` operation is more complex:

```ocaml
# let rec lock t =
    match Atomic.get t with
    | Unlocked ->
      if not (Atomic.compare_and_set t Unlocked (Locked [])) then
        lock t
    | Locked awaiters as before ->
      let dla = Domain_local_await.prepare_for_await () in
      let after = Locked (dla.release :: awaiters) in
      if Atomic.compare_and_set t before after then
        match dla.await () with
        | () -> lock t
        | exception cancellation_exn ->
          let rec cleanup () =
            match Atomic.get t with
            | Unlocked -> ()
            | Locked awaiters as before ->
              if List.for_all ((==) dla.release) awaiters then
                let after =
                  Locked (List.filter ((!=) dla.release) awaiters)
                in
                if not (Atomic.compare_and_set t before after) then
                  cleanup ()
          in
          cleanup ();
          raise cancellation_exn
      else
        lock t
val lock : state Atomic.t -> unit = <fun>
```

In case the mutex is already locked, domain-local-await is used to `await` until
the mutex is unlocked and the corresponding `release` is called. In case await
raises, `unlock` makes sure to remove the `release` operation from the mutex to
avoid a potential space leak.

Let's then use the mutex in a simple example of increment a counter from
multiple domains:

```ocaml
# let mutex = mutex ()
val mutex : state Atomic.t = <abstr>

# let counter = ref 0
val counter : int ref = {contents = 0}

# let domains = List.init 3 @@ fun _ ->
    Domain.spawn @@ fun () ->
    for _ = 1 to 10000 do
      lock mutex;
      incr counter;
      unlock mutex;
    done
val domains : unit Domain.t list = [<abstr>; <abstr>; <abstr>]

# List.iter Domain.join domains
- : unit = ()

# !counter
- : int = 30000
```

Note that, like with the previous lazy implementation, the above mutex
implementation is intentionally kept relatively simple and can be improved in
various ways. It would make sense to use a
[backoff](https://github.com/ocaml-multicore/backoff) in case of contention. The
representation could also be optimized to reduce memory usage. The above mutex
implementation is also unfair.

## Example: Awaitable atomic locations

As a second example, let's implement a simple awaitable atomic location
abstraction. An awaitable location contains both the current value of the
location and a list of awaiters, which are just `unit -> unit` functions:

```ocaml
type 'a awaitable_atomic = ('a * (unit -> unit) list) Atomic.t
```

The constructor of awaitable locations just pairs the initial value with an
empty list of awaiters:

```ocaml
# let awaitable_atomic v : _ awaitable_atomic = Atomic.make (v, [])
val awaitable_atomic : 'a -> 'a awaitable_atomic = <fun>
```

Operations that modify awaitable locations, like `fetch_and_add`, need to call
the awaiters to wake them up after a successful modification:

```ocaml
# let rec fetch_and_add x n =
    let (i, awaiters) as was = Atomic.get x in
      if Atomic.compare_and_set x was (i+n, []) then begin
          List.iter ((|>) ()) awaiters;
          i
        end
      else
        fetch_and_add x n
val fetch_and_add : (int * (unit -> unit) list) Atomic.t -> int -> int =
  <fun>
```

We can also have read-only operations, like `get_as`, that can be used to await
for an awaitable location to have a specific value:

```ocaml
# let rec get_as fn x =
    let (v, awaiters) as was = Atomic.get x in
    match fn v with
    | Some w -> w
    | None ->
      let dla = Domain_local_await.prepare_for_await () in
      if Atomic.compare_and_set x was (v, dla.release :: awaiters) then
        match dla.await () with
        | () -> get_as fn x
        | exception cancelation_exn ->
          let rec cleanup () =
            let (w, awaiters) as was = Atomic.get x in
            if v == w then
              let awaiters = List.filter ((!=) dla.release) awaiters in
              if not (Atomic.compare_and_set x was (w, awaiters))
              then cleanup ()
          in
          cleanup ();
          raise cancelation_exn
      else
        get_as fn x
val get_as : ('a -> 'b option) -> ('a * (unit -> unit) list) Atomic.t -> 'b =
  <fun>
```

Notice that we carefully cleaned up in case the `await` was canceled.

We could, of course, also have operations that potentially awaits for the
location to have an acceptable value before attempting modification. Let's leave
that as an exercise.

To test awaitable locations, let's first create a location:

```ocaml
# let x = awaitable_atomic 0
val x : int awaitable_atomic = <abstr>
```

And let's then create a thread that awaits until the value of the location has
changed and then modifies the value of the location:

```ocaml
# let a_thread =
    ()
    |> Thread.create @@ fun () ->
       get_as (fun x -> if x = 0 then None else Some ()) x;
       fetch_and_add x 21 |> ignore
val a_thread : Thread.t = <abstr>
```

The other thread is now awaiting for the initial modification:

```ocaml
# assert (0 = fetch_and_add x 21)
- : unit = ()
```

And we can await for the thread to perform its modification:

```ocaml
# get_as (fun x -> if x <> 21 then Some x else None) x;
- : int = 42
```

Let's then finish by joining with the other thread:

```ocaml
# Thread.join a_thread
- : unit = ()
```

## References

DLA is used to implement blocking operations by the following libraries:

- [Kcas](https://ocaml-multicore.github.io/kcas/)

DLA support is provided by the following schedulers:

- [Eio](https://github.com/ocaml-multicore/eio) <sup>(>= 0.10)</sup>
- [Domainslib](https://github.com/ocaml-multicore/domainslib) <sup>(>=
  0.5.1)</sup>
- [Moonpool](https://github.com/c-cube/moonpool) <sup>(>= 0.3)</sup>
