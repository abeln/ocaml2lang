open Location
open Longident

module P = Parsetree

module Read = struct

  type structure = {
    str_builtin: bool;
    str_program: P.structure;
  }

  let mk_structure ?(str_builtin=false) str_program =
    { str_builtin; str_program }

  type builtin = string list

  let builtin =
    let cin = open_in "_builtin" in (* FIXME: check if _bultin is present *)
    let l = ref [] in
    try
      while true do
        let line = input_line cin in
        l := line :: !l
      done;
      assert false
    with End_of_file -> let acc = List.rev !l in
      let h = Hashtbl.create 16 in
      List.iter (fun s -> Hashtbl.add h s ()) acc;
      h

  let ptree fname =
    let cin = open_in fname in
    let lb = Lexing.from_channel cin in
    let str_program = Parser.implementation Lexer.token lb in
    let str_builtin = Hashtbl.mem builtin fname in
    mk_structure ~str_builtin str_program

end

open Ast

type info = { (* auxiliary information needed for translation, such as
                 free variables, local variables, paths, etc. *)
  info_lvars : (ident, unit) Hashtbl.t;
  info_gvars : (ident, builtin) Hashtbl.t;
  info_bultin: bool;
  info_known : (string, builtin) Hashtbl.t;
  info_deps  : (string, unit) Hashtbl.t;
  info_env   : env;
  (* TODO: dependencies, in particular for [assert] *)
}

let create_info info_bultin = {
  info_lvars = Hashtbl.create 16;
  info_gvars = Hashtbl.create 16;
  info_bultin;
  info_known = Hashtbl.create 16;
  info_deps  = Hashtbl.create 16;
  info_env   = mk_env ();
}

let add_known info id builtin =
  Hashtbl.add info.info_known id builtin

let mk_lamb binder expr =
  Rec (BAnon, binder, expr)

let rec name_of_pat pat = match pat.P.ppat_desc with
  | Ppat_any -> assert false
  | Ppat_var s -> s.txt
  | Ppat_constraint (p, _) -> name_of_pat p
  | Ppat_construct ({txt = Lident "()"; _}, _) -> "<>"
  | _ -> assert false (* TODO *)

let is_builtin info = info.info_bultin

let mk_bultin env known =
  mk_aneris_program env [] known

let return_builtin info l =
  if is_builtin info then l else []

let value_binding_bultin info P.{pvb_pat; pvb_attributes; _} =
  let is_builtin P.{attr_name = {txt; _}; _} =
    txt = "builtin" || txt = "UnOp" in
  let get_payload payload = match payload with
    | P.PStr
        [{ pstr_desc =
             Pstr_eval
               ({ pexp_desc =
                    Pexp_constant (Pconst_string (spec, _, _)); _ }, _);
           _ };] -> spec
    | _ -> assert false in
  let get_builtin P.{attr_name = {txt; _}; attr_payload; _} = match txt with
    | "builtin" -> BBuiltin (get_payload attr_payload)
    | "UnOp"    -> BUnOp (get_payload attr_payload)
    | _         -> BNone in
  begin try
    let attr = List.find is_builtin pvb_attributes in
    let builtin = get_builtin attr in
    let id = name_of_pat pvb_pat in
    add_known info id builtin;
  with Not_found -> () end;
  []

(* To be completed with all possible builtin translation *)
let node_from_builtin s args = match s, args with
  | "MakeAddress", [expr1; expr2] ->
     MakeAddress (expr1, expr2)
  | "NewSocket", [expr1; expr2; expr3] ->
     NewSocket (expr1, expr2, expr3)
  | "SocketBind", [expr1; expr2] ->
     SocketBind (expr1, expr2)
  | "SendTo", [expr1; expr2; expr3] ->
     SendTo (expr1, expr2, expr3)
  | "ReceiveFrom", [expr] ->
     ReceiveFrom expr
  | "SetReceiveTimeout", [expr1; expr2; expr3] ->
     SetReceiveTimeout (expr1, expr2, expr3)
  | "SubString", [expr1; expr2; expr3] ->
     Substring (expr1, expr2, expr3)
  | "FindFrom", [expr1; expr2; expr3] ->
     FindFrom (expr1, expr2, expr3)
  | "Fork", [expr] ->
     Fork expr
  | _ -> assert false (* TODO *)

let node_from_unop s args = match s, args with
  | "StringLength", [expr] ->
     UnOp (StringLength, expr)
  | "StringOfInt", [expr] ->
     UnOp (StringOfInt, expr)
  | "IntOfString", [expr] ->
     UnOp (IntOfString, expr)
  | _ -> assert false (* TODO *)

let rec structure info str =
  let body = List.flatten (List.map (structure_item info) str) in
  mk_aneris_program info.info_env body info.info_known

and structure_item info str_item =
  let add_info id b = Hashtbl.add info.info_gvars id b in
  let add_known id b = Hashtbl.add info.info_known id b in
  match str_item.P.pstr_desc with
  | Pstr_value (Nonrecursive, [val_bind]) ->
      if is_builtin info then
        value_binding_bultin info val_bind
      else
        let id, expr = value_binding info val_bind in
        add_info id BNone;
        add_known id BNone;
        [(id, expr)]
  | Pstr_value (Recursive, [val_bind]) ->
      if is_builtin info then
        value_binding_bultin info val_bind
      else
        let id, expr = value_binding info val_bind in
        let arg, body = match expr with
          | Rec (_, b, e) -> b, e
          | _ -> assert false in
        add_info id BNone;
        add_known id BNone;
        [(id, Rec (BNamed id, arg, body))]
  | Pstr_type _ ->
      []
  | Pstr_open {popen_expr = {pmod_desc = Pmod_ident m; _}; _} ->
      let fname = string_of_longident m.txt in
      if not (is_builtin info) then begin
        let fname_ml = (String.uncapitalize_ascii fname) ^ ".ml" in
        let {prog_known; prog_body; _} = program fname_ml in
        (* add all known symbols to the gvars tables *)
        let add_info id b = add_info id b in
        Hashtbl.iter add_info prog_known;
        let add_decl acc d = d :: acc in
        let decls = List.fold_left add_decl [] prog_body in
        let decls = List.rev decls in
        add_env info.info_env fname decls
      end;
      (* else ...
              what should we do about [open] inside builtins? *)
      Hashtbl.add info.info_deps fname ();
      []
  | Pstr_exception _ ->
      if is_builtin info then []
      else failwith "Exceptions not supported"
  | _ -> assert false (* TODO *)

and value_binding info {pvb_pat; pvb_expr; _} =
  let add_info id = Hashtbl.add info.info_lvars id () in
  let remove_info id = Hashtbl.remove info.info_lvars id in
  let id = name_of_pat pvb_pat in
  add_info id;
  let expr = expression info pvb_expr in
  remove_info id;
  id, expr

and string_of_longident = function
  | Lapply _ -> assert false (* TODO *)
  | Lident s -> s
  | Ldot (id, s) -> (string_of_longident id) ^ "_" ^ s

and longident info = function
  | Lapply _ -> assert false (* TODO *)
  | Lident s ->
      if Hashtbl.mem info.info_lvars s then Vlvar s
      else if Hashtbl.mem info.info_gvars s then Vgvar (Gvar s)
      else failwith ("Unautorized global symbol: " ^ s)
  | Ldot (t, s) ->
      (* TODO: open external modules *)
      let v = longident info t in
      match v with
      | Vgvar x -> Vgvar (Gdot (x, s))
      | Vlvar _ -> assert false

and expression info expr =
  let is_fst P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "fst"; _} -> true
    | _ -> false in
  let is_snd P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "snd"; _} -> true
    | _ -> false in
  let is_plus P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "+"; _} -> true
    | _ -> false in
  let is_minus P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "-"; _} -> true
    | _ -> false in
  let is_mult P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "*"; _} -> true
    | _ -> false in
  let is_quot P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "/"; _} -> true
    | _ -> false in
  let is_mod P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "mod"; _} -> true
    | _ -> false in
  let is_and P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "&&"; _} -> true
    | _ -> false in
  let is_or P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "||"; _} -> true
    | _ -> false in
  let is_xor P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "<>"; _} -> true
    | _ -> false in
  let is_equal P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "="; _} -> true
    | _ -> false in
  let is_leq P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "<="; _} -> true
    | _ -> false in
  let is_lt P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "<"; _} -> true
    | _ -> false in
  let is_string_app P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "^"; _} -> true
    | _ -> false in
  let is_uminus P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "~-"; _} -> true
    | _ -> false in
  let is_not P.{pexp_desc; _} = match pexp_desc with
    | Pexp_ident {txt = Lident "not"; _} -> true
    | _ -> false in
  let add_info id = Hashtbl.add info.info_lvars id () in
  (* let add_local_args args = List.iter add_info args in *)
  let remove_info id = Hashtbl.remove info.info_lvars id in
  (* let remove_local_args args = List.iter remove_info args in *)
  let mk_app e1 args =
    let find_builtin id = Hashtbl.find info.info_gvars id in
    let mk_app acc e = App (acc, e) in
    let expr1 = expression info e1 in
    let (_, args) = List.split args in
    let exprl = List.map (expression info) args in
    match expr1 with
    | Var (Vgvar (Gvar id)) ->
        begin match find_builtin id with (* this should not raise Not_found *)
        | BNone -> List.fold_left mk_app expr1 exprl
        | BBuiltin s -> node_from_builtin s exprl
        | BUnOp s -> node_from_unop s exprl end
    | _ -> List.fold_left mk_app expr1 exprl in
  match expr.P.pexp_desc with
  | Pexp_constant c -> Val (LitV (constant c))
  | Pexp_construct (c,o) -> construct info (c,o)
  | Pexp_ident t -> Var (longident info t.txt)
  | Pexp_fun (Nolabel, None, pat, expr) ->
      let id = name_of_pat pat in
      add_info id;
      let expr = expression info expr in
      remove_info id;
      Rec (BAnon, BNamed id, expr)
  | Pexp_fun _ ->
      assert false (* TODO *)
  | Pexp_apply (f, [(_, e)]) when is_fst f ->
      Fst (expression info e)
  | Pexp_apply (f, [(_, e)]) when is_snd f ->
      Snd (expression info e)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_plus f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (PlusOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_minus f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (MinusOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_mult f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (MultOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_quot f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (QuotOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_mod f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (RemOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_and f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (AndOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_or f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (OrOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_xor f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (XorOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_equal f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (EqOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_leq f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (LeOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_lt f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (LtOp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1); (_, expr2)]) when is_string_app f ->
      let expr1 = expression info expr1 in
      let expr2 = expression info expr2 in
      BinOp (StringApp, expr1, expr2)
  | Pexp_apply (f, [(_, expr1)]) when is_uminus f ->
      let expr1 = expression info expr1 in
      UnOp (MinusUnOp, expr1)
  | Pexp_apply (f, [(_, expr1)]) when is_not f ->
      let expr1 = expression info expr1 in
      UnOp (NegOp, expr1)
  | Pexp_apply (e1, el) ->
      mk_app e1 el
  | Pexp_tuple (x :: xs) ->
      let mk_tuple acc e = Pair (acc, e) in (* check for values *)
      let fst = expression info x in
      let snd = List.map (expression info) xs in
      List.fold_left mk_tuple fst snd
  | Pexp_tuple [] ->
      assert false (* TODO *)
  | Pexp_match (e, [c1; c2]) ->
      let expr = expression info e in
      Case (expr, pattern info c1, pattern info c2)
  | Pexp_match _ ->
      assert false (* TODO *)
  | Pexp_constraint (e, _) ->
     expression info e
  | Pexp_ifthenelse (e1, e2, Some e3) ->
     let expr1 = expression info e1 in
     let expr2 = expression info e2 in
     let expr3 = expression info e3 in
     If (expr1, expr2, expr3)
  | Pexp_ifthenelse (_, _, None) ->
     assert false
  | Pexp_let (Nonrecursive, [val_bind], e2) ->
      let id, expr = value_binding info val_bind in
      add_info id;
      let expr2 = expression info e2 in
      remove_info id;
      App (mk_lamb (BNamed id) expr2, expr)
  | Pexp_let (Recursive, [{pvb_pat; _} as val_bind], e2) ->
      let fun_name = name_of_pat pvb_pat in
      add_info fun_name;
      let _id, expr = value_binding info val_bind in
      let expr2 = expression info e2 in
      remove_info fun_name;
      begin
        let arg, body = match expr with
          | Rec (_, b, e) -> b, e
          | _ -> assert false in
        match expr2 with
        | Var (Vlvar v) when v = fun_name ->
           Rec (BNamed fun_name, arg, body)
        | _ ->
           App (Rec (BNamed fun_name, arg, body), expr2)
      end
  | Pexp_sequence (e1, e2) ->
     let expr1 = expression info e1 in
     let expr2 = expression info e2 in
     App (mk_lamb BAnon expr2, expr1)
  | Pexp_assert e ->
      Eassert (expression info e)
  | Pexp_open _ ->
      assert false (* TODO *)
  | _ -> assert false (* TODO *)

and pattern info P.{pc_lhs; pc_rhs; _} =
  let is_unit P.{ppat_desc; _} = match ppat_desc with
    | Ppat_construct ({txt = Lident "()"; _}, None) -> true
    | _ -> false in
  let get_var_of_pat P.{ppat_desc; _} = match ppat_desc with
    | Ppat_var {txt; _} -> txt
    | _ -> assert false in
  let add_info id = Hashtbl.add info.info_lvars id () in
  let pat_desc P.{ppat_desc; _} = match ppat_desc with
    | P.Ppat_any -> assert false (* TODO *)
    | Ppat_var _ ->
        assert false (* not autorized as a top-level pattern *)
    | Ppat_construct ({txt = Lident "None"; _}, None) ->
        "None", BAnon
    | Ppat_construct ({txt = Lident "InjL"; _}, Some p) when is_unit p ->
        "InjL", BAnon
    | Ppat_construct ({txt = Lident "InjL"; _}, Some p) ->
        let v = get_var_of_pat p in
        add_info v;
        "InjL", BNamed v
    | Ppat_construct ({txt = Lident "InjR"; _}, Some p) ->
        let v = get_var_of_pat p in
        add_info v;
        "InjR", BNamed v
    | Ppat_construct ({txt = Lident p; _}, Some {ppat_desc = Ppat_var s; _}) ->
        add_info s.txt;
        p, BNamed s.txt
    | _ -> assert false (* TODO *) in
  let txt, binder = pat_desc pc_lhs in
  let pc_rhs = expression info pc_rhs in
  txt, mk_lamb binder pc_rhs

and constant = function
    Pconst_integer (t, _) -> LitInt (int_of_string t)
  | Pconst_string (s, _, _) -> LitString s
  | Pconst_char _ ->  assert false (* not implemented in AnerisLang *)
  | Pconst_float _ -> assert false (* not implemented in AnerisLang *)

and construct info = function
  | ({txt = Lident "()"; loc = _}, None) -> Val (LitV LitUnit)
  | ({txt = Lident "true"; loc = _}, None) -> Val (LitV (LitBool true))
  | ({txt = Lident "false"; loc = _}, None) -> Val (LitV (LitBool false))
  | ({txt = Lident "None"; loc = _}, None) -> ENone
  | ({txt = Lident "Some"; loc = _}, Some expr) ->
      let e = expression info expr in
      begin match e with Val v -> Val (SomeV v) | _ -> ESome e end
  (* | ({txt = Lident "::"; loc = _}, Some e) ->
   *     begin match e.pexp_desc with
   *       | Pexp_tuple [e1;e2] ->
   *           Eapp (mk_gvar "::", [expression info   e1;
   *                                expression info   e2])
   *       | _ -> assert false
   *     end *)
  (* | ({txt = Lident "[]"; loc = _}, None) ->
   *     Evalue NONEV *)
  | ({txt = Lident "InjL"; _}, Some expr) ->
      let e = expression info expr in
      begin match e with Val v -> Val (InjLV v) | _ -> InjL e end
  | ({txt = Lident "InjR"; _}, Some expr) ->
      let e = expression info expr in
      begin match e with Val v -> Val (InjRV v) | _ -> InjR e end
  | ({txt = Lident "PF_INET"; _}, None) ->
     Val (LitV (LitAddressFamily PF_INET))
  | ({txt = Lident "SOCK_DGRAM"; _}, None) ->
     Val (LitV (LitSocketType SOCK_DGRAM))
  | ({txt = Lident "IPPROTO_UDP"; _}, None) ->
     Val (LitV (LitProtocol IPPROTO_UDP))
  | ({txt = Lident s; _}, _) ->
      Format.eprintf "s:%s@." s;
      assert false (* TODO *)
  | _ -> assert false (*TODO : socket address, socket handle? *)

and program fname =
  let open Read in
  let {str_builtin; str_program} = ptree fname in
  let info = create_info str_builtin in
  structure info str_program

let ptree_of_string s =
  let lb = Lexing.from_string s in
  Parser.implementation Lexer.token lb

open Pp_aneris

let%expect_test _ =
  pp_program Format.std_formatter
    (structure (create_info false) (ptree_of_string "let f x = x")).prog_body;
  [%expect {| Definition f : base_lang.val := λ: "x", "x". |}]
