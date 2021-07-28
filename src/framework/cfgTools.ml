open MyCFG
open Cil
open Pretty
open GobConfig

module H = NodeH
module NH = NodeH


(* TODO: refactor duplication with find_loop_heads *)
module NS = Set.Make (Node)
let find_loop_heads_fun (module Cfg:CfgForward) (fd:Cil.fundec): unit NH.t =
  let loop_heads = NH.create 100 in
  let global_visited_nodes = NH.create 100 in

  (* DFS *)
  let rec iter_node path_visited_nodes node =
    if NS.mem node path_visited_nodes then
      NH.add loop_heads node ()
    else if not (NH.mem global_visited_nodes node) then begin
      NH.add global_visited_nodes node ();
      let new_path_visited_nodes = NS.add node path_visited_nodes in
      List.iter (fun (_, to_node) ->
          iter_node new_path_visited_nodes to_node
        ) (Cfg.next node)
    end
  in

  let entry_node = FunctionEntry fd in
  iter_node NS.empty entry_node;

  loop_heads

let find_backwards_reachable (module Cfg:CfgBackward) (node:node): unit NH.t =
  let reachable = NH.create 100 in

  (* DFS, copied from Control is_sink *)
  let rec iter_node node =
    if not (NH.mem reachable node) then begin
      NH.replace reachable node ();
      List.iter (fun (_, prev_node) ->
          iter_node prev_node
        ) (Cfg.prev node)
    end
  in

  iter_node node;
  reachable


let rec pretty_edges () = function
  | [] -> Pretty.dprintf ""
  | [_,x] -> Edge.pretty_plain () x
  | (_,x)::xs -> Pretty.dprintf "%a; %a" Edge.pretty_plain x pretty_edges xs


let createCFG (file: file) =
  let cfgF = H.create 113 in
  let cfgB = H.create 113 in
  if Messages.tracing then Messages.trace "cfg" "Starting to build the cfg.\n\n";

  let addEdges fromNode edges toNode =
    if Messages.tracing then
      Messages.trace "cfg" "Adding edges [%a] from\n\t%a\nto\n\t%a ... "
        pretty_edges edges
        Node.pretty_plain_short fromNode
        Node.pretty_plain_short toNode;
    H.add cfgB toNode (edges,fromNode);
    H.add cfgF fromNode (edges,toNode);
    Messages.trace "cfg" "done\n\n"
  in
  let addEdge fromNode edge toNode = addEdges fromNode [edge] toNode in
  let addEdge_fromLoc fromNode edge toNode = addEdge fromNode (Node.location fromNode, edge) toNode in

  (* Find real (i.e. non-empty) successor of statement.
     CIL CFG contains some unnecessary intermediate statements.
     If stmt is succ of parent, then optional argument parent must be passed
     to also detect cycle ending with parent itself.
     If not_found is true, then a stmt without succs will raise Not_found
     instead of returning that stmt. *)
  let find_real_stmt ?parent ?(not_found=false) stmt =
    if Messages.tracing then Messages.tracei "cfg" "find_real_stmt not_found=%B stmt=%d\n" not_found stmt.sid;
    let rec find visited_sids stmt =
      if Messages.tracing then Messages.trace "cfg" "find_real_stmt visited=[%a] stmt=%d: %a\n" (d_list "; " (fun () x -> Pretty.text (string_of_int x))) visited_sids stmt.sid dn_stmt stmt;
      if List.mem stmt.sid visited_sids then (* mem uses structural equality on ints, which is fine *)
        stmt (* cycle *)
      else
        match stmt.skind with
        | Goto _ (* 1 succ *)
        | Instr [] (* CIL inserts like unlabelled goto, 0-1 succs *)
        | Block _ (* just container for stmts, 0-1 succs *)
        | Loop _ -> (* just container for (prepared) body, 1 succ *)
          begin match stmt.succs with
            | [] ->
              if not_found then
                raise Not_found
              else
                stmt
            | [next] ->
              find (stmt.sid :: visited_sids) next
            | _ -> (* >1 succ *)
              failwith "MyCFG.createCFG.find_real_stmt: >1 succ"
          end

        | Instr _
        | If _
        | Return _ ->
          stmt

        | Continue _
        | Break _
        | Switch _ ->
          (* Should be removed by Cil.prepareCFG. *)
          failwith "MyCFG.createCFG: unprepared stmt"

        | ComputedGoto _
        | TryExcept _
        | TryFinally _ ->
          failwith "MyCFG.createCFG: unsupported stmt"
    in
    try
      let initial_visited_sids = match parent with
        | Some parent -> [parent.sid]
        | None -> []
      in
      let r = find initial_visited_sids stmt in
      if Messages.tracing then Messages.traceu "cfg" "-> %d\n" r.sid;
      r
    with Not_found ->
      if Messages.tracing then Messages.traceu "cfg" "-> Not_found\n";
      raise Not_found
  in
  addEdge_fromLoc (FunctionEntry dummy_func) (Ret (None, dummy_func)) (Function dummy_func);
  (* We iterate over all globals looking for functions: *)
  iterGlobals file (fun glob ->
      match glob with
      | GFun (fd, fd_loc) ->
        if Messages.tracing then Messages.trace "cfg" "Looking at the function %s.\n" fd.svar.vname;

        if get_bool "dbg.cilcfgdot" then
          Cfg.printCfgFilename ("cilcfg." ^ fd.svar.vname ^ ".dot") fd;

        (* Find the first statement in the function *)
        let entrynode = find_real_stmt (Cilfacade.getFirstStmt fd) in
        (* Add the entry edge to that node *)
        addEdge (FunctionEntry fd) (fd_loc, Entry fd) (Statement entrynode);
        (* Return node to be used for infinite loop connection to end of function
         * lazy, so it's only added when actually needed *)
        let pseudo_return = lazy (
          let newst = mkStmt (Return (None, fd_loc)) in
          let start_id = 10_000_000_000 in (* TODO get max_sid? *)
          let sid = Hashtbl.hash fd_loc in (* Need pure sid instead of Cil.new_sid for incremental, similar to vid in Goblintutil.create_var. We only add one return stmt per loop, so the location hash should be unique. *)
          newst.sid <- if sid < start_id then sid + start_id else sid;
          fd.sallstmts <- fd.sallstmts @ [newst]; (* TODO: anything bad happen from changing sallstmts? should also update smaxid? *)
          let newst_node = Statement newst in
          addEdge newst_node (fd_loc, Ret (None, fd)) (Function fd);
          newst_node
        )
        in
        let loop_head_neg1 = NH.create 3 in
        (* So for each statement in the function body, we do the following: *)
        let handle stmt =
          if Messages.tracing then Messages.trace "cfg" "Statement %d at %a.\n" stmt.sid d_loc (get_stmtLoc stmt.skind);

          let real_succs () = List.map (find_real_stmt ~parent:stmt) stmt.succs in

          match stmt.skind with
          | Instr [] ->
            (* CIL sometimes inserts empty Instr, which is like a goto without label. *)
            (* Without this special case, CFG would contain edges without label or transfer function,
               which is unwanted because such flow is undetectable by the analysis (especially for witness generation). *)
            (* Generally these are unnecessary and unwanted because find_real_stmt skips over these. *)
            (* CIL uses empty Instr self-loop for empty Loop, so a Skip self-loop must be added to not lose the loop. *)
            begin match real_succs () with
              | [] -> () (* if stmt.succs is empty (which in other cases requires pseudo return), then it isn't a self-loop to add anyway *)
              | [succ] ->
                if CilType.Stmt.equal succ stmt then (* self-loop *)
                  addEdge (Statement stmt) (Cil.locUnknown, Skip) (Statement succ) (* TODO: better loc from somewhere? *)
              | _ -> failwith "MyCFG.createCFG: >1 Instr [] succ"
            end

          | Instr instrs -> (* non-empty Instr *)
            let edge_of_instr = function
              | Set (lval,exp,loc) -> loc, Assign (lval, exp)
              | Call (lval,func,args,loc) -> loc, Proc (lval,func,args)
              | Asm (attr,tmpl,out,inp,regs,loc) -> loc, ASM (tmpl,out,inp)
              | VarDecl (v, loc) -> loc, VDecl(v)
            in
            let edges = List.map edge_of_instr instrs in
            let add_succ_node succ_node = addEdges (Statement stmt) edges succ_node in
            begin match real_succs () with
              | [] -> add_succ_node (Lazy.force pseudo_return) (* stmt.succs can be empty if last instruction calls non-returning function (e.g. exit), so pseudo return instead *)
              | [succ] -> add_succ_node (Statement succ)
              | _ -> failwith "MyCFG.createCFG: >1 non-empty Instr succ"
            end

          | If (exp, _, _, loc) ->
            (* Cannot use true and false blocks from If constructor, because blocks don't have succs (stmts do).
               Cannot use first stmt in block either, because block may be empty (e.g. missing branch). *)
            (* Hence we rely on implementation detail of the If case in CIL's succpred_stmt.
               First, true branch's succ is consed (to empty succs list).
               Second, false branch's succ is consed (to previous succs list).
               CIL doesn't cons duplicate succs, so if both branches have the same succ, then singleton list is returned instead. *)
            let (true_stmt, false_stmt) = match real_succs () with
              | [false_stmt; true_stmt] -> (true_stmt, false_stmt)
              | [same_stmt] -> (same_stmt, same_stmt)
              | _ -> failwith "MyCFG.createCFG: invalid number of If succs"
            in
            addEdge (Statement stmt) (loc, Test (exp, true )) (Statement true_stmt);
            addEdge (Statement stmt) (loc, Test (exp, false)) (Statement false_stmt)

          | Loop (_, loc, Some cont, Some brk) -> (* TODO: use loc for something? *)
            (* CIL already converts Loop logic to Gotos and If. *)
            (* CIL eliminates the constant true If corresponding to constant true Loop.
               Then there is no Goto to after the loop and the CFG is unconnected (to Function node).
               An extra Neg(1) edge is added in such case. *)
            if Messages.tracing then Messages.trace "cfg" "loop %d cont=%d brk=%d\n" stmt.sid cont.sid brk.sid;
            begin match find_real_stmt ~parent:stmt ~not_found:true brk with
              | break_stmt ->
                (* break statement is what follows the (constant true) Loop *)
                (* Neg(1) edges are lazily added only when unconnectedness is detected at the end,
                   so break statement is just remembered here *)
                let loop_stmt = find_real_stmt stmt in
                NH.add loop_head_neg1 (Statement loop_stmt) (Statement break_stmt)
              | exception Not_found ->
                (* if the (constant true) Loop and its break statement are at the end of the function,
                   then find_real_stmt doesn't find a non-empty statement. *)
                (* pseudo return is used instead by default, so nothing to do here *)
                ()
            end

          | Loop (_, _, _, _) ->
            (* CIL's xform_switch_stmt (via prepareCFG) always adds both continue and break statements to all Loops. *)
            failwith "MyCFG.createCFG: unprepared Loop"

          | Return (exp, loc) ->
            addEdge (Statement stmt) (loc, Ret (exp, fd)) (Function fd)

          | Goto (target_ref, loc) ->
            (* Gotos are generally unnecessary and unwanted because find_real_stmt skips over these. *)
            (* CIL uses Goto self-loop for empty goto-based loop, so a Skip self-loop must be added to not lose the loop. *)
            if CilType.Stmt.equal !target_ref stmt then
              addEdge (Statement stmt) (loc, Skip) (Statement !target_ref)

          | Block _ ->
            (* Nothing to do for Blocks, find_real_stmt skips over these. *)
            ()

          | Continue _
          | Break _
          | Switch _ ->
            (* Should be removed by Cil.prepareCFG. *)
            failwith "MyCFG.createCFG: unprepared stmt"

          | ComputedGoto _
          | TryExcept _
          | TryFinally _ ->
            failwith "MyCFG.createCFG: unsupported stmt"
        in
        List.iter handle fd.sallstmts;

        if Messages.tracing then Messages.trace "cfg" "Over\n";

        (* Connect remaining infinite loops (e.g made using goto) to end of function
         * via pseudo return node for demand driven solvers *)
        let module TmpCfg: CfgBidir =
        struct
          let next = H.find_all cfgF
          let prev = H.find_all cfgB
        end
        in
        let loop_heads = find_loop_heads_fun (module TmpCfg) fd in
        let reachable_return = find_backwards_reachable (module TmpCfg) (Function fd) in
        NH.iter (fun node () ->
            if not (NH.mem reachable_return node) then (
              let targets = match NH.find_all loop_head_neg1 node with
                | [] -> [Lazy.force pseudo_return]
                | targets -> targets
              in
              (* single loop head may have multiple neg1-s, e.g. test 03/22 *)
              List.iter (fun target ->
                  addEdge_fromLoc node (Test (one, false)) target
                ) targets
            )
          ) loop_heads;

        (* Verify that function is now connected *)
        let reachable_return' = find_backwards_reachable (module TmpCfg) (Function fd) in
        if not (NH.mem reachable_return' (FunctionEntry fd)) then
          failwith "MyCFG.createCFG: FunctionEntry not connected to Function (return)"
      | _ -> ()
    );
  if Messages.tracing then Messages.trace "cfg" "CFG building finished.\n\n";
  cfgF, cfgB


let minimizeCFG (fw,bw) =
  let keep = H.create 113 in
  let comp_keep t (_,f) =
    if (List.length (H.find_all bw t)<>1) || (List.length (H.find_all fw t)<>1) then
      H.replace keep t ();
    if (List.length (H.find_all bw f)<>1) || (List.length (H.find_all fw f)<>1) then
      H.replace keep f ()
  in
  H.iter comp_keep bw;
  (* H.iter comp_keep fw; *)
  let cfgB = H.create 113 in
  let cfgF = H.create 113 in
  let ready = H.create 113 in
  let rec add a b t (e,f)=
    if H.mem keep f then begin
      H.add cfgB b (e@a,f);
      H.add cfgF f (e@a,b);
      if H.mem ready b then begin
        H.replace ready f ();
        List.iter (add [] f f) (H.find_all bw f)
      end
    end else begin
      List.iter (add (e@a) b f) (H.find_all bw f)
    end
  in
  H.iter (fun k _ -> List.iter (add [] k k) (H.find_all bw k)) keep;
  H.clear ready;
  H.clear keep;
  cfgF, cfgB


module type CfgPrinters =
sig
  val defaultNodeStyles: string list
  val printNodeStyle: out_channel -> node -> unit
  val printEdgeStyle: out_channel -> node -> (edges * node) -> unit
end

module type NodeStyles =
sig
  val defaultNodeStyles: string list
  val extraNodeStyles: node -> string list
end

module CfgPrinters (NodeStyles: NodeStyles) =
struct
  include NodeStyles

  let p_node () n = text (Node.show_id n)

  (* escape string in label, otherwise dot might fail *)
  let p_edge () x = Pretty.text (String.escaped (Pretty.sprint ~width:max_int (Edge.pretty () x)))

  let rec p_edges () = function
    | [] -> Pretty.dprintf ""
    | [(_, x)] -> p_edge () x
    | (_,x)::xs -> Pretty.dprintf "%a\n%a" p_edge x p_edges xs

  let printEdgeStyle out (toNode: node) ((edges:(location * edge) list), (fromNode: node)) =
    ignore (Pretty.fprintf out "\t%a -> %a [label = \"%a\"] ;\n" p_node fromNode p_node toNode p_edges edges)

  let printNodeStyle out (n:node) =
    let label = match n with
      | Statement _ -> [] (* use default label *)
      | _ -> ["label=\"" ^ String.escaped (Node.show_cfg n) ^ "\""]
    in
    let shape = match n with
      | Statement {skind=If (_,_,_,_); _}  -> ["shape=diamond"]
      | Statement _     -> [] (* use default shape *)
      | Function _
      | FunctionEntry _ -> ["shape=box"]
    in
    let styles = String.concat "," (label @ shape @ extraNodeStyles n) in
    ignore (Pretty.fprintf out ("\t%a [%s];\n") p_node n styles)
end

let fprint_dot (module CfgPrinters: CfgPrinters) iter_edges out =
  let node_table = NH.create 113 in
  Printf.fprintf out "digraph cfg {\n";
  Printf.fprintf out "\tnode [%s];\n" (String.concat "," CfgPrinters.defaultNodeStyles);
  let printEdge (toNode: node) ((edges:(location * edge) list), (fromNode: node)) =
    CfgPrinters.printEdgeStyle out toNode (edges, fromNode);
    NH.replace node_table toNode ();
    NH.replace node_table fromNode ()
  in
  iter_edges printEdge;
  NH.iter (fun node _ -> CfgPrinters.printNodeStyle out node) node_table;
  Printf.fprintf out "}\n";
  flush out;
  close_out_noerr out

let fprint_hash_dot cfg  =
  let module NoExtraNodeStyles =
  struct
    let defaultNodeStyles = []
    let extraNodeStyles node = []
  end
  in
  let out = open_out "cfg.dot" in
  let iter_edges f = H.iter f cfg in
  fprint_dot (module CfgPrinters (NoExtraNodeStyles)) iter_edges out


let getCFG (file: file) : cfg * cfg =
  let cfgF, cfgB = createCFG file in
  let cfgF, cfgB =
    if get_bool "exp.mincfg" then
      Stats.time "minimizing the cfg" minimizeCFG (cfgF, cfgB)
    else
      (cfgF, cfgB)
  in
  if get_bool "justcfg" then fprint_hash_dot cfgB;
  H.find_all cfgF, H.find_all cfgB


(* TODO: unused *)
let generate_irpt_edges cfg =
  let make_irpt_edge toNode (_, fromNode) =
    match toNode with
    | FunctionEntry f -> let _ = print_endline ( " Entry " ) in ()
    | _ -> H.add cfg toNode (SelfLoop, toNode)
  in
  H.iter make_irpt_edge cfg


let iter_fd_edges (module Cfg : CfgBackward) fd =
  let ready      = NH.create 113 in
  let rec printNode (toNode : node) f =
    if not (NH.mem ready toNode) then begin
      NH.replace ready toNode ();
      let prevs = Cfg.prev toNode in
      List.iter (f toNode) prevs;
      List.iter (fun (_,x) -> printNode x f) prevs
    end
  in
  printNode (Function fd)

let fprint_fundec_html_dot (module Cfg : CfgBidir) live fd out =
  let module HtmlExtraNodeStyles =
  struct
    let defaultNodeStyles = ["id=\"\\N\""; "URL=\"javascript:show_info('\\N');\""; "style=filled"; "fillcolor=white"] (* \N is graphviz special for node ID *)

    let extraNodeStyles n =
      if live n then
        []
      else
        ["fillcolor=orange"]
  end
  in
  let iter_edges = iter_fd_edges (module Cfg) fd in
  fprint_dot (module CfgPrinters (HtmlExtraNodeStyles)) iter_edges out

let dead_code_cfg (file:file) (module Cfg : CfgBidir) live =
  iterGlobals file (fun glob ->
      match glob with
      | GFun (fd,loc) ->
        (* ignore (Printf.printf "fun: %s\n" fd.svar.vname); *)
        let base_dir = Goblintutil.create_dir ((if get_bool "interact.enabled" then get_string "interact.out"^"/" else "")^"cfgs") in
        let c_file_name = Str.global_substitute (Str.regexp Filename.dir_sep) (fun _ -> "%2F") fd.svar.vdecl.file in
        let dot_file_name = fd.svar.vname^".dot" in
        let file_dir = Goblintutil.create_dir (Filename.concat base_dir c_file_name) in
        let fname = Filename.concat file_dir dot_file_name in
        fprint_fundec_html_dot (module Cfg : CfgBidir) live fd (open_out fname)
      | _ -> ()
    )


let getGlobalInits (file: file) : edges  =
  (* runtime with fast_global_inits: List: 36.25s, Hashtbl: 0.56s *)
  let inits = Hashtbl.create 13 in
  let fast_global_inits = get_bool "exp.fast_global_inits" in
  let rec doInit lval loc init is_zero =
    let initoffs offs init typ lval =
      doInit (addOffsetLval offs lval) loc init is_zero;
      lval
    in
    let rec all_index = function
      | Index (e,o) -> Index (all_array_index_exp, all_index o)
      | Field (f,o) -> Field (f, all_index o)
      | NoOffset -> NoOffset
    in
    let all_index (lh,offs) = lh, all_index offs in
    match init with
    | SingleInit exp ->
      let assign lval = (loc, Assign (lval, exp)) in
      (* This is an optimization so that we don't get n*m assigns for an array a[n][m].
         Instead, we get one assign for each distinct value in the array *)
      if not fast_global_inits then
        Hashtbl.add inits (assign lval) ()
      else if not (Hashtbl.mem inits (assign (all_index lval))) then
        Hashtbl.add inits (assign (all_index lval)) ()
      else
        ()
    | CompoundInit (typ, lst) ->
      let ntyp = match typ, lst with
        | TArray(t, None, attr), [] -> TArray(t, Some zero, attr) (* set initializer type to t[0] for flexible array members of structs that are intialized with {} *)
        | _, _ -> typ
      in
      ignore (foldLeftCompound ~implicit:true ~doinit:initoffs ~ct:ntyp ~initl:lst ~acc:lval)
  in
  let f glob =
    match glob with
    | GVar ({vtype=vtype; _} as v, init, loc) -> begin
        let init, is_zero = match init.init with
          | None -> makeZeroInit vtype, true
          | Some x -> x, false
        in
        doInit (var v) loc init is_zero
      end
    | _ -> ()
  in
  iterGlobals file f;
  let initfun = emptyFunction "__goblint_dummy_init" in
  (* order is not important since only compile-time constants can be assigned *)
  ({line = 0; file="initfun"; byte= 0; column = 0}, Entry initfun) :: (BatHashtbl.keys inits |> BatList.of_enum)


let numGlobals file =
  let n = ref 0 in
  (* GVar Cannot have storage Extern or function type *)
  Cil.iterGlobals file (function GVar _ -> incr n | _ -> ());
  !n