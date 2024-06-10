(** CFG node.
    Corresponds to a program point between program statements. *)

open GoblintCil
open Pretty

include Printable.StdLeaf

include Node0

let name () = "node"

(* TODO: remove this? *)
(** Pretty node plainly with entire stmt. *)
let rec pretty_plain () = function
  | Statement s -> text "Statement " ++ dn_stmt () s
  | Function f -> text "Function " ++ text f.svar.vname
  | FunctionEntry f -> text "FunctionEntry " ++ text f.svar.vname
  | Enter (source, f, _) -> text "Enter " ++ text f.svar.vname ++ text " from " ++ pretty_plain () source
  | Combine (source, f, _) -> text "Combine " ++ text f.svar.vname ++ text " with " ++ pretty_plain () source

(* TODO: remove this? *)
(** Pretty node plainly with stmt location. *)
let rec pretty_plain_short () = function
  | Statement s -> text "Statement @ " ++ CilType.Location.pretty () (Cilfacade.get_stmtLoc s)
  | Function f -> text "Function " ++ text f.svar.vname
  | FunctionEntry f -> text "FunctionEntry " ++ text f.svar.vname
  | Enter (source, f, _) -> text "Enter " ++ text f.svar.vname ++ text " from " ++ pretty_plain_short () source
  | Combine (source, f, _) -> text "Combine " ++ text f.svar.vname ++ text " with " ++ pretty_plain_short () source

(** Pretty node for solver variable tracing with short stmt. *)
let rec pretty_trace () = function
  | Statement stmt          -> dprintf "node %d \"%a\"" stmt.sid Cilfacade.stmt_pretty_short stmt
  | Function      fd        -> dprintf "call of %s (%d)" fd.svar.vname fd.svar.vid
  | FunctionEntry fd        -> dprintf "entry state of %s (%d)" fd.svar.vname fd.svar.vid
  | Enter (source, fd, _)      -> dprintf "enter %s (%d) from %a" fd.svar.vname fd.svar.vid pretty_trace source
  | Combine (source, fd, _) -> dprintf "combine %s (%d) with %a" fd.svar.vname fd.svar.vid pretty_trace source

(** Output functions for Printable interface *)
let pretty () x = pretty_trace () x
include Printable.SimplePretty (
  struct
    type nonrec t = t
    let pretty = pretty
  end
  )
(* TODO: deriving to_yojson gets overridden by SimplePretty *)

(** Show node ID for CFG and results output. *)
let rec show_id = function
  | Statement stmt          -> string_of_int stmt.sid
  | Function fd             -> "ret" ^ string_of_int fd.svar.vid
  | FunctionEntry fd        -> "fun" ^ string_of_int fd.svar.vid
  | Enter (source, fd, _)      -> "enter" ^ string_of_int fd.svar.vid ^ "[" ^ show_id source ^ "]"
  | Combine (source, fd, _) -> "combine_env" ^ string_of_int fd.svar.vid ^ "[" ^ show_id source ^ "]"


(** Show node label for CFG. *)
let rec show_cfg = function
  | Statement stmt          -> string_of_int stmt.sid (* doesn't use this but defaults to no label and uses ID from show_id instead *)
  | Function fd             -> "return of " ^ fd.svar.vname ^ "()"
  | FunctionEntry fd        -> fd.svar.vname ^ "()"
  | Enter (source, fd, _)      -> "enter " ^ fd.svar.vname ^ "() from " ^ show_cfg source
  | Combine (source, fd, _) -> "combine_env" ^ fd.svar.vname ^ "() with " ^ show_cfg source

(** Find [fundec] which the node is in. In an incremental run this might yield old fundecs for pseudo-return nodes from the old file. *)
let find_fundec (node: t) =
  match node with
  | Statement stmt -> Cilfacade.find_stmt_fundec stmt
  | Function fd
  | FunctionEntry fd -> fd
  | Enter (_, fd, _) -> fd
  | Combine (_, fd, _) -> fd

(** @raise Not_found *)
let of_id s =
  let ix = Str.search_forward (Str.regexp {|[0-9]+$|}) s 0 in
  let id = int_of_string (Str.string_after s ix) in
  let prefix = Str.string_before s ix in
  match ix with
  | 0 -> Statement (Cilfacade.find_stmt_sid id)
  | _ ->
    let fundec = Cilfacade.find_varinfo_fundec {dummyFunDec.svar with vid = id} in
    match prefix with
    | "ret" -> Function fundec
    | "fun" -> FunctionEntry fundec
    | _     -> raise Not_found
