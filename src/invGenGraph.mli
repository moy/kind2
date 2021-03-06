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


(** One state graph-based invariant generation module. *)
module OneState : sig

  (** Invariant generation entry point. *)
  val main : TransSys.t -> unit

  (** Destroys the underlying solver and cleans things up. *)
  val on_exit : TransSys.t option -> unit

  (** Launches invariant generation with a max [k] and a set of
      candidate terms. *)
  val run : TransSys.t -> Numeral.t -> Term.t list -> Term.t list

end

(** Two state graph-based invariant generation module. *)
module TwoState : sig

  (** Invariant generation entry point. *)
  val main : TransSys.t -> unit

  (** Destroys the underlying solver and cleans things up. *)
  val on_exit : TransSys.t option -> unit

  (** Launches invariant generation with a max [k] and a set of
      candidate terms. *)
  val run : TransSys.t -> Numeral.t -> Term.t list -> Term.t list

end

(* 
   Local Variables:
   compile-command: "make -C .. -k"
   tuareg-interactive-program: "./kind2.top -I ./_build -I ./_build/SExpr"
   indent-tabs-mode: nil
   End: 
*)

