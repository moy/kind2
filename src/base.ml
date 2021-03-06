(* This file is part of the Kind 2 model checker.

   Copyright (c) 2014 by the Board of Trustees of the University of Iowa

   Licensed under the Apache License, Version 2.0 (the "License"); you
   may not use this file except in compliance with the License.  You
   may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0 

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied. See the License for the specific language governing
   permissions and limitations under the License. 

*)

open Lib
open TermLib
open Actlit

module Solver = SolverMethods.Make(SMTSolver.Make(SMTLIBSolver))

let solver_ref = ref None

(* Output statistics *)
let print_stats () = 

  Event.stat 
    [Stat.misc_stats_title, Stat.misc_stats;
     Stat.bmc_stats_title, Stat.bmc_stats;
     Stat.smt_stats_title, Stat.smt_stats]

(* Clean up before exit *)
let on_exit _ =

  (* Stop all timers. *)
  Stat.bmc_stop_timers ();
  Stat.smt_stop_timers ();

  (* Output statistics *)
  print_stats ();

  (* Delete solver instance if created. *)
  (try
      match !solver_ref with
      | None -> ()
      | Some solver ->
         Solver.delete_solver solver |> ignore ;
         solver_ref := None
    with
    | e -> 
       Event.log L_error
                 "BMC @[<v>Error deleting solver_init:@ %s@]" 
                 (Printexc.to_string e))

(* Returns true if the property is not falsified or valid. *)
let shall_keep trans (s,_) =
  match TransSys.get_prop_status trans s with
  | TransSys.PropInvariant
  | TransSys.PropFalse _ -> false
  | _ -> true

(* Check-sat and splits properties.. *)
let split trans solver k falsifiable to_split actlits =

  (* Function to run if sat. *)
  let if_sat () =
    (* Get-model function. *)
    let get_model = Solver.get_model solver in
    (* Getting the model. *)
    let model = TransSys.vars_of_bounds trans k k
                |> get_model in
    (* Extracting the counterexample. *)
    let cex =
      TransSys.path_from_model trans get_model k in
    (* Evaluation function. *)
    let eval term =
      Eval.eval_term (TransSys.uf_defs trans) model term
      |> Eval.bool_of_value in
    (* Splitting properties. *)
    let new_to_split, new_falsifiable =
      List.partition
        ( fun (_, term) ->
          Term.bump_state k term |> eval )
        to_split in
    (* Building result. *)
    Some (new_to_split, (new_falsifiable, cex))
  in

  (* Function to run if unsat. *)
  let if_unsat () =
    None
  in

  (* Check sat assuming with actlits. *)
  Solver.check_sat_assuming solver if_sat if_unsat actlits

(* Splits its input list of properties between those that can be
   falsified and those that cannot after asserting the actlit
   implications. *)
let split_closure trans solver k actlits to_split =

  let rec loop falsifiable list =
    (* Building negative term. *)
    let term =
      list
      |> List.map snd
      |> Term.mk_and |> Term.mk_not |> Term.bump_state k in
    (* Getting actlit for it. *)
    let actlit = generate_actlit term in
    (* Declaring actlit. *)
    actlit |> Solver.declare_fun solver ;
    (* Asserting implication. *)
    Term.mk_implies
        [ actlit |> term_of_actlit ; term ]
    |> Solver.assert_term solver ;
    (* All actlits. *)
    let all_actlits = (term_of_actlit actlit) ::  actlits in
    (* Splitting. *)
    match split trans solver k falsifiable list all_actlits with
    | None -> list, falsifiable
    | Some ([], new_falsifiable) ->
       [], new_falsifiable :: falsifiable
    | Some (new_list, new_falsifiable) ->
       loop (new_falsifiable :: falsifiable) new_list
  in

  loop [] to_split

(* Performs the next check after updating its context with new
   invariants and falsified properties. Assumes the solver is
   in the following state:

   actlit(prop) => prop@i
     for all 0 <= i <= k-2 and prop      in 'unknowns';

   invariant@i
     for all 0 <= i <= k and invariant in 'invariants';

   T[i-1,i]
     for all 1 <= i <= k.

   Note that the transition relation for the current iteration is
   already asserted. *)
let rec next (trans, solver, k, invariants, unknowns) =

  (* Asserts terms from 0 to k. *)
  let assert_new_invariants =
    List.iter
      (Term.bump_and_apply_k
         (Solver.assert_term solver) k)
  in

  (* Asserts terms at k. *)
  let assert_old_invariants =
    List.iter
      (fun term -> Term.bump_state k term
                   |> Solver.assert_term solver)
  in

  (* Getting new invariants and updating transition system. *)
  let new_invariants =


    let new_invs, updated_props =
      (* Receiving messages. *)
      Event.recv ()
      (* Updating transition system. *)
      |> Event.update_trans_sys trans
      (* Extracting invariant module/term pairs. *)
    in

    updated_props
    (* Looking for new invariant properties. *)
    |> List.fold_left
         ( fun list (_, (name,status)) ->
           if status = TransSys.PropInvariant
           then
             (* Memorizing new invariant property. *)
             ( TransSys.named_term_of_prop_name trans name )
             :: list
           else
             list )
         (* New invariant properties are added to new invariants. *)
         ( Event.top_invariants_of_invariants new_invs )
           
  in

  (* Cleaning unknowns by removing invariants and falsifieds. *)
  let nu_unknowns = unknowns |> List.filter (shall_keep trans) in

  match nu_unknowns with
  | [] -> ()

  | _ ->
     let k_int = Numeral.to_int k in

     (* Notifying framework of our progress. *)
     Stat.set k_int Stat.bmc_k ;
     Event.progress k_int ;
     Stat.update_time Stat.bmc_total_time ;

     (* Output current progress. *)
     Event.log
       L_info
       "BMC @[<v>at k = %i@,\
                 %i unfalsifiable properties.@]"
       (Numeral.to_int k) (List.length nu_unknowns);

     (* Merging old and new invariants and asserting them. *)
     let nu_invariants =
       match invariants, new_invariants with
       | [],[] -> []
       | _, [] ->
          assert_old_invariants invariants ;
          invariants
       | [], _ ->
          assert_new_invariants new_invariants ;
          new_invariants
       | _ ->
          assert_old_invariants invariants ;
          assert_new_invariants new_invariants ;
          List.rev_append new_invariants invariants
     in

     (* Building the positive actlits and corresponding implications
        at k-1. *)
     let actlits, implications =
       nu_unknowns
       |> List.fold_left
            ( fun (actlits,implications) (_,term) ->
              (* Building the actlit. *)
              let actlit_term =
                generate_actlit term |> term_of_actlit
              in

              (* Appending it to the list of actlits. *)
              actlit_term :: actlits,
              (* Building the implication and appending. *)
              (Term.mk_implies
                 [ actlit_term ;
                   Term.bump_state Numeral.(k-one) term])
              :: implications )
            ([], [])
     in

     (* Asserting implications if k > 0. *)
     if Numeral.(k > zero) then
       implications
       |> Term.mk_and
       |> Solver.assert_term solver ;

     (* Splitting. *)
     let unfalsifiable, falsifiable =
       split_closure trans solver k actlits nu_unknowns
     in

     (* Broadcasting k-true properties. *)
     unfalsifiable
     |> List.iter
          ( fun (s, _) ->
            Event.prop_status
              (TransSys.PropKTrue (Numeral.to_int k))
              trans
              s ) ;

     (* Broadcasting falsified properties. *)
     falsifiable
     |> List.iter
          ( fun (p, cex) ->
            List.iter
              ( fun (s,_) ->
                Event.prop_status
                  (TransSys.PropFalse cex) trans s )
              p ) ;

     (* K plus one. *)
     let k_p_1 = Numeral.succ k in
     
     (* Declaring unrolled vars at k+1. *)
     TransSys.declare_vars_of_bounds
       trans (Solver.declare_fun solver) k_p_1 k_p_1 ;
     
     (* Asserting transition relation for next iteration. *)
     TransSys.trans_of_bound trans k_p_1
     |> Solver.assert_term solver
     |> ignore ;

     (* Output statistics *)
     print_stats ();

     (* Int k plus one. *)
     let k_p_1_int = Numeral.to_int k_p_1 in

     (* Checking if we have reached max k. *)
     if Flags.bmc_max () > 0 && k_p_1_int > Flags.bmc_max () then
       Event.log
         L_info
         "BMC @[<v>reached maximal number of iterations.@]"
     else
       (* Looping. *)
       next (trans, solver, k_p_1 , nu_invariants, unfalsifiable)

(* Initializes the solver for the first check. *)
let init trans =
  (* Starting the timer. *)
  Stat.start_timer Stat.bmc_total_time;

  (* Getting properties. *)
  let unknowns =
    (TransSys.props_list_of_bound trans Numeral.zero)
  in

  (* Creating solver. *)
  let solver =
    TransSys.get_logic trans
    |> Solver.new_solver ~produce_assignments:true
  in

  (* Memorizing solver for clean on_exit. *)
  solver_ref := Some solver ;

  (* Declaring positive actlits. *)
  List.iter
    (fun (_, prop) ->
     generate_actlit prop
     |> Solver.declare_fun solver)
    unknowns ;

  (* Declaring variables at 0. *)
  TransSys.declare_vars_of_bounds
    trans (Solver.declare_fun solver) Numeral.zero Numeral.zero ;

  (* Defining functions. *)
  TransSys.iter_uf_definitions
    trans
    (Solver.define_fun solver) ;

  (* Asserting init. *)
  TransSys.init_of_bound trans Numeral.zero
  |> Solver.assert_term solver
  |> ignore ;

  (* Invariants if the system at 0. *)
  let invariants =
    TransSys.invars_of_bound trans Numeral.zero
  in

  (trans, solver, Numeral.zero, [invariants], unknowns)

(* Runs the base instance. *)
let main trans =
  init trans |> next





(* 
   Local Variables:
   compile-command: "make -C .. -k"
   tuareg-interactive-program: "./kind2.top -I ./_build -I ./_build/SExpr"
   indent-tabs-mode: nil
   End: 
*)

