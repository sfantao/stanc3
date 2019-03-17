open Core_kernel
open Mir
open Dataflow_types

(** Union maps, preserving the left element in a collision *)
let union_maps_left (m1 : ('a, 'b) Map.Poly.t) (m2 : ('a, 'b) Map.Poly.t) :
    ('a, 'b) Map.Poly.t =
  let f ~key:_ opt =
    match opt with
    | `Left v -> Some v
    | `Right v -> Some v
    | `Both (v1, _) -> Some v1
  in
  Map.Poly.merge m1 m2 ~f

(**
   A traversal that simultaneously accumulates a state (type 'f) and replaces the
   substatement values from ('a to 'c). Traversal is done in-order but ignores branching,
   e.g., and if's then block is followed by the else block rather than branching.
*)
let fwd_traverse_statement (stmt : 'a statement) ~init:(state : 'f)
    ~(f : 'f -> 'a -> 'f * 'c) : 'f * 'c statement =
  match stmt with
  | IfElse (pred, then_s, else_s_opt) ->
      let s', c = f state then_s in
      Option.value_map else_s_opt
        ~default:(s', IfElse (pred, c, None))
        ~f:(fun else_s ->
          let s'', c' = f s' else_s in
          (s'', IfElse (pred, c, Some c')) )
  | While (pred, body) ->
      let s', c = f state body in
      (s', While (pred, c))
  | For vars ->
      let s', c = f state vars.body in
      (s', For {vars with body= c})
  | Block stmts ->
      let s', ls =
        List.fold_left stmts
          ~f:(fun (s, l) stmt ->
            let s', c = f s stmt in
            (s', List.cons c l) )
          ~init:(state, [])
      in
      (s', Block (List.rev ls))
  | SList stmts ->
      let s', ls =
        List.fold_left stmts
          ~f:(fun (s, l) stmt ->
            let s', c = f s stmt in
            (s', List.cons c l) )
          ~init:(state, [])
      in
      (s', SList (List.rev ls))
  | FunDef vars ->
      let s', c = f state vars.fdbody in
      (s', FunDef {vars with fdbody= c})
  | Assignment _ as s -> (state, s)
  | TargetPE _ as s -> (state, s)
  | NRFunApp _ as s -> (state, s)
  | Check _ as s -> (state, s)
  | Break as s -> (state, s)
  | Continue as s -> (state, s)
  | Return _ as s -> (state, s)
  | Skip as s -> (state, s)
  | Decl _ as s -> (state, s)

(**
   Like a forward traversal, but branches accumulate two different states that are
   recombined with join.
*)
let branching_traverse_statement (stmt : 'a statement) ~(join : 'f -> 'f -> 'f)
    ~init:(state : 'f) ~(f : 'f -> 'a -> 'f * 'c) : 'f * 'c statement =
  match stmt with
  | IfElse (pred, then_s, else_s_opt) ->
      let s', c = f state then_s in
      Option.value_map else_s_opt
        ~default:(s', IfElse (pred, c, None))
        ~f:(fun else_s ->
          let s'', c' = f state else_s in
          (join s' s'', IfElse (pred, c, Some c')) )
  | _ as s -> fwd_traverse_statement s ~init:state ~f

(** Like a branching traversal, but doesn't return an updated statement.
*)
let branching_fold_statement (stmt : 'a statement) ~(join : 'f -> 'f -> 'f)
    ~init:(state : 'f) ~(f : 'f -> 'a -> 'f) : 'f =
  fst
    (branching_traverse_statement stmt ~join ~init:state ~f:(fun s a ->
         (f s a, ()) ))

(**
   See interface file
*)
let build_statement_map (extract : 's -> 's statement) (metadata : 's -> 'm)
    (stmt : 's) : (label, label statement * 'm) Map.Poly.t =
  let rec build_statement_map_rec (next_label : label)
      (map : (label, label statement * 'm) Map.Poly.t) (stmt : 's) :
      (label * (label, label statement * 'm) Map.Poly.t) * label =
    let this_label = next_label in
    let next_label' = next_label + 1 in
    let f (label, map) stmt = build_statement_map_rec label map stmt in
    let (next_label'', map), built =
      fwd_traverse_statement (extract stmt) ~init:(next_label', map) ~f
    in
    ( ( next_label''
      , union_maps_left map
          (Map.Poly.singleton this_label (built, metadata stmt)) )
    , this_label )
  in
  let (_, map), _ = build_statement_map_rec 1 Map.Poly.empty stmt in
  map
(* TODO: this currently does not seem to be labelling inside function bodies.
   Could we also do that? *)

(**
   See interface file
*)
let rec build_recursive_statement (rebuild : 's statement -> 'm -> 's)
    (statement_map : (label, label statement * 'm) Map.Poly.t) (label : label)
    : 's =
  let stmt_ints, meta = Map.Poly.find_exn statement_map label in
  let build_stmt = build_recursive_statement rebuild statement_map in
  let stmt = map_statement build_stmt stmt_ints in
  rebuild stmt meta

(**
   See interface file
*)
let build_cf_graph (statement_map : (label, label statement * 'm) Map.Poly.t) :
    (label, label Set.Poly.t) Map.Poly.t =
  let rec build_cf_graph_rec (cf_parent : label option)
      ((breaks_in, returns_in, continues_in, map_in) :
        label Set.Poly.t
        * label Set.Poly.t
        * label Set.Poly.t
        * (label, label Set.Poly.t) Map.Poly.t) (label : label) :
      label Set.Poly.t
      * label Set.Poly.t
      * label Set.Poly.t
      * (label, label Set.Poly.t) Map.Poly.t =
    let stmt, _ = Map.Poly.find_exn statement_map label in
    (* Only control flow nodes should pass themselves down as parents *)
    let is_ctrl_flow =
      match stmt with
      | IfElse _ -> true
      | While _ -> true
      | For _ -> true
      | FunDef _ -> true
      | _ -> false
    in
    let child_cf = if is_ctrl_flow then Some label else cf_parent in
    let join_state (breaks1, returns1, continues1, map_sofar1)
        (breaks2, returns2, continues2, map_sofar2) =
      ( Set.Poly.union breaks1 breaks2
      , Set.Poly.union returns1 returns2
      , Set.Poly.union continues1 continues2
      , union_maps_left map_sofar1 map_sofar2 )
    in
    (* The accumulated state after traversing substatements *)
    let breaks_subexpr, returns_subexpr, continues_subexpr, map_subexpr =
      branching_fold_statement stmt ~join:join_state
        ~init:(breaks_in, returns_in, continues_in, map_in)
        ~f:(build_cf_graph_rec child_cf)
    in
    (* Some statements interact with the break/return/continue states
       E.g., loops nullify breaks and continues in their body, but are still affected by
       breaks and input continues*)
    let breaks_out, returns_out, continues_out, extra_cf_deps =
      match stmt with
      | Break ->
          ( Set.Poly.add breaks_subexpr label
          , returns_subexpr
          , continues_subexpr
          , Set.Poly.empty )
      | Return _ ->
          ( breaks_subexpr
          , Set.Poly.add returns_subexpr label
          , continues_subexpr
          , Set.Poly.empty )
      | Continue ->
          ( breaks_subexpr
          , returns_subexpr
          , Set.Poly.add continues_subexpr label
          , Set.Poly.empty )
      | While _ -> (breaks_in, returns_subexpr, continues_in, breaks_subexpr)
      | For _ -> (breaks_in, returns_subexpr, continues_in, breaks_subexpr)
      | _ ->
          (breaks_subexpr, returns_subexpr, continues_subexpr, Set.Poly.empty)
    in
    let cf_parent_set =
      Option.value_map cf_parent ~default:Set.Poly.empty ~f:Set.Poly.singleton
    in
    let cf_deps =
      Set.Poly.union
        (Set.Poly.union continues_in
           (Set.Poly.union returns_subexpr extra_cf_deps))
        cf_parent_set
    in
    ( breaks_out
    , returns_out
    , continues_out
    , union_maps_left map_subexpr (Map.Poly.singleton label cf_deps) )
  in
  let _, _, _, map =
    build_cf_graph_rec None
      (Set.Poly.empty, Set.Poly.empty, Set.Poly.empty, Map.Poly.empty)
      1
  in
  map

(**
   See interface file
*)
let build_predecessor_graph
    (statement_map : (label, label statement * 'm) Map.Poly.t) :
    label Set.Poly.t * (label, label Set.Poly.t) Map.Poly.t =
  let rec build_pred_graph_rec
      ((preds, map_in) :
        label Set.Poly.t * (label, label Set.Poly.t) Map.Poly.t)
      (label : label) : label Set.Poly.t * (label, label Set.Poly.t) Map.Poly.t
      =
    let stmt, _ = Map.Poly.find_exn statement_map label in
    let join_state (preds1, map1) (preds2, map2) =
      (Set.Poly.union preds1 preds2, union_maps_left map1 map2)
    in
    let exits, map_subexpr =
      branching_fold_statement stmt ~join:join_state
        ~init:(Set.Poly.singleton label, map_in)
        ~f:build_pred_graph_rec
    in
    let looping_predecessors () =
      let exits, map_subexpr =
        branching_fold_statement stmt ~join:join_state
          ~init:(Set.Poly.add exits label, map_in)
          ~f:build_pred_graph_rec
      in
      (Set.Poly.union preds exits, map_subexpr)
    in
    let exits', map_subexpr' =
      match stmt with
      | For _ -> looping_predecessors ()
      | While _ -> looping_predecessors ()
      | _ -> (exits, map_subexpr)
    in
    (exits', union_maps_left map_subexpr' (Map.Poly.singleton label preds))
  in
  build_pred_graph_rec (Set.Poly.empty, Map.Poly.empty) 1

(***********************************)
(* Tests                           *)
(***********************************)

let example1_program =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
        model {
          int i = 0;
          if (i < 0) {
            print(i);
          } else {
            for (j in 1:10) {
              if (j > 9) {
                break;
              }
              if (j > 8 && i < -1) {
                continue;
              }
              if (j > 5) {
                continue;
              } else {
                print("Badger", i + j);
              }
              print("Fin");
            }
          }
        }
      |}
  in
  let mir =
    Ast_to_Mir.trans_prog "" (Semantic_check.semantic_check_program ast)
  in
  let block = Mir.Block mir.log_prob in
  {stmt= block; sloc= ""}

let example1_statement_map =
  build_statement_map (fun s -> s.stmt) (fun s -> s.sloc) example1_program

let%expect_test "Statement label map example" =
  print_s
    [%sexp
      (example1_statement_map : (label, label statement * string) Map.Poly.t)] ;
  [%expect
    {|
      ((1 ((Block (2 5)) ""))
       (2 ((SList (3 4)) "file string, line 3, columns 10-20"))
       (3
        ((Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))
         "file string, line 3, columns 10-20"))
       (4 ((Assignment (Var i) (Lit Int 0)) "file string, line 3, columns 10-20"))
       (5
        ((IfElse (BinOp (Var i) Less (Lit Int 0)) 6 (8))
         "file string, line 4, column 10 to line 21, column 11"))
       (6 ((Block (7)) "file string, line 4, column 21 to line 6, column 11"))
       (7 ((NRFunApp print ((Var i))) "file string, line 5, columns 12-21"))
       (8 ((Block (9)) "file string, line 6, column 17 to line 21, column 11"))
       (9
        ((For (loopvar (Var j)) (lower (Lit Int 1)) (upper (Lit Int 10)) (body 10))
         "file string, line 7, column 12 to line 20, column 13"))
       (10
        ((Block (11 14 17 22))
         "file string, line 7, column 28 to line 20, column 13"))
       (11
        ((IfElse (BinOp (Var j) Greater (Lit Int 9)) 12 ())
         "file string, line 8, column 14 to line 10, column 15"))
       (12 ((Block (13)) "file string, line 8, column 25 to line 10, column 15"))
       (13 (Break "file string, line 9, columns 16-22"))
       (14
        ((IfElse
          (BinOp (BinOp (Var j) Greater (Lit Int 8)) And
           (BinOp (Var i) Less (FunApp Minus ((Lit Int 1)))))
          15 ())
         "file string, line 11, column 14 to line 13, column 15"))
       (15 ((Block (16)) "file string, line 11, column 35 to line 13, column 15"))
       (16 (Continue "file string, line 12, columns 16-25"))
       (17
        ((IfElse (BinOp (Var j) Greater (Lit Int 5)) 18 (20))
         "file string, line 14, column 14 to line 18, column 15"))
       (18 ((Block (19)) "file string, line 14, column 25 to line 16, column 15"))
       (19 (Continue "file string, line 15, columns 16-25"))
       (20 ((Block (21)) "file string, line 16, column 21 to line 18, column 15"))
       (21
        ((NRFunApp print ((Lit Str Badger) (BinOp (Var i) Plus (Var j))))
         "file string, line 17, columns 16-39"))
       (22
        ((NRFunApp print ((Lit Str Fin))) "file string, line 19, columns 14-27")))
    |}]

let%expect_test "Controlflow graph example" =
  let cf = build_cf_graph example1_statement_map in
  print_s [%sexp (cf : (label, label Set.Poly.t) Map.Poly.t)] ;
  [%expect
    {|
      ((1 ()) (2 ()) (3 ()) (4 ()) (5 ()) (6 (5)) (7 (5)) (8 (5)) (9 (5 13))
       (10 (9)) (11 (9)) (12 (11)) (13 (11)) (14 (9)) (15 (14)) (16 (14))
       (17 (9 16)) (18 (16 17)) (19 (16 17)) (20 (16 17)) (21 (16 17))
       (22 (9 16 19)))
    |}]

let%expect_test "Predecessor graph example" =
  let exits, preds = build_predecessor_graph example1_statement_map in
  print_s
    [%sexp
      ((exits, preds) : label Set.Poly.t * (label, label Set.Poly.t) Map.Poly.t)] ;
  [%expect
    {|
      ((7 8 22)
       ((1 ()) (2 (1)) (3 (2)) (4 (3)) (5 (4)) (6 (5)) (7 (6)) (8 (5)) (9 (8))
        (10 (9 22)) (11 (10)) (12 (11)) (13 (12)) (14 (13)) (15 (14)) (16 (15))
        (17 (16)) (18 (17)) (19 (18)) (20 (17)) (21 (20)) (22 (19 21))))
    |}]

let example2_program =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        real f() {
          if (3>2) {
            print("hello");
            return 2;
          }
          return 22;
        }
        void g() {
          print("bye");
        }
      }
      |}
  in
  let mir =
    Ast_to_Mir.trans_prog "" (Semantic_check.semantic_check_program ast)
  in
  let block = Mir.Block mir.functions_block in
  {stmt= block; sloc= ""}

let example2_statement_map =
  build_statement_map (fun s -> s.stmt) (fun s -> s.sloc) example2_program

let%expect_test "Statement label map example 2" =
  print_s
    [%sexp
      (example2_statement_map : (label, label statement * string) Map.Poly.t)] ;
  [%expect
    {|
      ((1 ((Block (2 9)) ""))
       (2
        ((FunDef (fdrt (UReal)) (fdname f) (fdargs ()) (fdbody 3))
         "file string, line 3, column 8 to line 9, column 9"))
       (3 ((Block (4 8)) "file string, line 3, column 17 to line 9, column 9"))
       (4
        ((IfElse (BinOp (Lit Int 3) Greater (Lit Int 2)) 5 ())
         "file string, line 4, column 10 to line 7, column 11"))
       (5 ((Block (6 7)) "file string, line 4, column 19 to line 7, column 11"))
       (6
        ((NRFunApp print ((Lit Str hello))) "file string, line 5, columns 12-27"))
       (7 ((Return ((Lit Int 2))) "file string, line 6, columns 12-21"))
       (8 ((Return ((Lit Int 22))) "file string, line 8, columns 10-20"))
       (9
        ((FunDef (fdrt ()) (fdname g) (fdargs ()) (fdbody 10))
         "file string, line 10, column 8 to line 12, column 9"))
       (10 ((Block (11)) "file string, line 10, column 17 to line 12, column 9"))
       (11
        ((NRFunApp print ((Lit Str bye))) "file string, line 11, columns 10-23")))
    |}]

let%expect_test "Controlflow graph example 2" =
  let cf = build_cf_graph example2_statement_map in
  print_s [%sexp (cf : (label, label Set.Poly.t) Map.Poly.t)] ;
  [%expect
    {|
      ((1 (7 8)) (2 (7 8)) (3 (2 7 8)) (4 (2 7)) (5 (4 7)) (6 (4)) (7 (4))
       (8 (2 7)) (9 (7 8)) (10 (7 8 9)) (11 (7 8 9)))
    |}]

let%expect_test "Predecessor graph example 2" =
  let exits, preds = build_predecessor_graph example2_statement_map in
  print_s
    [%sexp
      ((exits, preds) : label Set.Poly.t * (label, label Set.Poly.t) Map.Poly.t)] ;
  [%expect
    {|
      ((11)
       ((1 ()) (2 (1)) (3 (2)) (4 (3)) (5 (4)) (6 (5)) (7 (6)) (8 (7)) (9 (8))
        (10 (9)) (11 (10))))
    |}]
(* TODO: this predecessor graph is all wrong! *)

let%test "Reconstructed recursive statement" =
  let stmt =
    build_recursive_statement
      (fun stmt meta -> {stmt; sloc= meta})
      example1_statement_map 1
  in
  stmt = example1_program
