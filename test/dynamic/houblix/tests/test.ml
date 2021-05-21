open Printf

let ls dir = Array.to_list (Sys.readdir dir)

let filter_suffix files suffix =
  List.filter (fun f -> Filename.check_suffix f suffix) files


let remove_filter_suffix files suffix =
  List.map Filename.remove_extension @@ filter_suffix files suffix


let uniques = List.sort_uniq compare

let backends = filter_suffix (ls "../backends") ".backend"

let tests_dirs = filter_suffix (ls ".") ".tests"

let test_dir_kind dir =
  match List.rev @@ String.split_on_char '.' dir with
  | "tests" :: kind :: _ ->
      kind
  | _ ->
      assert false


type test =
  { kind : string
  ; name : string
  }

let tests_of_dir dir = remove_filter_suffix (ls dir) ".expected"

let tests = List.concat (List.map tests_of_dir tests_dirs)

let rule_result file kind backend test =
  fprintf
    file
    {|
(rule
  (target %s.%s.output)
  (deps
    (:exe ../../backends/%s/houblix.exe)
    (:input %s.hopix)
    %s.expected)
  (action
    (with-stdout-to %%{target}
      (run %%{exe} --%s %s.hopix))))
|}
    test
    backend
    backend
    test
    test
    kind
    test


let rule_diff file backend test =
  fprintf
    file
    {|
(rule
  (alias test_houblix)
  (deps
    (:expected %s.expected)
    (:result %s.%s.output))
  (action
    (diff %%{expected} %%{result})))
|}
    test
    test
    backend


let global_dune_file = open_out "dune.auto"

let () =
  tests_dirs
  |> List.iter (fun dir ->
         let kind = test_dir_kind dir in
         let tests = tests_of_dir dir in
         let dune_file = open_out @@ Filename.concat dir "dune.auto" in
         tests
         |> List.iter (fun test ->
                backends
                |> List.iter (fun backend ->
                       rule_result dune_file kind backend test ) );
         backends
         |> List.iter (fun backend ->
                tests
                |> List.iter (fun test ->
                       let test = Filename.concat dir test in
                       rule_diff global_dune_file backend test ) ) )

(* backends
   |> List.iter (fun backend ->
          tests
          |> List.iter (fun { kind; name } ->
                 rule_result kind backend name;
                 rule_diff backend name ) ) *)
