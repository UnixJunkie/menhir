(******************************************************************************)
(*                                                                            *)
(*                                   Menhir                                   *)
(*                                                                            *)
(*                       François Pottier, Inria Paris                        *)
(*              Yann Régis-Gianas, PPS, Université Paris Diderot              *)
(*                                                                            *)
(*  Copyright Inria. All rights reserved. This file is distributed under the  *)
(*  terms of the GNU General Public License version 2, as described in the    *)
(*  file LICENSE.                                                             *)
(*                                                                            *)
(******************************************************************************)

open Printf
open StackLang


let fresh_int =
  let n = ref (-1) in
  fun () ->
    n := !n + 1 ;
    !n

let suffix name i =
  Printf.sprintf "%s_%i" name i

let branch_iter f (_pat, block) = 
  f block

let branch_map f (pat, block) = 
  (pat, f block)

(* -------------------------------------------------------------------------- *)

(* Checking that a StackLang program contains no references to undefined
   registers. *)

let wf_regs label rs rs' =
  (* Check that [rs'] is a subset of [rs]. *)
  let stray = RegisterSet.diff rs' rs in
  if not (RegisterSet.is_empty stray) then begin
    eprintf
      "StackLang: in block %s, reference to undefined register%s:\n  %s\n"
      label
      (if RegisterSet.cardinal stray > 1 then "s" else "")
      (RegisterSet.print stray)
    ;
    eprintf
      "StackLang: the following registers are defined:\n  %s\n"
      (RegisterSet.print rs)
    ;
    exit 1
  end

let wf_reg label rs r =
  wf_regs label rs (RegisterSet.singleton r)

let rec wf_value label rs v =
  match v with
  | VTag _ ->
      ()
  | VReg r ->
      wf_reg label rs r
  | VTuple vs ->
      List.iter (wf_value label rs) vs
  | VUnit -> ()

let rec def rs p =
  match p with
  | PWildcard ->
      rs
  | PReg r ->
      (* Check that no name is bound twice by a pattern. *)
      assert (not (RegisterSet.mem r rs));
      RegisterSet.add r rs
  | PTuple ps ->
      List.fold_left def rs ps

let def rs p =
  (* The newly defined registers are the previously defined registers
     plus the registers defined by the pattern [p]. *)
  RegisterSet.union rs (def RegisterSet.empty p)

let wf_prim label rs p =
  match p with
  | PrimOCamlCall (_, args) ->
      List.iter (wf_reg label rs) args
  | PrimOCamlFieldAccess (r, _) ->
      wf_reg label rs r
  | PrimOCamlDummyPos ->
      ()
  | PrimOCamlAction _ ->
      ()

(* [wf_block cfg label rs block] checks that the block [block] does not refer
   to an undefined register, under the assumption that the registers [rs] are
   initially defined. The control flow graph [cfg] is used to map labels to
   blocks. [label] is the label of the current block and is used only as part
   of error messages. *)

let rec wf_block cfg label rs block =
  match block with
  | INeed (rs', block) ->
      wf_regs label rs rs';
      (* A [need] instruction undefines the registers that it does not
         mention, so we continue with [rs']. *)
      let rs = rs' in
      wf_block cfg label rs block
  | IPush (v, block) ->
      wf_value label rs v;
      wf_block cfg label rs block
  | IPop (p, block) ->
      let rs = def rs p in
      wf_block cfg label rs block
  | IDef (p, v, block) ->
      wf_value label rs v;
      let rs = def rs p in
      wf_block cfg label rs block
  | IPrim (r, p, block) ->
      wf_prim label rs p;
      let rs = def rs (PReg r) in
      wf_block cfg label rs block
  | ITrace (_, block)
  | IComment (_, block) ->
      wf_block cfg label rs block
  | IDie ->
      ()
  | IReturn r ->
      wf_reg label rs r
  | IJump label' ->
      (* Check that every register that is needed at the destination label
         is defined here. *)
      wf_regs label rs (needed (lookup label' cfg))
  | ICaseToken (r, branches, odefault) ->
      wf_reg label rs r ;
      List.iter (wf_branch cfg label rs) branches ;
      Option.iter (wf_block cfg label rs) odefault
  | ICaseTag (r, branches) ->
      wf_reg label rs r ;
      List.iter (branch_iter (wf_block cfg label rs)) branches
  | ITypedBlock ({block; stack_type=_; final_type=_}) -> wf_block cfg label rs block

and wf_branch cfg label rs (tokpat, block) =
  let rs =
    match tokpat with
    | TokSingle (_, r) ->
        def rs (PReg r)
    | TokMultiple _ ->
        rs
  in
  wf_block cfg label rs block

(* [wf_block cfg label block] checks that the block [block] at address [label]
   does not refer to an undefined register. We assume that the block begins
   with an [INeed] instruction and use this instruction serves as a reference
   to find out which registers are initially defined. *)

let wf_block (cfg : cfg) label ({block} as t_block) =
  wf_block cfg label (needed t_block) block

(* [wf program] checks that the program [program] contains no references to
   undefined registers. *)

let wf program =
  LabelMap.iter (wf_block program.cfg) program.cfg;
  Time.tick "Checking the StackLang code for well-formedness"

(* -------------------------------------------------------------------------- *)

(* [successors yield block] applies the function [yield] in turn to every
   label that is the target of a [jump] instruction in the block [block]. *)

let rec successors yield block =
  match block with
  | INeed (_, block)
  | IPush (_, block)
  | IPop (_, block)
  | IDef (_, _, block)
  | IPrim (_, _, block)
  | ITrace (_, block)
  | IComment (_, block) ->
      successors yield block
  | IDie | IReturn _ ->
      ()
  | IJump label ->
      yield label
  | ICaseToken (_, branches, oblock) ->
      List.iter (branch_iter (successors yield)) branches ;
      Option.iter (successors yield) oblock
  | ICaseTag (_, branches) ->
      List.iter (branch_iter (successors yield)) branches
  | ITypedBlock ({block; stack_type=_; final_type=_}) ->
      successors yield block

(* -------------------------------------------------------------------------- *)

(* [in_degree program] computes the in-degree of every label in the program
   [program]. It returns a table that maps every reachable label to its
   in-degree. Unreachable labels do not appear in the table. The entry labels
   artifically receive an in-degree of at least 2; this ensures that they
   cannot be inlined by the function [inline] that follows. *)

let in_degree program =

  (* Initialize a queue and a map of labels to degrees. *)
  let queue  : label Queue.t = Queue.create()
  and degree : int LabelMap.t ref = ref LabelMap.empty in

  (* [tick label] increments the degree associated with [label]. If its
     previous degree was zero, then [label] is enqueued for exploration. *)
  let tick label =
    let d =
      try LabelMap.find label !degree
      with Not_found -> Queue.add label queue ; 0
    in
    degree := LabelMap.add label (d + 1) !degree
  in
  (* [visit () label] examines the block at address [label]. *)
  let visit () label = successors tick (lookup label program.cfg).block in
  (* Initialize the queue with the entry labels. Process the queue until it
     becomes empty. Return the final table. *)
  Lr1.NodeMap.iter
    (fun _s label ->
      Queue.add label queue ;
      degree := LabelMap.add label 2 !degree)
    program.entry ;
  Misc.qfold visit () queue ;
  !degree

(* -------------------------------------------------------------------------- *)

(* [inline degree program] transforms the program [program] by removing every
   unreachable block and by inlining every block whose in-degree is 1. It is
   assumed that every entry label has an in-degree of at least 2. *)

let rec inline_block cfg degree block =
  match block with
  | INeed (rs, block) ->
      INeed (rs, inline_block cfg degree block)
  | IPush (v, block) ->
      IPush (v, inline_block cfg degree block)
  | IPop (p, block) ->
      IPop (p, inline_block cfg degree block)
  | IDef (p, v, block) ->
      IDef (p, v, inline_block cfg degree block)
  | IPrim (r, p, block) ->
      IPrim (r, p, inline_block cfg degree block)
  | ITrace (s, block) ->
      ITrace (s, inline_block cfg degree block)
  | IComment (s, block) ->
      IComment (s, inline_block cfg degree block)
  | IDie ->
      IDie
  | IReturn r ->
      IReturn r
  | IJump label ->
      (* If the target label's in-degree is 1, follow the indirection;
         otherwise, keep the [jump] instruction. *)
      if lookup label degree = 1 then
        let typed_block = (lookup label cfg) in
        ITypedBlock { typed_block with
                      block = (inline_block cfg degree typed_block.block) }
      else IJump label
  | ICaseToken (r, branches, odefault) ->
      ICaseToken
        ( r
        , List.map (branch_map (inline_block cfg degree)) branches
        , Option.map (inline_block cfg degree) odefault )
  | ICaseTag (r, branches) ->
      ICaseTag (r, List.map (branch_map (inline_block cfg degree)) branches)
  | ITypedBlock ({ block
                 ; stack_type=_
                 ; final_type=_
                 ; needed_registers=_ }) ->
      inline_block cfg degree block

let inline_cfg degree (cfg : typed_block RegisterMap.t) : cfg =
  LabelMap.fold
    (fun label { block ; stack_type
               ; final_type ; needed_registers
               ; has_case_tag } accu ->
      match LabelMap.find label degree with
      | exception Not_found ->
          (* An unreachable label. *)
          accu
      | d ->
          assert (d > 0) ;
          if d = 1 then accu
          else
            LabelMap.add label
                         { block= inline_block cfg degree block
                         ; stack_type
                         ; final_type
                         ; needed_registers
                         ; has_case_tag }
                         accu  )
    cfg LabelMap.empty

let inline degree {cfg; entry; states} : program = {cfg= inline_cfg degree cfg; entry; states}

(* [inline program] transforms the program [program] by removing every
   unreachable block and by inlining away every (non-entry) label whose
   in-degree is 1. *)

let inline program =
  let program = inline (in_degree program) program in
  Time.tick "Inlining in StackLang";
  program

(* -------------------------------------------------------------------------- *)

(* Measuring the size of a StackLang program. *)

type measure = {
  mutable push: int;
  mutable pop: int;
  mutable def: int;
  mutable prim: int;
  mutable trace: int;
  mutable die: int;
  mutable return: int;
  mutable jump: int;
  mutable casetoken: int;
  mutable casetag: int;
  mutable total: int;
}

let zero () = {
  push = 0;
  pop = 0;
  def = 0;
  prim = 0;
  trace = 0;
  die = 0;
  return = 0;
  jump = 0;
  casetoken = 0;
  casetag = 0;
  total = 0;
}

let print m =
  let pad i = Misc.padded_index m.total i in
  printf "PUSH    %s\n" (pad m.push);
  printf "POP     %s\n" (pad m.pop);
  printf "DEF     %s\n" (pad m.def);
  printf "PRIM    %s\n" (pad m.prim);
  printf "TRCE    %s\n" (pad m.trace);
  printf "DIE     %s\n" (pad m.die);
  printf "RET     %s\n" (pad m.return);
  printf "JUMP    %s\n" (pad m.jump);
  printf "CASEtok %s\n" (pad m.casetoken);
  printf "CASEtag %s\n" (pad m.casetag);
  printf "total   %s\n" (pad m.total);
  ()

let rec measure_block m block =
  match block with
  | INeed (_, block) ->
      measure_block m block
  | IPush (_, block) ->
      m.total <- m.total + 1;
      m.push <- m.push + 1;
      measure_block m block
  | IPop (_, block) ->
      m.total <- m.total + 1;
      m.pop <- m.pop + 1;
      measure_block m block
  | IDef (_, _, block) ->
      m.total <- m.total + 1;
      m.def <- m.def + 1;
      measure_block m block
  | IPrim (_, _, block) ->
      m.total <- m.total + 1;
      m.prim <- m.prim + 1;
      measure_block m block
  | ITrace (_, block) ->
      m.total <- m.total + 1;
      m.trace <- m.trace + 1;
      measure_block m block
  | IComment (_, block) ->
      measure_block m block
  | IDie ->
      m.total <- m.total + 1 ;
      m.die <- m.die + 1
  | IReturn _ ->
      m.total <- m.total + 1 ;
      m.return <- m.return + 1
  | IJump _ ->
      m.total <- m.total + 1 ;
      m.jump <- m.jump + 1
  | ICaseToken (_, branches, odefault) ->
      m.total <- m.total + 1 ;
      m.casetoken <- m.casetoken + 1 ;
      List.iter (branch_iter (measure_block m)) branches ;
      Option.iter (measure_block m) odefault
  | ICaseTag (_, branches) ->
      m.total <- m.total + 1 ;
      m.casetag <- m.casetag + 1 ;
      List.iter (branch_iter (measure_block m)) branches
  | ITypedBlock ({block; stack_type=_; final_type=_}) ->
    measure_block m block

let measure program =
  let m = zero () in
  LabelMap.iter (fun _ block -> measure_block m block.block) program.cfg ;
  m

let get_args_map block_map =
  StringMap.map
    (function
    | INeed (registers, _block) ->
          StringSet.elements registers
      | _ ->
          assert false)
    block_map

let rec _is_pattern_equivalent_to_value pattern value =
    match pattern, value with
    | PWildcard, _ -> true
    | PReg reg_pat, VReg reg_val
      when reg_pat = reg_val -> true
    | PTuple li_pat, VTuple li_val
      when ( List.length li_pat = List.length li_val ) ->
        List.for_all2
          _is_pattern_equivalent_to_value
          li_pat
          li_val
    | _, _ -> false

(* let rec is_intersection_non_empty pattern value =
  match pattern, value with
  | PWildcard, _ -> false
  | PReg reg_pat, VReg reg_val
    when reg_pat = reg_val -> true
  | pattern, VTuple li_val ->
      List.exists
        (is_intersection_non_empty pattern)
        li_val
  | PTuple li, value ->
      List.exists
        (fun pattern ->
            is_intersection_non_empty pattern value)
        li
  | _, _ -> false *)

let rec intersection pattern value =
  match pattern, value with
  | PWildcard, _ -> RegisterSet.empty
  | PReg reg_pat, VReg reg_val
    when reg_pat = reg_val -> RegisterSet.singleton reg_pat
  | pattern, VTuple li_val ->
      List.fold_left
        RegisterSet.union
        RegisterSet.empty
        (List.map (intersection pattern) li_val)
  | PTuple li_pat, value ->
      List.fold_left
        RegisterSet.union
        RegisterSet.empty
        ( List.map
            ( fun pattern ->
                intersection pattern value ) 
            li_pat )
  | _, _ -> RegisterSet.empty

(* 
let is_intersection_empty pattern value =
  not (is_intersection_non_empty pattern value) *)

let rec value_refers_to_register register value =
  match value with
  | VReg register'
    when register = register' -> true
  | VTuple li -> List.exists (value_refers_to_register register) li
  | _ -> false

let block_map f = function
    | INeed (registers, block) ->
        INeed(registers, f block)
    | IPush (value, block) ->
        IPush(value, f block)
    | IPop (register, block) ->
        IPop(register, f block)
    | IDef (pattern, value, block) ->
        IDef (pattern, value, f block)
    | IPrim (register, primitive, block) ->
        IPrim (register, primitive, f block)
    | ITrace (register, block) ->
        ITrace (register, f block)
    | IComment (comment, block) ->
        IComment (comment, f block)
    | IDie -> IDie
    | IReturn r ->
        IReturn r
    | IJump j ->
        IJump j
    | ICaseToken (reg, branches, odefault) ->
        ICaseToken ( reg
                , List.map
                    ( fun (tokpat, block) ->
                        (tokpat, f block) )
                    branches
                , Option.map f odefault )
    | ICaseTag (reg, branches) ->
        ICaseTag ( reg
                , List.map
                    ( fun (tokpat, block) ->
                        (tokpat, f block) )
                    branches )
    | ITypedBlock t_block ->
        ITypedBlock ({ t_block
                    with block = f t_block.block })

module Substitution :
sig
    type t

    (** empty substitution *)
    val empty : t

    (** [add register value s] adds a rule [register -> value] to [s]*)
    val add : register -> value -> t -> t

    (** [remove s pattern] remove every rule of the shape [r -> _] for every [r] a register occuring in [pattern] *)
    val remove : t -> pattern -> t

    (** [substitute s value] apply to rules of the substitution [s] to [value] recursively *)
    val substitute : t -> value -> value

    (** [substitute s pattern] apply the rules of the substitution [s] to [pattern] recursively.
        It assumes that every relevant rule has shape [_ -> VReg(_)] *)
    val substitute_pattern : t -> pattern -> pattern

    (** [restore_defs s block] generate a definition block with a definition [let x = y] for every rule [x -> y] in [s]*)
    val restore_defs : t -> block -> block

    (** [tight_restore_defs s registers block] generate a definition block with a definition 
        [let x = y] for every rule [x -> y] in [s] such that [x] is in [registers] *)
    val tight_restore_defs : t -> registers -> block -> block
end =
struct
    type t = value RegisterMap.t

    let empty = RegisterMap.empty
    let add register value map = 
        RegisterMap.add register value map
        (* match value with 
        | VReg register' when register = register' -> map
        | _ -> RegisterMap.add register value map *)

    let rec remove substitution pattern =
        match pattern with
        | PReg reg -> RegisterMap.remove reg substitution
        | PWildcard -> substitution
        | PTuple li -> List.fold_left remove substitution li
    let rec substitute substitution =
    function
    | VReg register ->
        Option.value
          (RegisterMap.find_opt register substitution)
          ~default:(VReg register)
    | VTuple li -> VTuple (List.map (substitute substitution) li)
    | v -> v

    let rec substitute_pattern substitution =
      function
      | PReg register ->
            (match RegisterMap.find_opt register substitution with
            | Some (VReg reg) -> PReg reg
            | Some _ -> failwith "Could not transform value into pattern"
            | None -> PReg register)
      | PTuple li -> PTuple ( List.map 
                                (substitute_pattern substitution) 
                                li )
      | v -> v
  
    let restore_defs substitution block =
        RegisterMap.fold
            (fun register value block ->
               IDef(PReg register, value, block) )
            substitution
            block
    let tight_restore_defs substitution registers block =
      RegisterSet.fold
          (fun register block ->
              let value = substitute substitution (VReg register) in
              if value = VReg register then
                block
              else
                IDef(PReg register, value, block) )
          registers
          block

end
let inline_tags program =
    let rec aux substitution block =
        match block with
        | IDef (PReg name, VTag tag, block) ->
            aux (Substitution.add name (VTag tag) substitution) block
        | IDef (pattern, value, block) ->
            IDef ( pattern
                 , Substitution.substitute substitution value
                 , aux (Substitution.remove substitution pattern) block )
        | IPush (value, block) ->
            IPush ( Substitution.substitute substitution value
                  , aux substitution block )
        | IPrim (register, primitive, block) ->
            IPrim ( register
                  , primitive
                  , aux ( Substitution.remove
                            substitution
                            (PReg register) )
                        block )
        | IPop(pattern, block) ->
            IPop( pattern, aux
                             (Substitution.remove substitution pattern)
                             block )
        | IJump reg ->
            Substitution.tight_restore_defs
              substitution
              (needed (StringMap.find reg program.cfg))
              (IJump reg)
        | ITypedBlock ({has_case_tag=true} as t_block) ->
            Substitution.restore_defs
              substitution
              ( ITypedBlock { t_block
                              with block = aux Substitution.empty t_block.block } )
        | _ -> block_map (aux substitution) block

    in
    { program
      with cfg =
        RegisterMap.map
          ( fun t_block -> { t_block
                             with block = aux Substitution.empty t_block.block } )
          program.cfg }

let restore_pushes push_list block =
    List.fold_left
      (fun block value -> IPush(value, block))
      block
      push_list

let rec string_of_value value =
    match value with
    | VTag t -> string_of_int t
    | VReg s -> s
    | VTuple li -> "(" ^ (String.concat ", " (List.map string_of_value li)) ^ ")"
    | VUnit -> "()"

(* Add fresh name in [substitution] for every register that is part of the intersection of [values] and [pattern] *)
let update_substitution substitution pattern values =
  (* Add a new rule to the substitution for every element of the intersection of [pattern] and [value] *)
  let add_intersection pattern substitution value =
    RegisterSet.fold (
            fun register substitution ->
            Substitution.add 
                register 
                (VReg (suffix register (fresh_int () ))) 
                substitution ) 
        (intersection pattern value) substitution 
  in
  let substitution = 
      List.fold_left 
      (add_intersection pattern)
      substitution 
      values 
  in
  substitution
let commute_pushes program =
    let rec aux (push_list: value list) substitution = 
        (* [push_list] is the list of pushes that we need to restore, 
           and hopefully cancel out with a pop.
           Every time there is a definition of a new value, 
          in order to not disturb the pushes, 
          if the pattern is in conflict with one of the pushed value, 
          we change the name of the culprit register, and we save the change in a [Substitution.t].
          In subsequent code, every time we refer to a register, 
          we use the name from the substitution's right-hand side. *)
        function
        | INeed (_registers, block) ->
           (* Deleted for now *)
            aux push_list substitution block
        | IPush (value, block) ->
            (* We push the substituted name *)
            IComment (sprintf "Commuted push of %s" (string_of_value value),
            aux 
              ( ( Substitution.substitute 
                    substitution 
                    value ) :: push_list ) 
              substitution 
              block)
        | IPop (pattern, block) ->
            (* A pop is a special kind of definition,
               so you may think that we need to generate new substition rules from it, 
               but there is no need because we only keep the pop if there is no push that can conflict with it. *)
            (match push_list with
             | [] -> IPop (pattern, aux [] substitution block)
             | value :: push_list ->
                 IDef(pattern, value, aux push_list substitution block))
        | IDef (pattern, value', block) ->
            (* As explained above, for every conflict between the definition and a push currently commuting, 
               we add a new substitution rule *)
            (* Currently, the value is raw, 
               we need to apply the substitution to it in order for it to refer to the correct definition. *)   
            let value' = Substitution.substitute substitution value' in
            let substitution = update_substitution substitution pattern push_list in
            IDef ( Substitution.substitute_pattern substitution pattern
                 , value'
                 , aux push_list substitution block )
        | IPrim (register, primitive, block) ->
          (* A primitive is a like def except it has a simple register instead of a pattern *)
          let register' =
            if List.exists 
                 (value_refers_to_register register) 
                 push_list then
              suffix register (fresh_int () )
            else register
          in
          let substitution = 
            Substitution.add register (VReg register') substitution 
          in
          IPrim(register', primitive, aux push_list substitution block)
        | ITrace (register, block) ->
            ITrace (register, aux push_list substitution block)
        | IComment (comment, block) ->
            IComment (comment, aux push_list substitution block)
        | IDie ->
            IDie
        | IReturn r ->
            IReturn r
        | IJump j ->
            (* We first restore the pushes we failed to eliminate, 
               then we restore every value to its original name, 
               so that the jump does not fail. *)
            restore_pushes 
              push_list 
              ( Substitution.tight_restore_defs
                  substitution
                  (needed (StringMap.find j program.cfg))
                  (IJump j) )
        | ICaseToken (reg, branches, odefault) ->
            ICaseToken ( reg
                       , List.map
                           ( function 
                               (* Every [TokSingle] introduces a definition of a register. *)
                               | TokSingle (tok , register'), block -> 
                                   let new_register =
                                     if List.exists 
                                       (value_refers_to_register register') 
                                       push_list then
                                     suffix register' (fresh_int () )
                                   else register'
                                 in
                                 let substitution = 
                                   Substitution.add 
                                     register' 
                                     (VReg new_register) 
                                     substitution 
                                 in
                                 ( TokSingle(tok, new_register)
                                 , aux push_list substitution block )
                               (* [TokMultiple] does not introduce new definitions*)
                               | TokMultiple terminals, block ->
                                   ( TokMultiple terminals
                                   , aux push_list substitution block )  )
                           branches
                       , Option.map
                           (aux push_list substitution)
                           odefault )
        | ICaseTag (reg, branches) ->
            (* [ICaseTag] does not introduce new definitions *)
            ICaseTag ( reg
                     , List.map
                         ( fun (tagpat, block) ->
                             (tagpat, aux push_list substitution block) )
                         branches )
        | ITypedBlock ({stack_type} as t_block) ->
            (* We alter the type information according to the number of commuting pushes :
               Every push that is commuting removes a known stack symbol *)
            ITypedBlock ({ t_block
                           with block = aux push_list substitution t_block.block
                           ;    stack_type = Array.sub
                                               stack_type
                                               0
                                               ( max 
                                                   0 
                                                   ( (Array.length stack_type) 
                                                   - (List.length push_list) ) ) })
        in
      { program
        with cfg =
        RegisterMap.map
            ( fun t_block -> { t_block
                               with block = aux [] Substitution.empty t_block.block } )
            program.cfg }
    

let count_pushes program =
    let rec aux block i =
        match block with
        | INeed (_, block) ->
            aux block i
        | IPush (_, block) ->
            aux block (i+1)
        | IPop (_, block) ->
            aux block i
        | IDef (_, _, block) ->
            aux block i
        | IPrim (_, _, block) ->
            aux block i
        | ITrace (_, block) ->
            aux block i
        | IComment (_, block) ->
            aux block i
        | IDie -> i
        | IReturn _ ->
            i
        | IJump _ ->
            i
        | ICaseToken (_, branches, _)  ->
            ( List.fold_left
               (+)
               0
               (List.map
                  ( fun (_, block) ->
                      aux block i )
                  branches ) ) / (List.length branches)
        | ICaseTag (_, branches) ->
            ( List.fold_left
               (+)
               0
               (List.map
                  ( fun (_, block) ->
                      aux block i )
                  branches ) ) / (List.length branches)
        | ITypedBlock {block} ->
            aux block i
    in
    RegisterMap.fold (fun _ {block} acc -> acc + aux block 0 ) program.cfg 0

let optimize program =
    let original_count = count_pushes program in
    let program = inline_tags program in
    (*print_endline "Before commute" ;
    StackLangPrinter.print stdout program ;*)
    let program = commute_pushes program in
    (* print_endline "After commute" ;
    StackLangPrinter.print stdout program ; *)

    let commuted_count = count_pushes program in
    (*assert (original_count = commuted_count) ;*)
    Printf.printf
      "Original pushes count : %d\n\
       Commuted pushes count : %d \n"
       original_count commuted_count ;
    program