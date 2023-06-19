type t = { release : unit -> unit; await : unit -> unit }

module Default = struct
  type t = { mutex : Mutex.t; condition : Condition.t }

  let init () =
    let t =
      let mutex = Mutex.create () and condition = Condition.create () in
      { mutex; condition }
    in
    fun () ->
      let released = ref false in
      let release () =
        if not !released then (
          Mutex.lock t.mutex;
          if not !released then (
            released := true;
            Mutex.unlock t.mutex;
            Condition.broadcast t.condition)
          else Mutex.unlock t.mutex)
      and await () =
        if not !released then (
          Mutex.lock t.mutex;
          while not !released do
            Condition.wait t.condition t.mutex
          done;
          Mutex.unlock t.mutex)
      in
      { release; await }
end

include Thread_intf

type config =
  | Per_domain : { mutable prepare_for_await : unit -> t } -> config
  | Per_thread : {
      mutable prepare_for_await : unit -> t;
      self : unit -> 'handle;
      id : 'handle -> int;
      id_to_prepare : (unit -> t) Thread_table.t;
    }
      -> config

let default_init = ref (fun () -> failwith "unimplemented")
let default () = !default_init ()

let key =
  Domain.DLS.new_key @@ fun () -> Per_domain { prepare_for_await = default }

(* Below we use [@poll error] to ensure that there are no safe-points where
   thread switches might occur during critical section. *)

let[@poll error] update_prepare_atomically state prepare_for_await =
  match state with
  | Per_domain r ->
      let current = r.prepare_for_await in
      if current == default then begin
        r.prepare_for_await <- prepare_for_await;
        prepare_for_await
      end
      else current
  | Per_thread r ->
      let current = r.prepare_for_await in
      if current == default then begin
        r.prepare_for_await <- prepare_for_await;
        prepare_for_await
      end
      else current

let () =
  default_init :=
    fun () ->
      let prepare_for_await = Default.init () in
      let prepare_for_await =
        update_prepare_atomically (Domain.DLS.get key) prepare_for_await
      in
      prepare_for_await ()

let per_thread ((module Thread) : (module Thread)) =
  match Domain.DLS.get key with
  | Per_thread _ ->
      failwith "Domain_local_await: per_thread called twice on a single domain"
  | Per_domain { prepare_for_await } ->
      let open Thread in
      let id_to_prepare = Thread_table.create () in
      Domain.DLS.set key
        (Per_thread { prepare_for_await; self; id; id_to_prepare })

let using ~prepare_for_await ~while_running =
  match Domain.DLS.get key with
  | Per_domain _ as previous ->
      let current = Per_domain { prepare_for_await } in
      Domain.DLS.set key current;
      Fun.protect while_running ~finally:(fun () -> Domain.DLS.set key previous)
  | Per_thread r ->
      let id = r.id (r.self ()) in
      Thread_table.add r.id_to_prepare id prepare_for_await;
      Fun.protect while_running ~finally:(fun () ->
          Thread_table.remove r.id_to_prepare id)

let prepare_for_await () =
  match Domain.DLS.get key with
  | Per_domain r -> r.prepare_for_await ()
  | Per_thread r -> (
      match Thread_table.find r.id_to_prepare (r.id (r.self ())) with
      | prepare -> prepare ()
      | exception Not_found -> r.prepare_for_await ())
