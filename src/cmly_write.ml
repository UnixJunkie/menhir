open Grammar
open Cmly_format

let terminal (t : Terminal.t) : terminal_def =
  {
    t_kind = (
      if Terminal.equal t Terminal.error then
        `ERROR
      else if
        (match Terminal.eof with
         | None -> false
         | Some eof -> Terminal.equal t eof) then
        `EOF
      else if Terminal.pseudo t then
        `PSEUDO
      else
        `REGULAR
    );
    t_name = Terminal.print t;
    t_type = Terminal.ocamltype t;
    t_attributes = Terminal.attributes t;
  }

let nonterminal (nt : Nonterminal.t) : nonterminal_def =
  let is_start = Nonterminal.is_start nt in
  {
    n_kind = if is_start then `START else `REGULAR;
    n_name = Nonterminal.print false nt;
    n_mangled_name = Nonterminal.print true nt;
    n_type = if is_start then None else Nonterminal.ocamltype nt;
    n_positions = if is_start then [] else Nonterminal.positions nt;
    n_is_nullable = Analysis.nullable nt;
    n_first = List.map Terminal.t2i (TerminalSet.elements (Analysis.first nt));
    n_attributes = if is_start then [] else Nonterminal.attributes nt;
  }

let symbol (sym : Symbol.t) : symbol =
  match sym with
  | Symbol.N n -> N (Nonterminal.n2i n)
  | Symbol.T t -> T (Terminal.t2i t)

let action (a : Action.t) : action =
  {
    a_expr = Action.to_il_expr a;
    a_keywords = Keyword.KeywordSet.elements (Action.keywords a);
    a_filenames = Action.filenames a;
  }

let rhs (prod : Production.index) : producer_def array =
  match Production.classify prod with
  | Some n ->
      [| (N (Nonterminal.n2i n), "", []) |]
  | None ->
      Array.mapi (fun i sym ->
        let id = (Production.identifiers prod).(i) in
        let attributes = (Production.rhs_attributes prod).(i) in
        symbol sym, id, attributes
      ) (Production.rhs prod)

let production (prod : Production.index) : production_def =
  {
    p_kind = if Production.is_start prod then `START else `REGULAR;
    p_lhs = Nonterminal.n2i (Production.nt prod);
    p_rhs = rhs prod;
    p_positions = Production.positions prod;
    p_action = if Production.is_start prod then None
               else Some (action (Production.action prod));
    p_attributes = Production.lhs_attributes prod;
  }

let item (i : Item.t) : production * int =
  let p, i = Item.export i in
  (Production.p2i p, i)

let itemset (is : Item.Set.t) : (production * int) list =
  List.map item (Item.Set.elements is)

let lr0_state (node : Lr0.node) : lr0_state_def =
  {
    lr0_incoming = Option.map symbol (Lr0.incoming_symbol node);
    lr0_items = itemset (Lr0.items node)
  }

let transition (sym, node) : symbol * lr1 =
  (symbol sym, Lr1.number node)

let lr1_state (node : Lr1.node) : lr1_state_def =
  {
    lr1_lr0 = Lr0.core (Lr1.state node);
    lr1_transitions =
      List.map transition (SymbolMap.bindings (Lr1.transitions node));
    lr1_reductions =
      let add t ps rs = (Terminal.t2i t, List.map Production.p2i ps) :: rs in
      TerminalMap.fold_rev add (Lr1.reductions node) []
  }

let entry_point prod node xs : (production * lr1) list =
  (Production.p2i prod, Lr1.number node) :: xs

let encode () : grammar =
  {
    g_basename     = Settings.base;
    g_terminals    = Terminal.init terminal;
    g_nonterminals = Nonterminal.init nonterminal;
    g_productions  = Production.init production;
    g_lr0_states   = Array.init Lr0.n lr0_state;
    g_lr1_states   = Array.of_list (Lr1.map lr1_state);
    g_entry_points = ProductionMap.fold entry_point Lr1.entry [];
    g_attributes   = Analysis.attributes;
    g_parameters   = Front.grammar.UnparameterizedSyntax.parameters;
  }

let write oc t =
  (* .cmly file format: version string ++ grammar *)
  output_string oc Version.version;
  output_value oc (t : grammar)

let write filename =
  let oc = open_out filename in
  write oc (encode());
  close_out oc