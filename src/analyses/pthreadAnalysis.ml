(** Tracking of pthread lib code. Output to promela. *)

open Prelude.Ana
open Analyses
open Cil
open Deriving.Cil
open BatteriesExceptionless

(** [Function] module represents the supported pthread functions for the analysis *)
module Function = struct
  type t =
    | ThreadCreate
    | ThreadJoin
    | MutexInit
    | MutexLock
    | MutexUnlock
    | Other of string

  let prefix = "pthread_"

  let supported =
    List.map
      (( ^ ) prefix)
      [ "create"; "join"; "mutex_init"; "mutex_lock"; "mutex_unlock" ]


  let is_pthread_fun f = String.starts_with f prefix

  let from_string = function
    | "pthread_create" ->
        ThreadCreate
    | "pthread_join" ->
        ThreadJoin
    | "pthread_mutex_init" ->
        MutexInit
    | "pthread_mutex_lock" ->
        MutexLock
    | "pthread_mutex_unlock" ->
        MutexUnlock
    | s ->
        Other s
end

(** [Resource] module represts different resources extracted for the analysis *)
module Resource = struct
  (** Enumeration of all resources relevant for the analysis *)
  type resource_type =
    | Thread
    | Function
    | Mutex
  [@@deriving show]

  (** name of the resource in code *)
  type resource_name = string

  (** type [t] represents the resource *)
  type t = resource_type * resource_name

  let make t n : t = (t, n)

  let res_type = fst

  let res_name = snd

  let show t =
    let str_res_type = show_resource_type @@ res_type t in
    let str_res_name = res_name t in
    str_res_type ^ ":" ^ str_res_name
end

module Action = struct
  type thread =
    { t : varinfo  (** a global var from Tbls.ResourceTbl *)
    ; f : varinfo  (** a function being called *)
    ; tid : int
    ; pri : int
          (* TODO: extract this info from the thread attributes *)
          (* TODO: have a list of args to pass?*)
          (* ; args : varinfo list *)
    }

  type mutex = { m : varinfo }

  (** uniquely identifies the function call
   ** created/defined by `fun_ctx` function *)
  type fun_call_id = string

  (** ADT of all possible edge types actions *)
  type t =
    (* | Assign of string * string (\* var_callee = var_caller *\) *)
    | Call of fun_call_id
    | ThreadCreate of thread
    | ThreadJoin of int (* tid *)
    | MutexInit of mutex
    | MutexLock (*TODO: add associated args for it*)
    | MutexUnlock (*TODO: add associated args for it*)
    | Nop
end

type thread_name = string

type fun_name = string

(** type of a node in CFG *)
type node = PthreadDomain.Pred.Base.t

(** type of a single edge in CFG *)
type edge = node * Action.t * string option * node

module Tbls = struct
  module type SymTblGen = sig
    type k

    type v

    val make_new_val : (k, v) Hashtbl.t -> k -> v
  end

  module type TblGen = sig
    type k

    type v
  end

  module SymTbl (G : SymTblGen) = struct
    let table = (Hashtbl.create 123 : (G.k, G.v) Hashtbl.t)

    let get k =
      (* in case there is no value for the key, populate the table with the next value (id) *)
      let new_value_thunk () =
        let new_val = G.make_new_val table k in
        Hashtbl.replace table k new_val ;
        new_val
      in
      Hashtbl.find table k |> Option.default_delayed new_value_thunk


    let get_key v =
      table |> Hashtbl.filter (( = ) v) |> Hashtbl.keys |> Enum.get


    let to_list () = table |> Hashtbl.enum |> List.of_enum
  end

  module Tbl (G : TblGen) = struct
    let table = (Hashtbl.create 123 : (G.k, G.v) Hashtbl.t)

    let add k v = Hashtbl.replace table k v

    let get k = Hashtbl.find table k

    let get_key v = table |> Hashtbl.enum |> List.of_enum |> List.assoc_inv v
  end

  let all_keys_count table =
    table |> Hashtbl.keys |> List.of_enum |> List.length


  module ResourceTbl = SymTbl (struct
    type k = Resource.t

    type v = varinfo

    let make_new_val table k =
      let var_name = Resource.show k in
      (* creates a global var for resource with the unique var name of type void* *)
      Goblintutil.create_var (makeGlobalVar var_name voidPtrType)
  end)

  module ThreadPrioTbl = Tbl (struct
    type k = thread_name

    type v = int64
  end)

  module ThreadTidTbl = SymTbl (struct
    type k = thread_name

    type v = int

    let make_new_val table k = all_keys_count table
  end)

  (* context hash to differentiate function calls *)
  module CtxTbl = SymTbl (struct
    type k = int

    type v = int

    let make_new_val table k = all_keys_count table
  end)

  module FunTbl = SymTbl (struct
    type k = string * string (* TODO: what do they represent *)

    type v = int

    let make_new_val table k = all_keys_count table
  end)
end

let _ = Tbls.ThreadTidTbl.get "mainfun"

let fun_ctx ctx f =
  let ctx_hash =
    match PthreadDomain.Ctx.to_int ctx with
    | Some i ->
        i |> i64_to_int |> Tbls.CtxTbl.get |> string_of_int
    | None ->
        "TOP"
  in
  f.vname ^ "_" ^ ctx_hash


module Tasks = SetDomain.Make (Lattice.Prod (Queries.LS) (PthreadDomain.D))

module rec Env : sig
  type t

  val get : (PthreadDomain.D.t, Tasks.t, PthreadDomain.D.t) ctx -> t

  val d : t -> PthreadDomain.D.t

  val node : t -> MyCFG.node

  val id : t -> Resource.t
end = struct
  type t =
    { d : PthreadDomain.D.t
    ; node : MyCFG.node
    ; fundec : fundec
    ; thread_name : thread_name
    ; id : Resource.t
    }

  let get ctx =
    let d : PthreadDomain.D.t = ctx.local in
    let node = Option.get !MyCFG.current_node in
    (* let curpid = match Pid.to_int d.pid with Some i -> i | None -> failwith @@ "get_env: Pid.to_int = None inside function "^fundec.svar.vname^". State: " ^ D.short 100 d in
     * let pname = match get_by_pid curpid with Some s -> s | None -> failwith @@ "get_env: no processname for pid in Hashtbl!" in
     * let procid = Process, pname in
     * let pfuns = funs_for_process (Process,pname) in *)
    (* determine if we are at the root of a thread or in some called function *)
    let fundec = MyCFG.getFun node in
    let cur_tid =
      Int64.to_int @@ Option.get @@ PthreadDomain.Tid.to_int d.tid
    in
    let thread_name = Option.get @@ Tbls.ThreadTidTbl.get_key cur_tid in
    let id =
      let is_main_fun name =
        List.mem name @@ List.map Json.string @@ GobConfig.get_list "mainfun"
      in
      let funs_of_thread = Edges.funs_for_thread thread_name in
      let open Resource in
      if List.exists (( = ) fundec.svar) funs_of_thread
         || is_main_fun fundec.svar.vname
      then Resource.make Thread thread_name
      else Resource.make Function (fun_ctx d.ctx fundec.svar)
    in
    { d; node; fundec; thread_name; id }


  let d env = env.d

  let node env = env.node

  let id env = env.id
end

and Edges : sig
  val table : (Resource.t, edge Set.t) Hashtbl.t

  val add :
       ?r:string
    -> ?dst:Node.node
    -> ?d:PthreadDomain.D.t
    -> Env.t
    -> Action.t
    -> unit

  val get : Resource.t -> edge Set.t

  val filter_map_actions : (Action.t -> 'a option) -> 'a list

  val funs_for_thread : thread_name -> varinfo list
end = struct
  let table = Hashtbl.create 199

  (** [add] adds an edge for the current environment resource id (Thread or Function)
   ** [r] is return status code
   ** [dst] destination node
   ** [d] domain
   ** [env] environment
   ** [action] edge action of type `Action.t` *)
  let add ?r ?dst ?d env action =
    let open PthreadDomain in
    let preds =
      let env_d = Env.d env in
      (d |? env_d).pred
    in
    let add_edge_for_node node =
      let env_node = Env.node env in
      let env_id = Env.id env in
      let action_edge = (node, action, r, MyCFG.getLoc (dst |? env_node)) in
      Hashtbl.modify_def Set.empty env_id (Set.add action_edge) table
    in
    Pred.iter add_edge_for_node preds


  let get res_id = Hashtbl.find_default table res_id Set.empty

  let filter_map_actions f =
    let action_of_edge (_, action, _, _) = action in
    let all_edges =
      table
      |> Hashtbl.values
      |> List.of_enum
      |> List.map Set.elements
      |> List.concat
    in
    List.filter_map (f % action_of_edge) all_edges


  let funs_for_thread thread_name =
    let open Action in
    let get_funs = function
      | ThreadCreate t when t.f.vname = thread_name ->
          Some t.f
      | _ ->
          None
    in
    filter_map_actions get_funs |> List.unique
end

(** promela source code *)
type promela_src = string

let promela_main : fun_name = "mainfun"

module Codegen = struct
  module Resource = struct
    include Resource

    let to_pml = function
      | Thread, "mainfun" ->
          promela_main
          ^ "/["
          ^ String.concat
              ", "
              (List.map Json.string (GobConfig.get_list promela_main))
          ^ "]"
      | Thread, name ->
          name (* name ^ "/" ^ str_funs @@ funs_for_process id *)
      | _, name ->
          name
  end

  module PmlResTbl = struct
    let table = Hashtbl.create 13

    let init () = Hashtbl.add table (Resource.Thread, promela_main) 0L

    let get_id res : int64 =
      let ((resource, name) as k) = res in
      match Hashtbl.find table k with
      | None ->
          let ids =
            Hashtbl.filteri (fun (r, n) v -> r = resource) table
            |> Hashtbl.values
          in
          let res =
            if Enum.is_empty ids
            then 0L
            else Int64.succ (Enum.arg_max identity ids)
          in
          Hashtbl.replace table k res ;
          res
      | Some x ->
          x


    let show_id_for_res = Int64.to_string % get_id

    let show_prefixed_id_for_res res =
      let prefix =
        (* thread or function *)
        if Resource.res_type res = Resource.Thread then "T" else "F"
      in
      prefix ^ show_id_for_res res
  end

  module Action = struct
    include Action

    let extract_thread_create = function ThreadCreate x -> Some x | _ -> None

    let extract_mutex_init = function MutexInit x -> Some x | _ -> None

    let to_pml res = function
      | ThreadCreate t ->
          "ThreadCreate("
          ^ show_varinfo t.f
          (* ^ "," *)
          (* pass args to the thread instantiation *)
          ^ "); \n"
      | ThreadJoin tid ->
          "ThreadJoin(" ^ string_of_int tid ^ "); \n"
      | _ ->
          ""
  end

  module ReturnVarsTbl = struct
    (* this is just used to make sure that every var that is read has been written before *)
    let return_vars =
      ( Hashtbl.create 100
        : (Resource.t * [ `Read | `Write ], string Set.t) Hashtbl.t )


    let add_return_var pid kind var =
      Hashtbl.modify_def Set.empty (pid, kind) (Set.add var) return_vars


    let get_return_vars pid kind =
      if fst pid <> Resource.Thread
      then
        failwith
          "get_return_vars: tried to get var for Function, but vars are saved \
           per Thread!"
      else Hashtbl.find_default return_vars (pid, kind) Set.empty


    let decl_return_vars xs =
      Set.elements xs |> List.map (fun vname -> "mtype " ^ vname ^ ";")


    let is_global = startsWith "G"

    let get_locals pid =
      Set.union (get_return_vars pid `Read) (get_return_vars pid `Write)
      |> Set.filter (neg is_global)
      |> decl_return_vars


    let get_globals () =
      let flatten_set xs = Set.fold Set.union xs Set.empty in
      return_vars
      |> Hashtbl.values
      |> Set.of_enum
      |> flatten_set
      |> Set.filter is_global
      |> decl_return_vars
  end

  module Writer = struct
    let write_result desc content =
      let dir = Goblintutil.create_dir "result" in
      let path = dir ^ "/pthread.pml" in
      output_file path content ;
      print_endline @@ "saved " ^ desc ^ " as " ^ path
  end

  let tabulate = ( ^ ) "\t"

  let _ = PmlResTbl.init ()

  let save_promela_model () =
    let threads =
      List.unique @@ Edges.filter_map_actions Action.extract_thread_create
    in
    let mutexes =
      List.unique @@ Edges.filter_map_actions Action.extract_mutex_init
    in

    let thread_count = List.length threads + 1 in
    let mutex_count = List.length mutexes in

    (* let run_threads =
     *   let open Action in
     *   let run_command x = "run " ^ x ^ "();" in
     *   List.map (fun t -> run_command t.f.vname) threads
     * in *)
    let init_body =
      [ "preInit;"
      ; "run " ^ promela_main ^ "(0);"
      ; "postInit();"
      ; "run monitor();"
      ]
    in

    let current_thread_name = ref "" in
    let called_funs_done = ref Set.empty in

    let rec process_def res =
      let string_of_node = PthreadDomain.Pred.string_of_elt in

      let res_type = Resource.res_type res in
      let res_name = Resource.res_name res in
      let is_thread = res_type = Resource.Thread in
      (* if we already generated code for this function, we just return [] *)
      if res_type = Resource.Function && Set.mem res_name !called_funs_done
      then []
      else
        (* res is type*name, res_id is int64 (starting from 0 for each type of resource) *)
        let res_id = PmlResTbl.get_id res in
        let pref_res_id = PmlResTbl.show_prefixed_id_for_res res in

        (* set the name of the current thread
         * (this function is also run for functions, which need a reference to the thread for checking branching on return vars)
         * TODO: but why was it so? for a process we start with no called functions, for a function we add its name *)
        if is_thread
        then (
          current_thread_name := res_name ;
          called_funs_done := Set.empty )
        else called_funs_done := Set.add res_name !called_funs_done ;

        (* build adjacency matrix for all nodes of this process *)
        let module HashtblN = Hashtbl.Make (PthreadDomain.Pred.Base) in
        let a2bs = HashtblN.create 97 in
        let get_a (a, _, _, _) = a in
        let get_b (_, _, _, b) = b in
        let edges = Edges.get res in
        Set.iter
          (fun ((a, _, _, b) as edge) ->
            HashtblN.modify_def Set.empty a (Set.add edge) a2bs)
          edges ;

        let nodes = HashtblN.keys a2bs |> List.of_enum in
        let out_edges node =
          try HashtblN.find a2bs node |> Set.elements with Not_found -> []
        in
        let in_edges node =
          HashtblN.filter (Set.mem node % Set.map get_b) a2bs
          |> HashtblN.values
          |> List.of_enum
          |> flat_map Set.elements
        in
        let is_end_node = List.is_empty % out_edges in
        (* node with no incoming edges is the start node *)
        let is_start_node = List.is_empty % in_edges in

        let start_node = Option.get @@ List.find is_start_node nodes in
        let label n = pref_res_id ^ "_" ^ string_of_node n in
        let end_label = pref_res_id ^ "_end" in
        let goto node = "goto " ^ label node in

        let called_funs = ref [] in

        let str_edge (a, action, r, b) =
          let target_label = if is_end_node b then end_label else label b in
          let mark =
            let open Action in
            match action with
            | Call fun_name ->
                called_funs := fun_name :: !called_funs ;
                let pc =
                  string_of_int @@ Tbls.FunTbl.get (fun_name, target_label)
                in
                "mark(" ^ pc ^ "); "
            | _ ->
                ""
          in
          (* for function calls the goto will never be reached since the function's return will already jump to that label; however it's nice to see where the program will continue at the site of the call. *)
          mark
          ^ Action.to_pml (Resource.Thread, !current_thread_name) action
          ^ "goto "
          ^ target_label
        in

        let walk_edges (a, out_edges) =
          let edges = Set.elements out_edges |> List.map str_edge in
          let body =
            if List.length edges > 1
            then
              (* choices in if-statements are prefixed with :: *)
              let prefix_branch x = "::" ^ tabulate x in
              let if_branches = List.map prefix_branch edges in
              [ "if" ] @ if_branches @ [ "fi" ]
            else edges
          in
          (label a ^ ":") :: body
        in

        let locals = if is_thread then ReturnVarsTbl.get_locals res else [] in

        let body =
          locals
          @ goto start_node
            :: flat_map walk_edges (HashtblN.enum a2bs |> List.of_enum)
          @ [ ( end_label
              ^ ":"
              ^
              if is_thread
              then " status[res] = DONE"
              else " ret_" ^ snd res ^ "()" )
            ]
        in

        let head =
          let open Action in
          match res with
          | Thread, name ->
              let thread =
                let find_option f xs =
                  try Some (List.find f xs) with Not_found -> None
                in
                find_option (fun t -> t.f.vname = name) threads
              in
              (* None for mainfun *)
              let priority =
                match thread with
                | Some thread ->
                    " priority " ^ "1"
                    (* TODO: add later Int64.to_string thread.pri *)
                | _ ->
                    ""
              in
              "proctype "
              ^ name
              ^ "(byte res)"
              ^ priority
              ^ " provided (canRun("
              ^ Int64.to_string res_id
              ^ ") PRIO"
              ^ Int64.to_string res_id
              ^ ") {\n\tint stack[20]; int sp = -1;"
          | Function, name ->
              "Fun_" ^ name ^ ":"
          | _ ->
              failwith
                "Only Thread and Function are allowed as keys for collecting \
                 Pthread actions"
        in

        let called_fun_ids =
          List.map (fun fname -> (Resource.Function, fname)) !called_funs
        in

        let funs = flat_map process_def called_fun_ids in
        ("" :: head :: List.map tabulate body)
        @ funs
        @ [ (if is_thread then "}" else "") ]
    in

    (* used for macros oneIs, allAre, noneAre... *)
    let checkStatus =
      "("
      ^ ( String.concat " op2 "
        @@ List.of_enum
        @@ (0 --^ thread_count)
           /@ fun i -> "status[" ^ string_of_int i ^ "] op1 v" )
      ^ ")"
    in

    let allTasks =
      "("
      ^ ( String.concat " && "
        @@ List.of_enum
        @@ ((0 --^ thread_count) /@ fun i -> "prop(" ^ string_of_int i ^ ")") )
      ^ ")"
    in

    (* sort definitions so that inline functions come before the threads *)
    let process_defs =
      Edges.table
      |> Hashtbl.keys
      |> List.of_enum
      |> List.filter (fun res -> Resource.res_type res = Resource.Thread)
      |> (fun xs ->
           List.iter (fun x -> print_endline @@ Resource.show x) xs ;
           xs)
      |> List.sort (compareBy PmlResTbl.show_prefixed_id_for_res)
      |> flat_map process_def
    in

    let promela =
      String.concat "\n"
      @@ ("#define thread_count " ^ string_of_int thread_count)
         :: ("#define mutex_count " ^ string_of_int mutex_count)
         :: ""
         :: ("#define checkStatus(op1, v, op2) " ^ checkStatus)
         :: ""
         :: ("#define allTasks(prop) " ^ allTasks)
         :: ""
         :: "#include \"pthread.base.pml\""
         :: ""
         :: "init {"
         :: List.map tabulate init_body
      @ "}"
        :: ""
        :: ( List.of_enum
           @@ ((0 --^ thread_count) /@ fun i -> "#define PRIO" ^ string_of_int i)
           )
      (* @ ("#ifdef PRIOS" :: prios) *)
      (* @ ("#endif" :: "" :: fun_mappings) *)
      @ ("" :: ReturnVarsTbl.get_globals ())
      @ process_defs
    in
    Writer.write_result "promela model" promela ;
    print_endline
      "Copy spin/pthread_base.pml to same folder and then do: spin -a \
       pthread.pml && cc -o pan pan.c && ./pan"

  (* print_endline @@ "Model saved as " ^ path ;
     * print_endline "Run ./spin/check.sh to verify." *)

  (* generate priority based running constraints for each process (only used ifdef PRIOS):
     *  process can only run if no higher prio process is ready *)
  (*FIXME: DO IT *)
  (* let prios =
   *   let def thread =
   *     let res = show_id_for_res thread.pid in
   *     let pri = thread.pri in
   *     let higher = List.filter (fun x -> x.pri > pri) procs in
   *     if List.is_empty higher
   *     then None
   *     else
   *       Some
   *         ( "#undef PRIO"
   *         ^ res
   *         ^ "\n#define PRIO"
   *         ^ res
   *         ^ String.concat ""
   *         @@ List.map
   *              (fun x -> " && status[" ^ show_id_for_res x.pid ^ "] != READY")
   *              higher )
   *   in
   *   List.filter_map def procs
   * in *)

  (* FIXME: DO IT *)
  (* let fun_mappings =
   *   let fun_map xs =
   *     if List.is_empty xs
   *     then []
   *     else
   *       let (name, _), _ = List.hd xs in
   *       let entries =
   *         xs
   *         |> List.map (fun ((_, k), v) ->
   *                "\t:: (stack[sp] == "
   *                ^ string_of_int v
   *                ^ ") -> sp--; goto "
   *                ^ k
   *                ^ " \\")
   *       in
   *       (("#define ret_" ^ name ^ "() if \\") :: entries) @ [ "fi" ]
   *   in
   *   FunTbl.to_list ()
   *   |> List.group (compareBy (fst % fst))
   *   |> flat_map fun_map
   * in *)
end

module Spec : Analyses.Spec = struct
  module M = Messages
  module List = BatList

  (* Spec implementation *)
  include Analyses.DefaultSpec

  (** Domains *)
  include PthreadDomain

  (* TODO: what is C, Context? *)
  module C = D

  (** Set of created tasks to spawn when going multithreaded *)
  module Tasks = SetDomain.Make (Lattice.Prod (Queries.LS) (D))

  (* TODO: what is G *)
  module G = Tasks

  let tasks_var =
    Goblintutil.create_var (makeGlobalVar "__GOBLINT_PTHREAD_TASKS" voidPtrType)


  let name () = "pthread_to_promela"

  let init () = LibraryFunctions.add_lib_funs Function.supported

  (*TODO: implement non "assume_success" scenario *)
  let assign ctx (lval : lval) (rval : exp) : D.t = ctx.local

  (*TODO: implement non "assume_success" scenario *)
  let branch ctx (exp : exp) (tv : bool) : D.t = ctx.local

  let body ctx (f : fundec) : D.t =
    (* enter is not called for spawned threads -> initialize them here *)
    let context_hash =
      let base_context =
        Base.Main.context_cpa @@ Obj.obj @@ List.assoc "base" ctx.presub
      in
      Int64.of_int @@ Hashtbl.hash (base_context, ctx.local.tid)
    in
    { ctx.local with ctx = Ctx.of_int context_hash }


  let return ctx (exp : exp option) (f : fundec) : D.t = ctx.local

  let enter ctx (lval : lval option) (f : varinfo) (args : exp list) :
      (D.t * D.t) list =
    (* on function calls (also for main); not called for spawned processes *)
    let d_caller = ctx.local in
    let d_callee =
      if D.is_bot ctx.local
      then ctx.local
      else
        { ctx.local with
          pred = Pred.of_node (MyCFG.Function f)
        ; ctx = Ctx.top ()
        }
    in
    (* set predecessor set to start node of function *)
    [ (d_caller, d_callee) ]


  let combine
      ctx
      (lval : lval option)
      fexp
      (f : varinfo)
      (args : exp list)
      fc
      (au : D.t) : D.t =
    if D.any_is_bot ctx.local || D.any_is_bot au
    then ctx.local
    else
      let d_caller = ctx.local in
      let d_callee = au in
      (* check if the callee has some relevant edges, i.e. advanced from the entry point
       * if not, we generate no edge for the call and keep the predecessors from the caller *)
      (* set should never be empty *)
      if Pred.is_bot d_callee.pred then failwith "d_callee.pred is bot!" ;
      if Pred.equal d_callee.pred @@ Pred.of_node @@ MyCFG.Function f
      then
        (* set current node as new predecessor, since something interesting happend during the call *)
        { d_callee with pred = d_caller.pred; ctx = d_caller.ctx }
      else
        let env = Env.get ctx in
        (* write out edges with call to f coming from all predecessor nodes of the caller *)
        ( if Ctx.is_int d_callee.ctx
        then
          let last_pred = d_caller.pred in
          let action = Action.Call (fun_ctx d_callee.ctx f) in
          Edges.add ~d:{ d_caller with pred = last_pred } env action ) ;

        (* set current node as new predecessor, since something interesting happend during the call *)
        { d_callee with
          pred = Pred.of_node @@ Env.node env
        ; ctx = d_caller.ctx
        }


  module ExprEval = struct
    let eval_int ctx exp =
      match ctx.ask (Queries.EvalInt exp) with
      | `Int x ->
          Int64.to_int x
      | _ ->
          failwith @@ "Could not evaluate int-argument " ^ sprint d_plainexp exp


    let eval_str ctx exp =
      match ctx.ask (Queries.EvalStr exp) with
      | `Str x ->
          x
      | _ ->
          failwith
          @@ "Could not evaluate string-argument "
          ^ sprint d_plainexp exp


    let eval_id ctx exp =
      let mayPointTo ctx exp =
        match ctx.ask (Queries.MayPointTo exp) with
        | `LvalSet a
          when (not (Queries.LS.is_top a)) && Queries.LS.cardinal a > 0 ->
            let top_elt = (dummyFunDec.svar, `NoOffset) in
            let a' =
              if Queries.LS.mem top_elt a
              then (
                M.debug_each
                @@ "mayPointTo: query result for "
                ^ sprint d_exp exp
                ^ " contains TOP!" ;
                (* UNSOUND *)
                Queries.LS.remove top_elt a )
              else a
            in
            Queries.LS.elements a'
        | `Bot ->
            []
        | v ->
            M.debug_each
            @@ "mayPointTo: query result for "
            ^ sprint d_exp exp
            ^ " is "
            ^ sprint Queries.Result.pretty v ;
            []
      in
      mayPointTo ctx exp
      |> List.map (Option.get % Tbls.ResourceTbl.get_key % fst)
  end

  module Assign = struct
    let id ctx exp id =
      match exp with
      | AddrOf lval ->
          ctx.assign ~name:"base" lval (mkAddrOf @@ var id)
      | _ ->
          failwith
          @@ "Could not assign id. Expected &id. Found "
          ^ sprint d_exp exp


    let id_by_name ctx resource_type name exp =
      id
        ctx
        exp
        (Tbls.ResourceTbl.get (resource_type, ExprEval.eval_str ctx name))
  end

  let special ctx (lval : lval option) (f : varinfo) (arglist : exp list) : D.t
      =
    let fun_name = f.vname in
    let not_pthread_fun = not @@ Function.is_pthread_fun fun_name in
    if D.any_is_bot ctx.local || not_pthread_fun
    then ctx.local
    else
      let arglist = List.map (stripCasts % constFold false) arglist in
      let add_actions (actions : Action.t list) =
        let env = Env.get ctx in
        let d = Env.d env in
        List.iter (Edges.add env) actions ;
        if List.is_empty actions
        then d
        else { d with pred = Pred.of_node @@ Env.node env }
      in
      let add_action action = add_actions [ action ] in
      let pthread_fun = Function.from_string fun_name in
      let open Function in
      match (pthread_fun, arglist) with
      (* NOTE: thread_attr or fun_args can be nil/0 *)
      | ThreadCreate, [ AddrOf thread; thread_attr; AddrOf func; fun_arg ] ->
          (* TODO: take into consideration thread attributes, like prio *)
          let pri = 0 in
          let funs_ls =
            let ls =
              let start_routine =
                ctx.ask (Queries.ReachableFrom (AddrOf func))
              in
              match start_routine with `LvalSet ls -> ls | _ -> failwith ""
            in
            Queries.LS.filter
              (fun (v, o) ->
                let lval = (Var v, Lval.CilLval.to_ciloffs o) in
                isFunctionType (typeOfLval lval))
              ls
          in
          let funs =
            funs_ls |> Queries.LS.elements |> List.map fst |> List.unique
          in

          let _ = List.iter (print_endline % show_varinfo) funs in

          (* NOTE: thread name is not unique! *)
          let thread_name = (List.hd funs).vname in
          let thread_goblint_var =
            let thread_res = Resource.make Resource.Thread thread_name in
            Tbls.ResourceTbl.get thread_res
          in

          (* TODO: what's the point of the whole assign thingy?
           *       assign, such that we can later eval it?
           *       then we need to assign the value from code and not goblint_global_var *)
          Assign.id ctx (AddrOf thread) thread_goblint_var ;

          let tid = Tbls.ThreadTidTbl.get thread_name in
          (* create new task for the new thread created *)
          (* TODO: why? why do we need tasks for *)
          let tasks =
            let f_d =
              { tid = tid |> Int64.of_int |> Tid.of_int
              ; pri = Pri.of_int @@ Int64.of_int pri
              ; pred = Pred.of_node (MyCFG.Function f)
              ; ctx = Ctx.top ()
              }
            in

            Tasks.add (funs_ls, f_d) (ctx.global tasks_var)
          in
          ctx.sideg tasks_var tasks ;

          let thread_create f =
            Action.ThreadCreate Action.{ t = thread_goblint_var; f; tid; pri }
          in
          add_actions @@ List.map thread_create funs
      | ThreadJoin, [ thread; thread_ret ] ->
          (* TODO: take into consideration the return value of thread join *)
          (* TODO: read from the rendezvouz message channel in order to block the execution? *)
          let potential_thread_resources = ExprEval.eval_id ctx thread in

          let thread_join_for_res res =
            let tid =
              match res with
              | Resource.Thread, thread_name ->
                  Tbls.ThreadTidTbl.get thread_name
              | _ ->
                  failwith "No tid is associated with this thread"
            in
            Action.ThreadJoin tid
          in
          add_actions @@ List.map thread_join_for_res potential_thread_resources
      | MutexInit, [ AddrOf mutex; AddrOf mutex_attr ] ->
          add_action Nop (* TODO: add_action (MutexInit mutex) *)
      | MutexLock, [ AddrOf mutex ] ->
          add_action MutexLock
      | MutexUnlock, [ AddrOf mutex ] ->
          add_action MutexUnlock
      | _ ->
          add_action Nop


  let startstate v =
    let open D in
    make
      (Tid.of_int 0L)
      (Pri.top ())
      (Pred.of_node (MyCFG.Function (emptyFunction "main").svar))
      (Ctx.top ())


  let otherstate v = D.bot ()

  let exitstate v = D.bot ()

  let finalize = Codegen.save_promela_model
end

let _ = MCP.register_analysis ~dep:[ "base" ] (module Spec : Spec)
