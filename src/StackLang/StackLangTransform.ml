open Printf
open StackLang
open StackLangUtils
open Infix

let fresh_int =
  let n = ref (-1) in
  fun () -> n += 1 ; !n

let fstt (e, _, _) = e

let suffix name i = Printf.sprintf "%s_%i" name i

(** [pop_n_cells stack_type n] return a new stack_type, with [n] top cells
    removed. *)
let pop_n_cells stack_type n =
  let length = Array.length stack_type in
  let new_length = max (length - n) 0 in
  Array.sub stack_type 0 new_length

let restore_pushes push_list block =
  List.fold_left
    (fun block (value, cell, id) ->
      let comment = sprintf "Restoring push_%i" id in
      let block = IPush (value, cell, block) in
      IComment (comment, block))
    block push_list

let find_tagpat_branch branches tag =
  List.find
    (fun (TagMultiple taglist, _) -> List.exists (( = ) tag) taglist)
    branches

let pushcell_apply binds (value, cell, id) =
  (Bindings.apply binds value, cell, id)

(* let enrich_known_cells_with_state_info known_cells possible_states states =
  let state_known_cells =
    (state_info_intersection states possible_states).known_cells
  in
  Array.append known_cells state_known_cells *)

let needed_registers_pushes pushes =
  List.fold_left
    (fun needed_registers (value, _, _) ->
      let value_registers = Value.registers value in
      RegisterSet.union needed_registers value_registers)
    RegisterSet.empty pushes

let commute_pushes_t_block program t_block =
  let pushes_conflit_with_reg pushes reg =
    MList.exists (value_refers_to_register reg) pushes
  in
  let cancelled_pop = ref 0 in
  let eliminated_branches = ref 0 in
  let rec commute_pushes_block pushes bindings final_type known_cells =
    (* [push_list] is the list of pushes that we need to restore, and hopefully
       cancel out with a pop.
       Every definition is inlined in order to make it impossible that a
       commuted pushes refers to a shadowed definition. There should be no
       definition in the resulting code. Registers are still refered to, but
       their value only ever change by performing an ISubstitutedJump, or with
       primitive calls that can not be inlined.
       The code produced by [aux pushes substitution block] is equivalent to
       [restore_pushes pushes (Bindings.restore_defs substitution block)].
       The arguments [final_type] and [known_cells] are used along the way to
       modify correctly the ITypedBlock.
       [final_type] starts as the routine's final type, and if we go through a
       state were the final type is known, it is instanciated.
       If instanciated it is never changed, and replaces the [final_type] field
       of every ITypedBlock along the way.
       [known_cells] starts as the routine's stack type.
       When a pop cannot be cancelled, a cell is removed from [known_cells].
       It is enriched with more information when matching on a type.
       [possible_states] contains the possible values of ["_menhir_s"].
       It is used to filter useless (and in some cases, ill-typed) branches from
       casetag.
       Inlining a definition of shape ["_menhir_s = i"] will not affect it,
       because if we have such a definition, we will not match on ["_menhir_s"],
        as it is defined as ill-typed by [StackLangTraverse.wt]. *)
    function
    | INeed (registers, block) ->
        let block' =
          commute_pushes_block pushes bindings final_type known_cells block
        in
        let registers =
          RegisterSet.union
            (needed_registers_pushes pushes)
            (Bindings.apply_registers bindings registers)
        in
        INeed (registers, block')
    | IPush (value, cell, block) ->
        (*  *)
        let id = fresh_int () in
        let block' =
          commute_pushes_block
            ((Bindings.apply bindings value, cell, id) :: pushes)
            bindings final_type known_cells block
        in
        let comment =
          sprintf "Commuting push_%i %s" id
            (StackLangPrinter.value_to_string value)
        in
        IComment (comment, block')
    | IPop (pattern, block) -> (
      (* A pop is a special kind of definition, so you may think that we need
         to generate new substition rules from it, but there is no need
         because we only keep the pop if there is no push that can conflict
         with it. The pattern we pop into is authoritative and we remove it
         from the substitution. *)
      match pushes with
      | [] ->
          assert (known_cells <> [||]) ;
          (* We lose a known cell here *)
          let known_cells = pop_n_cells known_cells 1 in
          (* However, since we popped the state from the stack, it is now in
             sync with the stack. Therefore, no information we have was
             discovered by inspecting the stack *)
          let block' =
            commute_pushes_block []
              (Bindings.remove bindings pattern)
              final_type known_cells block
          in
          IPop (pattern, block')
      | (value, _cell, id) :: push_list ->
          (* We remove every register refered in the value from the
             substitution, because we need to access the value as it was when
             pushed, and add that to the substitution. *)
          let subst = Bindings.remove_value bindings value in
          let subst = Bindings.extend_pattern subst pattern value in
          (* We have cancelled a pop ! *)
          cancelled_pop += 1 ;
          let block =
            commute_pushes_block push_list subst final_type known_cells block
          in
          let comment =
            sprintf "Cancelled push_%i %s with pop %s" id
              (StackLangPrinter.value_to_string value)
              (StackLangPrinter.pattern_to_string pattern)
          in
          IComment (comment, block) )
    | IDef (bindings', block) ->
        (* As explained above, for every conflict between the definition and a
           push currently commuting, we add a new substitution rule
           We do not want to shadow definition useful for the push train *)
        let bindings = Bindings.compose bindings bindings' in
        let block =
          commute_pushes_block pushes bindings final_type known_cells block
        in
        IComment
          ( sprintf "Inlining def : %s"
              (StackLangPrinter.bindings_to_string bindings')
          , block )
    | IPrim (reg, prim, block) ->
        (* A primitive is a like def except it has a simple register instead of a
           pattern *)
        let reg' =
          if pushes_conflit_with_reg (List.map fstt pushes) reg then
            suffix reg (fresh_int ())
          else reg
        in
        let subst' =
          Bindings.extend reg (VReg reg') (Bindings.remove bindings (PReg reg'))
        in
        let block =
          commute_pushes_block pushes subst' final_type known_cells block
        in
        let prim =
          match prim with
          | PrimOCamlCall (f, args) ->
              let args = List.map (Bindings.apply bindings) args in
              PrimOCamlCall (f, args)
          | PrimOCamlAction (bindings', action) ->
              PrimOCamlAction (Bindings.compose bindings bindings', action)
          | prim ->
              prim
        in
        IPrim (reg', prim, block)
    | ITrace (register, block) ->
        let block' =
          commute_pushes_block pushes bindings final_type known_cells block
        in
        ITrace (register, block')
    | IComment (comment, block) ->
        let block =
          commute_pushes_block pushes bindings final_type known_cells block
        in
        IComment (comment, block)
    | IDie ->
        cancelled_pop += List.length pushes ;
        IDie
    | IReturn v ->
        cancelled_pop += List.length pushes ;
        IReturn (Bindings.apply bindings v)
    | IJump (bindings', label) ->
        let bindings = Bindings.compose bindings bindings' in
        aux_jump pushes bindings label
    | ICaseToken (reg, branches, odefault) ->
        aux_case_token pushes bindings reg branches odefault final_type
          known_cells
    | ICaseTag (reg, branches) ->
        aux_icase_tag pushes bindings final_type known_cells reg branches
    | ITypedBlock t_block ->
        aux_itblock pushes bindings final_type known_cells t_block
  and aux_icase_tag pushes bindings final_type known_cells reg branches =
    match Bindings.apply bindings (VReg reg) with
    | VTag tag ->
        (* If the value of the state is known, then we remove the match. *)
        let block = snd @@ find_tagpat_branch branches tag in
        eliminated_branches += (List.length branches - 1) ;
        let comment = "Eliminated case tag" in
        IComment
          ( comment
          , commute_pushes_block pushes bindings final_type known_cells block )
    | VReg reg ->
        let branch_aux (TagMultiple taglist, block) =
          let state_info = state_info_intersection program.states taglist in
          let known_cells =
            longest_known_cells [state_info.known_cells; known_cells]
          in
          let subst, pushes =
            match taglist with
            | [tag] ->
                (* In this case, we can inline the state value inside the
                   pushes. *)
                let subst = Bindings.extend reg (VTag tag) bindings in
                let tmp_subst = Bindings.singleton reg (VTag tag) in
                let pushes = List.map (pushcell_apply tmp_subst) pushes in
                (subst, pushes)
            | _ ->
                (bindings, pushes)
          in
          let final_type =
            Option.first_value [state_info.sfinal_type; final_type]
          in
          let block =
            commute_pushes_block pushes subst final_type known_cells block
          in
          (TagMultiple taglist, block)
        in
        let branches = List.map branch_aux branches in
        ICaseTag (Bindings.apply_reg bindings reg, branches)
    | _ ->
        assert false
  and aux_itblock pushes subst final_type known_cells t_block =
    let {block; needed_registers; stack_type; final_type= tb_final_type} =
      t_block
    in
    let stack_type = pop_n_cells stack_type (List.length pushes) in
    let needed_registers =
      RegisterSet.union
        (needed_registers_pushes pushes)
        (Bindings.apply_registers subst needed_registers)
    in
    let final_type = Option.first_value [final_type; tb_final_type] in
    let known_cells = longest_known_cells [stack_type; known_cells] in
    let block =
      commute_pushes_block pushes subst final_type known_cells block
    in
    let comment =
      sprintf "Known cells : %s"
        (StackLangPrinter.known_cells_to_string known_cells)
    in
    ITypedBlock
      { t_block with
        block= IComment (comment, block)
      ; final_type
      ; needed_registers
      ; stack_type= known_cells }
  and aux_jump pushes bindings label =
    restore_pushes pushes (Block.jump ~bindings label)
  and aux_case_token pushes subst reg branches odefault final_type known_cells =
    let aux_branch = function
      (* Every [TokSingle] introduces a definition of a register. *)
      | TokSingle (tok, reg'), (block : block) ->
          let reg'' =
            if pushes_conflit_with_reg (List.map fstt pushes) reg' then
              suffix reg' (fresh_int ())
            else reg'
          in
          let subst = Bindings.extend reg' (VReg reg'') subst in
          let block' =
            commute_pushes_block pushes subst final_type known_cells block
          in
          (TokSingle (tok, reg''), block')
      (* [TokMultiple] does not introduce new definitions *)
      | TokMultiple terminals, block ->
          let block' =
            commute_pushes_block pushes subst final_type known_cells block
          in
          (TokMultiple terminals, block')
    in
    let branches = List.map aux_branch branches in
    ICaseToken
      ( reg
      , branches
      , Option.map
          (commute_pushes_block pushes subst final_type known_cells)
          odefault )
  in
  let {block; stack_type; final_type} = t_block in
  let candidate =
    commute_pushes_block [] Bindings.empty final_type stack_type block
  in
  { t_block with
    block=
      ( if !cancelled_pop > 0 || !eliminated_branches > 0 then candidate
      else block ) }

let remove_dead_branches_t_block t_block =
  let rec remove_dead_branches_block possible_states block =
    Block.map
      (remove_dead_branches_block possible_states)
      ~pop:(fun pattern block ->
        let block = remove_dead_branches_block TagSet.all block in
        (pattern, block))
      ~case_tag:(fun reg branches ->
        let branch_aux (TagMultiple taglist, block) =
          let taglist' =
            List.filter (fun tag -> TagSet.mem tag possible_states) taglist
          in
          match taglist' with
          | [] ->
              None
          | _ :: _ ->
              Some
                (let possible_states = TagSet.of_list taglist' in
                 let block = remove_dead_branches_block possible_states block in
                 (TagMultiple taglist', block))
        in
        let branches = List.filter_map branch_aux branches in
        (reg, branches))
      block
  in
  let {block} = t_block in
  {t_block with block= remove_dead_branches_block TagSet.all block}

let remove_dead_branches = Program.map remove_dead_branches_t_block

let commute_pushes program =
  remove_dead_branches @@ Program.map (commute_pushes_t_block program) program

(** remove definitions of shape [x = x], or shape [_ = x] *)
let remove_useless_defs program =
  let rec aux block =
    match block with
    | IDef (binds, block) when binds = Bindings.empty ->
        aux block
    | _ ->
        Block.map aux block
  in
  Program.map (fun t_block -> {t_block with block= aux t_block.block}) program

let compute_has_case_tag_t_block t_block =
  let rec compute_has_case_tag_block = function
    | INeed (regs, block) ->
        let block', hct = compute_has_case_tag_block block in
        (INeed (regs, block'), hct)
    | IPush (value, cell, block) ->
        let block', hct = compute_has_case_tag_block block in
        (IPush (value, cell, block'), hct)
    | IPop (reg, block) ->
        let block', hct = compute_has_case_tag_block block in
        (IPop (reg, block'), hct)
    | IDef (bindings, block) ->
        let block', hct = compute_has_case_tag_block block in
        (IDef (bindings, block'), hct)
    | IPrim (reg, prim, block) ->
        let block', hct = compute_has_case_tag_block block in
        (IPrim (reg, prim, block'), hct)
    | ITrace (reg, block) ->
        let block', hct = compute_has_case_tag_block block in
        (ITrace (reg, block'), hct)
    | IComment (comment, block) ->
        let block', hct = compute_has_case_tag_block block in
        (IComment (comment, block'), hct)
    | (IDie | IReturn _ | IJump _) as block ->
        (block, false)
    | ICaseToken (reg, branches, odefault) ->
        let branches =
          List.map
            (fun (tokpat, block) ->
              let block, hct = compute_has_case_tag_block block in
              ((tokpat, block), hct))
            branches
        in
        let branches, hcts = List.split branches in
        let hct = List.exists Fun.id hcts in
        (ICaseToken (reg, branches, odefault), hct)
    | ICaseTag (reg, branches) ->
        let branches =
          List.map
            (fun (tokpat, block) ->
              let block, _hct = compute_has_case_tag_block block in
              (tokpat, block))
            branches
        in
        (ICaseTag (reg, branches), true)
    | ITypedBlock t_block ->
        let {block} = t_block in
        let block, has_case_tag = compute_has_case_tag_block block in
        (ITypedBlock {t_block with block; has_case_tag}, false)
  in
  let {block} = t_block in
  let block, has_case_tag = compute_has_case_tag_block block in
  {t_block with block; has_case_tag}

let compute_has_case_tag program =
  Program.map compute_has_case_tag_t_block program

let optimize program =
  (* let original_count = count_pushes program in *)
  remove_useless_defs
    ( if Settings.commute_pushes then
      (*let program = inline_tags program in*)
      let program = compute_has_case_tag @@ commute_pushes program in
      (* let commuted_count = count_pushes program in
         if Settings.stacklang_dump then
           Printf.printf
             "Original pushes count : %d\nCommuted pushes count : %d \n"
             original_count commuted_count ; *)
      program
    else program )

let test () =
  let module SL = EmitStackLang.Run () in
  let program = SL.program in
  let optimized_program = optimize program in
  StackLangTester.test program ;
  StackLangTester.test optimized_program
