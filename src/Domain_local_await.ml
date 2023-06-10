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

module type Thread = sig
  type t

  val self : unit -> t
  val id : t -> int
end

type 'handle thread = (module Thread with type t = 'handle)

module IdMap = Map.Make (Int)

type config =
  | Per_domain : (unit -> t) -> config
  | Per_thread : {
      default : unit -> t;
      self : unit -> 'handle;
      id : 'handle -> int;
      mutable id_to_prepare : (unit -> t) IdMap.t;
          (** Accessed from a single domain, but multiple threads. *)
    }
      -> config

let key = Domain.DLS.new_key @@ fun () -> Per_domain (Default.init ())

let per_thread (type handle) ((module Thread) : handle thread) =
  match Domain.DLS.get key with
  | Per_thread _ ->
      failwith "Domain_local_await: per_thread called twice on a single domain"
  | Per_domain default ->
      let open Thread in
      let id_to_prepare = IdMap.empty in
      Domain.DLS.set key (Per_thread { default; self; id; id_to_prepare })

let using ~prepare_for_await ~while_running =
  match Domain.DLS.get key with
  | Per_domain _ as previous ->
      let current = Per_domain prepare_for_await in
      Domain.DLS.set key current;
      Fun.protect while_running ~finally:(fun () -> Domain.DLS.set key previous)
  | Per_thread r ->
      let id = r.id (r.self ()) in
      let rec add () =
        let before = r.id_to_prepare in
        let after = IdMap.add id prepare_for_await before in
        if r.id_to_prepare == before then r.id_to_prepare <- after else add ()
      in
      add ();
      let rec remove () =
        let before = r.id_to_prepare in
        let after = IdMap.remove id before in
        if r.id_to_prepare == before then r.id_to_prepare <- after
        else remove ()
      in
      Fun.protect while_running ~finally:remove

let prepare_for_await () =
  match Domain.DLS.get key with
  | Per_domain default -> default ()
  | Per_thread r -> (
      match IdMap.find (r.id (r.self ())) r.id_to_prepare with
      | prepare -> prepare ()
      | exception Not_found -> r.default ())
