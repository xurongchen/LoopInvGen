open Core
open SyGuS
open Types
open Utils
open VPIE

type 'a config = {
  for_VPIE : 'a VPIE.config ;

  base_random_seed : string ;
  max_restarts : int ;
  max_steps_on_restart : int ;
  model_completion_mode : [ `RandomGeneration | `UsingZ3 ] ;
}

let default_config = {
  for_VPIE = {
    VPIE.default_config with
      simplify = false ;
  } ;

  base_random_seed = "LoopInvGen" ;
  max_restarts = 32 ;
  max_steps_on_restart = 48 ;
  model_completion_mode = `RandomGeneration ;
}

let learnStrongerThanPost ?(conf = default_config) ~(states : value list list)
                          ~(z3 : ZProc.t) (sygus : SyGuS.t) : PIE.desc =
  Log.debug (lazy ("STAGE 1> Learning initial candidate invariant")) ;
  VPIE.learnVPreCond ~conf:conf.for_VPIE ~consts:sygus.consts ~z3 (
    (PIE.create_pos_job ()
      ~f: (ZProc.constraint_sat_function
             sygus.post.expr ~z3 ~arg_names:(List.map sygus.state_vars ~f:fst))
      ~args: sygus.state_vars
      ~post: (fun _ res -> match res with
                           | Ok v when v = vtrue -> true
                           | _ -> false)
      ~pos_tests: states
    ),
    sygus.post.expr
  )

let strengthenForInductiveness ?(conf = default_config) ~(sygus : SyGuS.t)
                               ~(states : value list list) ~(z3 : ZProc.t)
                               (inv : PIE.desc) : PIE.desc =
  let invf_call =
       "(invf " ^ (List.to_string_map sygus.inv_vars ~sep:" " ~f:fst) ^ ")" in
  let invf'_call =
    "(invf " ^ (List.to_string_map sygus.inv'_vars ~sep:" " ~f:fst) ^ ")" in
  let trans_desc = ZProc.simplify z3 sygus.trans.expr in
  let eval_term = (if not (conf.model_completion_mode = `UsingZ3) then "true"
                   else "(and " ^ invf_call ^ " " ^ trans_desc ^ ")") in
  let rec helper inv =
  begin
    Log.debug (lazy ("STAGE 2> Strengthening for inductiveness:" ^
                     Log.indented_sep ^ inv)) ;
    if inv = "false" then inv else
    let inv_def =
      "(define-fun invf (" ^
      (List.to_string_map sygus.inv_vars ~sep:" "
                          ~f:(fun (s, t) -> "(" ^ s ^ " " ^
                                            (Types.string_of_typ t) ^ ")")) ^
      ") Bool " ^ inv ^ ")"
    in ZProc.create_local z3 ~db:[ inv_def
                                 ; "(assert " ^ trans_desc ^ ")"
                                 ; "(assert " ^ invf_call ^ ")" ]
     ; let pre_inv =
         VPIE.learnVPreCond
           ~conf:conf.for_VPIE ~consts:sygus.consts ~z3 ~eval_term
           ((PIE.create_pos_job ()
               ~f:(ZProc.constraint_sat_function ("(not " ^ invf'_call ^ ")")
                     ~z3 ~arg_names:(List.map sygus.state_vars ~f:fst))
               ~args: sygus.state_vars
               ~post: (fun _ res -> match res with
                                    | Ok v when v = vfalse -> true
                                    | _ -> false)
               ~pos_tests: states),
            invf'_call)
      in ZProc.close_local z3
       ; Log.debug (lazy ("Inductive Delta: " ^ pre_inv))
       ; if pre_inv = "true" then inv
         else helper (ZProc.simplify z3 ("(and " ^ pre_inv ^ " " ^ inv ^ ")"))
  end in helper inv

let checkIfWeakerThanPre ?(seed = default_config.base_random_seed)
                         ?(avoid_roots = []) (inv : PIE.desc) ~(sygus : SyGuS.t)
                         ~(z3 : ZProc.t) : value list option =
  Log.debug (lazy ("STAGE 3> Checking if weaker than precond:" ^
                   Log.indented_sep ^ inv)) ;
  let open Quickcheck in
  random_value ~size:1 ~seed:(`Deterministic seed)
    (Simulator.gen_state_from_model
       (ZProc.implication_counter_example z3 sygus.pre.expr inv
         ~db:(if avoid_roots = [] then []
               else [ "(assert (and " ^ (String.concat avoid_roots ~sep:" ")
                   ^ "))" ]))
       sygus z3)

let learnInvariant ?(avoid_roots = []) ?(conf = default_config)
                   ~(states : value list list) (sygus : SyGuS.t)
                   : PIE.desc option =
  ZProc.process (fun z3 ->
    Simulator.setup sygus z3 ;
    let rec helper states avoid_roots tries seed =
      let inv = learnStrongerThanPost sygus ~states ~z3
      in let inv = strengthenForInductiveness inv ~sygus ~states ~z3
      in match checkIfWeakerThanPre ~seed ~avoid_roots inv ~sygus ~z3 with
         | None -> Some inv
         | model -> if tries < 1 then None else
             let open Quickcheck in
             helper (List.dedup (
                       states @
                       (random_value
                           ~size:conf.max_steps_on_restart
                           ~seed:(`Deterministic seed)
                           (Simulator.simulate_from sygus z3 model))))
                    (List.cons_opt_value
                      (Simulator.build_avoid_constraints sygus model)
                      avoid_roots)
                    (tries - 1)
                    (seed ^ "#")
    in helper states avoid_roots conf.max_restarts conf.base_random_seed)