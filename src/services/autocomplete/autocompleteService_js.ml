(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Base.Result
open Loc_collections

let loc_of_aloc = Parsing_heaps.Reader.loc_of_aloc

let max_autoimport_suggestions = 100

let default_autoimport_options =
  let open Fuzzy_path in
  {
    default_options with
    max_results = max_autoimport_suggestions;
    num_threads = Base.Int.max 1 (Sys_utils.nbr_procs - 2);
  }

let lsp_completion_of_type =
  let open Ty in
  function
  | InlineInterface _ -> Some Lsp.Completion.Interface
  | StrLit _
  | NumLit _
  | BoolLit _ ->
    Some Lsp.Completion.Value
  | Fun _ -> Some Lsp.Completion.Function
  | Union _ -> Some Lsp.Completion.Enum
  | Tup _
  | Bot _
  | Null
  | Obj _
  | Inter _
  | TVar _
  | Bound _
  | Generic _
  | Any _
  | Top
  | Void
  | Symbol
  | Num _
  | Str _
  | Bool _
  | Arr _
  | TypeOf _
  | Utility _
  | IndexedAccess _
  | Mu _
  | CharSet _ ->
    Some Lsp.Completion.Variable

let lsp_completion_of_decl =
  let open Ty in
  function
  | VariableDecl _ -> Lsp.Completion.Variable
  | TypeAliasDecl _ -> Lsp.Completion.Enum
  | ClassDecl _ -> Lsp.Completion.Class
  | InterfaceDecl _ -> Lsp.Completion.Interface
  | EnumDecl _ -> Lsp.Completion.Enum
  | ModuleDecl _ -> Lsp.Completion.Module

let sort_text_of_rank rank = Some (Printf.sprintf "%020u" rank)

let text_edit ?insert_text name (insert, replace) =
  let newText = Base.Option.value ~default:name insert_text in
  { ServerProt.Response.newText; insert; replace }

let detail_of_ty ~exact_by_default ty =
  let type_ = Ty_printer.string_of_t_single_line ~with_comments:false ~exact_by_default ty in
  let cli_detail = type_ in
  let lsp_detail =
    (* [lsp_detail] is rendered immediately after the name, with no space.
       for most types, we add a [:] so it renders like an annotation;
       but for functions, no [:] makes it look like a signature.

       TODO: if we know a function property vs a member, we could
       render the prop with a [:] as a subtle signal that you can
       unbind it. *)
    match ty with
    | Ty.Fun _ -> type_
    | _ -> ": " ^ type_
  in
  (cli_detail, Some lsp_detail)

let detail_of_ty_decl ~exact_by_default d =
  let type_ = Ty_printer.string_of_decl_single_line ~with_comments:false ~exact_by_default d in
  (* decls aren't function signatures, so cli_detail and lsp_detail are the same *)
  let cli_detail = type_ in
  let lsp_detail =
    match d with
    | Ty.ClassDecl _ -> None
    | _ -> Some type_
  in
  (cli_detail, lsp_detail)

let autocomplete_create_result
    ?insert_text
    ?(rank = 0)
    ?(preselect = false)
    ?documentation
    ?tags
    ~exact_by_default
    ~log_info
    (name, edit_locs)
    ty =
  let (cli_detail, lsp_detail) = detail_of_ty ~exact_by_default ty in
  let kind = lsp_completion_of_type ty in
  let text_edit = Some (text_edit ?insert_text name edit_locs) in
  let sort_text = sort_text_of_rank rank in
  {
    ServerProt.Response.Completion.kind;
    name;
    text_edit;
    additional_text_edits = [];
    detail = cli_detail;
    sort_text;
    preselect;
    documentation;
    tags;
    log_info;
    source = None;
    type_ = lsp_detail;
  }

let autocomplete_create_result_decl
    ?insert_text
    ~rank
    ?(preselect = false)
    ?documentation
    ?tags
    ~exact_by_default
    ~log_info
    (name, edit_locs)
    d =
  let open Ty in
  let (kind, (cli_detail, lsp_detail)) =
    match d with
    | ModuleDecl _ -> (Some Lsp.Completion.Module, ("module " ^ name, None))
    | Ty.VariableDecl (_, ty) -> (Some Lsp.Completion.Variable, detail_of_ty ~exact_by_default ty)
    | d -> (Some (lsp_completion_of_decl d), detail_of_ty_decl ~exact_by_default d)
  in
  let text_edit = Some (text_edit ?insert_text name edit_locs) in
  let sort_text = sort_text_of_rank rank in
  {
    ServerProt.Response.Completion.kind;
    name;
    text_edit;
    additional_text_edits = [];
    detail = cli_detail;
    sort_text;
    preselect;
    documentation;
    tags;
    log_info;
    source = None;
    type_ = lsp_detail;
  }

let autocomplete_create_result_elt
    ?insert_text
    ?(rank = 0)
    ?preselect
    ?documentation
    ?tags
    ~exact_by_default
    ~log_info
    (name, edit_locs)
    elt =
  match elt with
  | Ty.Type t ->
    autocomplete_create_result
      ?insert_text
      ~rank
      ?preselect
      ?documentation
      ?tags
      ~exact_by_default
      ~log_info
      (name, edit_locs)
      t
  | Ty.Decl d ->
    autocomplete_create_result_decl
      ?insert_text
      ~rank
      ?preselect
      ?documentation
      ?tags
      ~exact_by_default
      ~log_info
      (name, edit_locs)
      d

let ty_normalizer_options =
  {
    Ty_normalizer_env.expand_internal_types = true;
    flag_shadowed_type_params = true;
    preserve_inferred_literal_types = false;
    evaluate_type_destructors = true;
    optimize_types = true;
    omit_targ_defaults = false;
    merge_bot_and_any_kinds = true;
    verbose_normalizer = false;
    max_depth = Some 50;
  }

type ac_result = {
  result: ServerProt.Response.Completion.t;
  errors_to_log: string list;
}

type autocomplete_service_result =
  | AcResult of ac_result
  | AcEmpty of string
  | AcFatalError of string

let jsdoc_of_def_loc ~reader ~typed_ast def_loc =
  loc_of_aloc ~reader def_loc
  |> Find_documentation.jsdoc_of_getdef_loc ~current_ast:typed_ast ~reader

let jsdoc_of_member ~reader ~typed_ast info =
  Base.Option.bind info.Ty_members.def_loc ~f:(jsdoc_of_def_loc ~reader ~typed_ast)

let jsdoc_of_loc ~options ~reader ~cx ~file_sig ~ast ~typed_ast loc =
  let open GetDef_js.Get_def_result in
  match GetDef_js.get_def ~options ~reader ~cx ~file_sig ~ast ~typed_ast loc with
  | Def getdef_loc
  | Partial (getdef_loc, _) ->
    Find_documentation.jsdoc_of_getdef_loc ~current_ast:typed_ast ~reader getdef_loc
  | Bad_loc
  | Def_error _ ->
    None

let documentation_and_tags_of_jsdoc jsdoc =
  let docs = Find_documentation.documentation_of_jsdoc jsdoc in
  let tags =
    Base.Option.map (Jsdoc.deprecated jsdoc) ~f:(fun _ -> [Lsp.CompletionItemTag.Deprecated])
  in
  (docs, tags)

let documentation_and_tags_of_member ~reader ~typed_ast info =
  jsdoc_of_member ~reader ~typed_ast info
  |> Base.Option.value_map ~default:(None, None) ~f:documentation_and_tags_of_jsdoc

let documentation_and_tags_of_loc ~options ~reader ~cx ~file_sig ~ast ~typed_ast loc =
  jsdoc_of_loc ~options ~reader ~cx ~file_sig ~ast ~typed_ast loc
  |> Base.Option.value_map ~default:(None, None) ~f:documentation_and_tags_of_jsdoc

let documentation_and_tags_of_def_loc ~reader ~typed_ast def_loc =
  jsdoc_of_def_loc ~reader ~typed_ast def_loc
  |> Base.Option.value_map ~default:(None, None) ~f:documentation_and_tags_of_jsdoc

let members_of_type
    ~reader
    ~exclude_proto_members
    ?(force_instance = false)
    ?(exclude_keys = SSet.empty)
    ~tparams_rev
    cx
    file_sig
    typed_ast
    type_ =
  let ty_members =
    Ty_members.extract
      ~include_proto_members:(not exclude_proto_members)
      ~force_instance
      ~cx
      ~typed_ast
      ~file_sig
      Type.TypeScheme.{ tparams_rev; type_ }
  in
  let include_valid_member (s, info) =
    let open Reason in
    match s with
    | OrdinaryName "constructor"
    | InternalName _
    | InternalModuleName _ ->
      None
    (* TODO consider making the $-prefixed names internal *)
    | OrdinaryName str when (String.length str >= 1 && str.[0] = '$') || SSet.mem str exclude_keys
      ->
      None
    | OrdinaryName str -> Some (str, info)
  in
  match ty_members with
  | Error error -> fail error
  | Ok Ty_members.{ members; errors; in_idx } ->
    return
      ( members
        |> NameUtils.Map.bindings
        |> Base.List.filter_map ~f:include_valid_member
        |> List.map (fun (name, info) ->
               let (document, tags) = documentation_and_tags_of_member ~reader ~typed_ast info in
               (name, document, tags, info)
           ),
        (match errors with
        | [] -> []
        | _ :: _ -> Printf.sprintf "members_of_type %s" (Debug_js.dump_t cx type_) :: errors),
        in_idx
      )

(* The fact that we need this feels convoluted.
   We run Scope_builder on the untyped AST and now we go back to the typed AST to get the types
   of the locations we got from Scope_api. We wouldn't need to do this separate pass if
   Scope_builder/Scope_api were polymorphic.
*)
class type_collector (reader : Parsing_heaps.Reader.reader) (locs : LocSet.t) =
  object
    inherit [ALoc.t, ALoc.t * Type.t, ALoc.t, ALoc.t * Type.t] Flow_polymorphic_ast_mapper.mapper

    val mutable acc = LocMap.empty

    method on_loc_annot x = x

    method on_type_annot x = x

    method collected_types = acc

    method! t_identifier (((aloc, t), _) as ident) =
      let loc = loc_of_aloc ~reader aloc in
      if LocSet.mem loc locs then acc <- LocMap.add loc t acc;
      ident
  end

let collect_types ~reader locs typed_ast =
  let collector = new type_collector reader locs in
  Stdlib.ignore (collector#program typed_ast);
  collector#collected_types

let local_value_identifiers
    ~options ~reader ~cx ~genv ~ac_loc ~file_sig ~ast ~typed_ast ~tparams_rev =
  let scope_info =
    Scope_builder.program ~enable_enums:(Context.enable_enums cx) ~with_types:false ast
  in
  let open Scope_api.With_Loc in
  (* get the innermost scope enclosing the requested location *)
  let (ac_scope_id, _) =
    IMap.fold
      (fun this_scope_id this_scope (prev_scope_id, prev_scope) ->
        if
          Reason.in_range ac_loc this_scope.Scope.loc
          && Reason.in_range this_scope.Scope.loc prev_scope.Scope.loc
        then
          (this_scope_id, this_scope)
        else
          (prev_scope_id, prev_scope))
      scope_info.scopes
      (0, scope scope_info 0)
  in
  (* gather all in-scope variables *)
  let names_and_locs =
    fold_scope_chain
      scope_info
      (fun _ scope acc ->
        let scope_vars = scope.Scope.defs in

        (* don't suggest lexically-scoped variables declared after the current location.
           this filtering isn't perfect:

             let foo = /* request here */
                 ^^^
                 def_loc

           since def_loc is the location of the identifier within the declaration statement
           (not the entire statement), we don't filter out foo when declaring foo. *)
        let relevant_scope_vars =
          SMap.filter
            (fun _name { Def.locs; kind; _ } ->
              Bindings.allow_forward_ref kind || Loc.compare (Nel.hd locs) ac_loc < 0)
            scope_vars
        in

        let relevant_scope_vars =
          SMap.map (fun { Def.locs; _ } -> Nel.hd locs) relevant_scope_vars
        in
        SMap.union acc relevant_scope_vars)
      ac_scope_id
      SMap.empty
  in
  let types = collect_types ~reader (LocSet.of_list (SMap.values names_and_locs)) typed_ast in
  names_and_locs
  |> SMap.bindings
  |> Base.List.filter_map ~f:(fun (name, loc) ->
         (* TODO(vijayramamurthy) do something about sometimes failing to collect types *)
         Base.Option.map (LocMap.find_opt loc types) ~f:(fun type_ ->
             let (documentation, tags) =
               documentation_and_tags_of_loc ~options ~reader ~cx ~file_sig ~ast ~typed_ast loc
             in
             ((name, documentation, tags), Type.TypeScheme.{ tparams_rev; type_ })
         )
     )
  |> Ty_normalizer.from_schemes ~options:ty_normalizer_options ~genv

(* Roughly collects upper bounds of a type.
 * This logic will be changed or made unnecessary once we have contextual typing *)
let upper_bound_t_of_t ~cx =
  let rec upper_bounds_of_t : ISet.t -> Type.t -> Type.t list =
    let open Base.List.Let_syntax in
    fun seen -> function
      | Type.OpenT (_, id) ->
        (* A given tvar might be reachable from many paths through uses. If
         * we've seen this tvar before, we should not re-add the uses we've
         * already seen. *)
        if ISet.mem id seen then
          []
        else
          let seen = ISet.add id seen in
          let%bind use = Flow_js_utils.possible_uses cx id in
          upper_bounds_of_use_t seen use
      | t -> return t
  and upper_bounds_of_use_t : ISet.t -> Type.use_t -> Type.t list =
   fun seen -> function
    | Type.ReposLowerT (_, _, use) -> upper_bounds_of_use_t seen use
    | Type.UseT (_, t) -> upper_bounds_of_t seen t
    | _ -> []
  in
  fun lb_type ->
    let seen = ISet.empty in
    let reason = TypeUtil.reason_of_t lb_type in
    match upper_bounds_of_t seen lb_type with
    | [] -> Type.MixedT.make reason (Trust.bogus_trust ())
    | [upper_bound] -> upper_bound
    | ub1 :: ub2 :: ubs -> Type.IntersectionT (reason, Type.InterRep.make ub1 ub2 ubs)

let rec literals_of_ty acc ty =
  match ty with
  | Ty.Union (_, t1, t2, ts) -> Base.List.fold_left (t1 :: t2 :: ts) ~f:literals_of_ty ~init:acc
  | Ty.StrLit _
  | Ty.NumLit _
  | Ty.BoolLit _ ->
    ty :: acc
  | Ty.Bool _ -> Ty.BoolLit true :: Ty.BoolLit false :: acc
  | _ -> acc

let autocomplete_literals ~prefer_single_quotes ~cx ~genv ~tparams_rev ~edit_locs ~upper_bound =
  let scheme = { Type.TypeScheme.tparams_rev; type_ = upper_bound } in
  let options = ty_normalizer_options in
  let upper_bound_ty =
    match Ty_normalizer.from_scheme ~options ~genv scheme with
    | Ok (Ty.Type ty) -> ty
    | Ok (Ty.Decl _)
    | Error _ ->
      Ty.Top
  in
  (* TODO: since we're inserting values, we shouldn't really be using the Ty_printer *)
  let exact_by_default = Context.exact_by_default cx in
  (*let literals = Base.List.fold tys ~init:[] ~f:literals_of_ty in*)
  let literals = literals_of_ty [] upper_bound_ty in
  Base.List.map literals ~f:(fun ty ->
      let name =
        Ty_printer.string_of_t_single_line
          ~prefer_single_quotes
          ~with_comments:false
          ~exact_by_default
          ty
      in
      (* TODO: if we had both the expanded and unexpanded type alias, we'd
         use the unexpanded alias for `ty` and the expanded literal for `name`. *)
      autocomplete_create_result
        ~insert_text:name
        ~rank:0
        ~preselect:true
        ~exact_by_default
        ~log_info:"literal from upper bound"
        (name, edit_locs)
        ty
  )

let src_dir_of_loc ac_loc =
  Loc.source ac_loc |> Base.Option.map ~f:(fun key -> File_key.to_string key |> Filename.dirname)

let flow_text_edit_of_lsp_text_edit { Lsp.TextEdit.range; newText } =
  let loc = Flow_lsp_conversions.lsp_range_to_flow_loc range in
  (loc, newText)

let completion_item_of_autoimport
    ~options ~reader ~src_dir ~ast ~edit_locs { Export_search.name; source; kind } rank =
  match
    Code_action_service.text_edits_of_import ~options ~reader ~src_dir ~ast kind name source
  with
  | None ->
    {
      ServerProt.Response.Completion.kind = Some Lsp.Completion.Variable;
      name;
      detail = "(global)" (* TODO: include the type *);
      text_edit = Some (text_edit name edit_locs);
      additional_text_edits = [];
      sort_text = sort_text_of_rank rank;
      preselect = false;
      documentation = None;
      tags = None;
      log_info = "global";
      source = None;
      type_ = None;
    }
  | Some { Code_action_service.title; edits; from } ->
    let additional_text_edits = Base.List.map ~f:flow_text_edit_of_lsp_text_edit edits in
    {
      ServerProt.Response.Completion.kind = Some Lsp.Completion.Variable;
      name;
      detail = title (* TODO: include the type *);
      text_edit = Some (text_edit name edit_locs);
      additional_text_edits;
      sort_text = sort_text_of_rank rank;
      preselect = false;
      documentation = None;
      tags = None;
      log_info = "autoimport";
      source = Some from;
      type_ = None (* TODO: include the type *);
    }

let add_locals ~f locals set =
  Base.List.iter ~f:(fun local -> Base.Hash_set.add set (f local)) locals

let set_of_locals ~f locals =
  let set = Base.Hash_set.create ~size:(Base.List.length locals) (module Base.String) in
  add_locals ~f locals set;
  set

let is_reserved name kind =
  if Export_index.kind_is_value kind then
    Parser_env.is_reserved name || Parser_env.is_strict_reserved name
  else
    Parser_env.is_reserved_type name

let append_completion_items_of_autoimports
    ~options ~reader ~ast ~ac_loc ~locals ~imports_ranked_usage ~edit_locs auto_imports acc =
  let src_dir = src_dir_of_loc ac_loc in
  let sorted_auto_imports =
    if imports_ranked_usage then
      let open Export_search in
      (* sort by score, then base the rank on the ordering so each one has a unique rank *)
      auto_imports
      |> Base.List.sort ~compare:(fun (import_a, score_a) (import_b, score_b) ->
             match Int.compare score_a score_b with
             | 0 -> String.compare import_a.name import_b.name
             | score_diff -> -1 * score_diff
         )
      |> Base.List.mapi ~f:(fun index (autoimport, _score) -> (autoimport, index))
    else
      (* legacy behavior is to not sort and not rank. all imports have the same
         constant rank. *)
      Base.List.map ~f:(fun (autoimport, _score) -> (autoimport, 0)) auto_imports
  in
  Base.List.fold_left
    ~init:acc
    ~f:(fun acc (auto_import, rank) ->
      let { Export_search.name; kind; source = _ } = auto_import in
      if is_reserved name kind || Base.Hash_set.mem locals name then
        (* exclude reserved words and already-defined locals, because they can't be imported
           without aliasing them, which we can't do automatically in autocomplete. for example,
           `import {null} from ...` is invalid; and if we already have `const foo = ...` then
           we can't auto-import another value named `foo`. *)
        acc
      else
        let item =
          completion_item_of_autoimport
            ~options
            ~reader
            ~src_dir
            ~ast
            ~edit_locs
            auto_import
            (100 + rank)
        in
        item :: acc)
    sorted_auto_imports

(* env is all visible bound names at cursor *)

let filter_by_token item_list token =
  let open ServerProt.Response.Completion in
  let open Fuzzy_path in
  let (before, _after) = Autocomplete_sigil.remove token in
  let candidates = Base.List.map ~f:(fun item -> item.name) item_list in
  let fuzzy_matcher = Fuzzy_path.init candidates in
  let filtered_candidates = Fuzzy_path.search before fuzzy_matcher in
  let filtered_candidates =
    List.fold_left (fun acc item -> SSet.add item.value acc) SSet.empty filtered_candidates
  in
  let item_list = List.filter (fun item -> SSet.mem item.name filtered_candidates) item_list in
  item_list

let autocomplete_id
    ~env
    ~options
    ~reader
    ~cx
    ~ac_loc
    ~file_sig
    ~ast
    ~typed_ast
    ~include_super
    ~include_this
    ~imports
    ~imports_ranked_usage
    ~tparams_rev
    ~edit_locs
    ~token
    ~type_ =
  (* TODO: filter to results that match `token` *)
  let open ServerProt.Response.Completion in
  let ac_loc = loc_of_aloc ~reader ac_loc |> Autocomplete_sigil.remove_from_loc in
  let exact_by_default = Context.exact_by_default cx in
  let genv = Ty_normalizer_env.mk_genv ~full_cx:cx ~file:(Context.file cx) ~typed_ast ~file_sig in
  let upper_bound = upper_bound_t_of_t ~cx type_ in
  let prefer_single_quotes = Options.format_single_quotes options in
  let results =
    autocomplete_literals ~prefer_single_quotes ~cx ~genv ~tparams_rev ~edit_locs ~upper_bound
  in
  let rank =
    if results = [] then
      0
    else
      1
  in
  let identifiers =
    local_value_identifiers
      ~options
      ~reader
      ~cx
      ~genv
      ~ac_loc
      ~file_sig
      ~typed_ast
      ~ast
      ~tparams_rev
  in
  let (items_rev, errors_to_log) =
    identifiers
    |> List.fold_left
         (fun (items_rev, errors_to_log) ((name, documentation, tags), elt_result) ->
           match elt_result with
           | Ok elt ->
             let result =
               autocomplete_create_result_elt
                 ~insert_text:name
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"local value identifier"
                 (name, edit_locs)
                 elt
             in
             (result :: items_rev, errors_to_log)
           | Error err ->
             let error_to_log = Ty_normalizer.error_to_string err in
             (items_rev, error_to_log :: errors_to_log))
         (results, [])
  in
  (* "this" is legal inside classes and (non-arrow) functions *)
  let items_rev =
    if include_this then
      {
        kind = Some Lsp.Completion.Variable;
        name = "this";
        detail = "this";
        text_edit = Some (text_edit "this" edit_locs);
        additional_text_edits = [];
        sort_text = sort_text_of_rank rank;
        preselect = false;
        documentation = None;
        tags = None;
        log_info = "this";
        source = None;
        type_ = None (* TODO: include the class type *);
      }
      :: items_rev
    else
      items_rev
  in
  (* "super" is legal inside classes *)
  let items_rev =
    if include_super then
      {
        kind = Some Lsp.Completion.Variable;
        name = "super";
        detail = "super";
        text_edit = Some (text_edit "super" edit_locs);
        additional_text_edits = [];
        sort_text = sort_text_of_rank rank;
        preselect = false;
        documentation = None;
        tags = None;
        log_info = "super";
        source = None;
        type_ = None (* TODO: include the parent class type *);
      }
      :: items_rev
    else
      items_rev
  in
  let items_rev = filter_by_token items_rev token in
  let (items_rev, is_incomplete) =
    if imports then
      let (before, _after) = Autocomplete_sigil.remove token in
      if before = "" then
        (* for empty autocomplete requests (hitting ctrl-space without typing anything),
           don't include any autoimport results, but do set `is_incomplete` so that
           it queries again when you type something. *)
        (items_rev, true)
      else
        let locals = set_of_locals ~f:(fun ((name, _docs, _tags), _ty) -> name) identifiers in
        let { Export_search.results = auto_imports; is_incomplete } =
          Export_search.search_values
            ~options:default_autoimport_options
            before
            env.ServerEnv.exports
        in
        let items_rev =
          append_completion_items_of_autoimports
            ~options
            ~reader
            ~ast
            ~ac_loc
            ~locals
            ~imports_ranked_usage
            ~edit_locs
            auto_imports
            items_rev
        in
        (items_rev, is_incomplete)
    else
      (* if autoimports are not enabled, then we have all the results *)
      (items_rev, false)
  in
  let result = { ServerProt.Response.Completion.items = List.rev items_rev; is_incomplete } in
  { result; errors_to_log }

let type_exports_of_module_ty ~edit_locs ~exact_by_default ~documentation_and_tags_of_module_member
    =
  let open ServerProt.Response.Completion in
  let open Ty in
  function
  | Decl (ModuleDecl { exports; _ }) ->
    Base.List.filter_map
      ~f:(function
        | TypeAliasDecl { name = { Ty.sym_name; sym_def_loc; _ }; type_ = Some t; _ } as d ->
          (* TODO consider omitting items with internal names throughout *)
          let sym_name = Reason.display_string_of_name sym_name in
          let (cli_detail, lsp_detail) = detail_of_ty_decl ~exact_by_default d in
          let (documentation, tags) = documentation_and_tags_of_module_member sym_def_loc in
          Some
            {
              kind = lsp_completion_of_type t;
              name = sym_name;
              text_edit = Some (text_edit sym_name edit_locs);
              additional_text_edits = [];
              detail = cli_detail;
              sort_text = None;
              preselect = false;
              documentation;
              tags;
              log_info = "qualified type alias";
              source = None;
              type_ = lsp_detail;
            }
        | InterfaceDecl ({ Ty.sym_name; sym_def_loc; _ }, _) as d ->
          let sym_name = Reason.display_string_of_name sym_name in
          let (cli_detail, lsp_detail) = detail_of_ty_decl ~exact_by_default d in
          let (documentation, tags) = documentation_and_tags_of_module_member sym_def_loc in
          Some
            {
              kind = Some Lsp.Completion.Interface;
              name = sym_name;
              text_edit = Some (text_edit sym_name edit_locs);
              additional_text_edits = [];
              detail = cli_detail;
              sort_text = None;
              preselect = false;
              documentation;
              tags;
              log_info = "qualified interface";
              source = None;
              type_ = lsp_detail;
            }
        | ClassDecl ({ Ty.sym_name; sym_def_loc; _ }, _) as d ->
          let sym_name = Reason.display_string_of_name sym_name in
          let (cli_detail, lsp_detail) = detail_of_ty_decl ~exact_by_default d in
          let (documentation, tags) = documentation_and_tags_of_module_member sym_def_loc in
          Some
            {
              kind = Some Lsp.Completion.Class;
              name = sym_name;
              text_edit = Some (text_edit sym_name edit_locs);
              additional_text_edits = [];
              detail = cli_detail;
              sort_text = None;
              preselect = false;
              documentation;
              tags;
              log_info = "qualified class";
              source = None;
              type_ = lsp_detail;
            }
        | EnumDecl { Ty.sym_name; sym_def_loc; _ } as d ->
          let sym_name = Reason.display_string_of_name sym_name in
          let (cli_detail, lsp_detail) = detail_of_ty_decl ~exact_by_default d in
          let (documentation, tags) = documentation_and_tags_of_module_member sym_def_loc in
          Some
            {
              kind = Some Lsp.Completion.Enum;
              name = sym_name;
              text_edit = Some (text_edit sym_name edit_locs);
              additional_text_edits = [];
              detail = cli_detail;
              sort_text = None;
              preselect = false;
              documentation;
              tags;
              log_info = "qualified enum";
              source = None;
              type_ = lsp_detail;
            }
        | _ -> None)
      exports
    |> Base.List.sort ~compare:(fun { name = a; _ } { name = b; _ } -> String.compare a b)
    |> Base.List.mapi ~f:(fun i r -> { r with sort_text = sort_text_of_rank i })
  | _ -> []

(* TODO(vijayramamurthy) think about how to break this file down into smaller modules *)
(* NOTE: excludes classes, because we'll get those from local_value_identifiers *)
class local_type_identifiers_searcher =
  object (this)
    inherit [ALoc.t, ALoc.t * Type.t, ALoc.t, ALoc.t * Type.t] Flow_polymorphic_ast_mapper.mapper

    method on_loc_annot x = x

    method on_type_annot x = x

    val mutable rev_ids = []

    method rev_ids = rev_ids

    method add_id id = rev_ids <- id :: rev_ids

    method! type_alias (Flow_ast.Statement.TypeAlias.{ id; _ } as x) =
      this#add_id id;
      x

    method! opaque_type (Flow_ast.Statement.OpaqueType.{ id; _ } as x) =
      this#add_id id;
      x

    method! interface (Flow_ast.Statement.Interface.{ id; _ } as x) =
      this#add_id id;
      x

    method! import_declaration _ x =
      let open Flow_ast.Statement.ImportDeclaration in
      let { import_kind; specifiers; default; _ } = x in
      let binds_type = function
        | ImportType
        | ImportTypeof ->
          true
        | ImportValue -> false
      in
      let declaration_binds_type = binds_type import_kind in
      if declaration_binds_type then Base.Option.iter default ~f:this#add_id;
      Base.Option.iter specifiers ~f:(function
          | ImportNamedSpecifiers specifiers ->
            List.iter
              (fun { kind; local; remote } ->
                let specifier_binds_type =
                  match kind with
                  | None -> declaration_binds_type
                  | Some k -> binds_type k
                in
                if specifier_binds_type then this#add_id (Base.Option.value local ~default:remote))
              specifiers
          | ImportNamespaceSpecifier _ -> ( (* namespaces can't be types *) )
          );
      x
  end

let make_builtin_type ~edit_locs name =
  {
    ServerProt.Response.Completion.kind = Some Lsp.Completion.Variable;
    name;
    detail = name;
    text_edit = Some (text_edit name edit_locs);
    additional_text_edits = [];
    sort_text = sort_text_of_rank 0;
    preselect = false;
    documentation = None;
    tags = None;
    log_info = "builtin type";
    source = None;
    type_ = None;
  }

let builtin_types =
  [
    "any";
    "boolean";
    "empty";
    "false";
    "mixed";
    "null";
    "number";
    "bigint";
    "string";
    "true";
    "void";
    "symbol";
  ]

let make_utility_type ~edit_locs name =
  {
    ServerProt.Response.Completion.kind = Some Lsp.Completion.Function;
    name;
    detail = name;
    text_edit = Some (text_edit name edit_locs);
    additional_text_edits = [];
    sort_text = sort_text_of_rank 200 (* below globals *);
    preselect = false;
    documentation = None;
    tags = None;
    log_info = "builtin type";
    source = None;
    type_ = None;
  }

let utility_types =
  [
    "Class";
    "$Call";
    "$CharSet";
    "$Diff";
    "$ElementType";
    "$Exact";
    "$Exports";
    "$KeyMirror";
    "$Keys";
    "$NonMaybeType";
    "$ObjMap";
    "$ObjMapi";
    "$PropertyType";
    "$ReadOnly";
    "$Rest";
    "$Shape";
    "$TupleMap";
    "$Values";
  ]

let make_type_param ~edit_locs { Type.name; _ } =
  let name = Subst_name.string_of_subst_name name in
  {
    ServerProt.Response.Completion.kind = Some Lsp.Completion.TypeParameter;
    name;
    detail = name;
    text_edit = Some (text_edit name edit_locs);
    additional_text_edits = [];
    sort_text = sort_text_of_rank 0;
    preselect = false;
    documentation = None;
    tags = None;
    log_info = "unqualified type parameter";
    source = None;
    type_ = None;
  }

let local_type_identifiers ~typed_ast ~cx ~file_sig =
  let search = new local_type_identifiers_searcher in
  Stdlib.ignore (search#program typed_ast);
  search#rev_ids
  |> Base.List.rev_map ~f:(fun ((loc, t), Flow_ast.Identifier.{ name; _ }) -> ((name, loc), t))
  |> Ty_normalizer.from_types
       ~options:ty_normalizer_options
       ~genv:(Ty_normalizer_env.mk_genv ~full_cx:cx ~file:(Context.file cx) ~typed_ast ~file_sig)

let autocomplete_unqualified_type
    ~env
    ~options
    ~reader
    ~cx
    ~imports
    ~imports_ranked_usage
    ~tparams_rev
    ~file_sig
    ~ac_loc
    ~ast
    ~typed_ast
    ~edit_locs
    ~token =
  (* TODO: filter to results that match `token` *)
  let ac_loc = loc_of_aloc ~reader ac_loc |> Autocomplete_sigil.remove_from_loc in
  let exact_by_default = Context.exact_by_default cx in
  let items_rev =
    []
    |> Base.List.rev_map_append builtin_types ~f:(make_builtin_type ~edit_locs)
    |> Base.List.rev_map_append utility_types ~f:(make_utility_type ~edit_locs)
    |> Base.List.rev_map_append tparams_rev ~f:(make_type_param ~edit_locs)
  in
  let type_identifiers = local_type_identifiers ~typed_ast ~cx ~file_sig in
  let (items_rev, errors_to_log) =
    type_identifiers
    |> List.fold_left
         (fun (items_rev, errors_to_log) ((name, aloc), ty_result) ->
           let (documentation, tags) =
             loc_of_aloc ~reader aloc
             |> documentation_and_tags_of_loc ~options ~reader ~cx ~file_sig ~ast ~typed_ast
           in
           match ty_result with
           | Ok elt ->
             let result =
               autocomplete_create_result_elt
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"unqualified type: local type identifier"
                 (name, edit_locs)
                 elt
             in
             (result :: items_rev, errors_to_log)
           | Error err ->
             let error_to_log = Ty_normalizer.error_to_string err in
             (items_rev, error_to_log :: errors_to_log))
         (items_rev, [])
  in
  let genv = Ty_normalizer_env.mk_genv ~full_cx:cx ~file:(Context.file cx) ~typed_ast ~file_sig in
  let value_identifiers =
    local_value_identifiers
      ~options
      ~ast
      ~typed_ast
      ~reader
      ~genv
      ~ac_loc
      ~tparams_rev
      ~cx
      ~file_sig
  in
  (* The value-level identifiers we suggest in type autocompletion:
      - classes
      - enums
      - modules (followed by a dot) *)
  let (items_rev, errors_to_log) =
    value_identifiers
    |> List.fold_left
         (fun (items_rev, errors_to_log) ((name, documentation, tags), ty_res) ->
           match ty_res with
           | Error err ->
             let error_to_log = Ty_normalizer.error_to_string err in
             (items_rev, error_to_log :: errors_to_log)
           | Ok (Ty.Decl (Ty.ClassDecl _ | Ty.EnumDecl _) as elt) ->
             let result =
               autocomplete_create_result_elt
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"unqualified type: class or enum"
                 (name, edit_locs)
                 elt
             in
             (result :: items_rev, errors_to_log)
           | Ok elt
             when type_exports_of_module_ty
                    ~edit_locs
                    ~exact_by_default
                    ~documentation_and_tags_of_module_member:(fun _ -> (None, None))
                    elt
                  <> [] ->
             let result =
               autocomplete_create_result_elt
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"unqualified type -> qualified type"
                 (name, edit_locs)
                 elt
                 ~insert_text:(name ^ ".")
             in
             (result :: items_rev, errors_to_log)
           | Ok _ -> (items_rev, errors_to_log))
         (items_rev, errors_to_log)
  in
  let items_rev = filter_by_token items_rev token in
  let (items_rev, is_incomplete) =
    if imports then
      let locals =
        let set = set_of_locals ~f:(fun ((name, _aloc), _ty) -> name) type_identifiers in
        add_locals ~f:(fun ((name, _docs, _tags), _ty) -> name) value_identifiers set;
        set
      in
      let { Export_search.results = auto_imports; is_incomplete } =
        let (before, _after) = Autocomplete_sigil.remove token in
        Export_search.search_types ~options:default_autoimport_options before env.ServerEnv.exports
      in
      let items_rev =
        append_completion_items_of_autoimports
          ~options
          ~reader
          ~ast
          ~ac_loc
          ~locals
          ~imports_ranked_usage
          ~edit_locs
          auto_imports
          items_rev
      in
      (items_rev, is_incomplete)
    else
      (items_rev, false)
  in
  let result = { ServerProt.Response.Completion.items = Base.List.rev items_rev; is_incomplete } in
  { result; errors_to_log }

(** If the token is a string literal, then the end of the token may be inaccurate
    due to parse errors. See tests/autocomplete/bracket_syntax_3.js for example. *)
let fix_loc_of_string_token token loc =
  match token.[0] with
  | '\''
  | '"' ->
    { loc with Loc._end = loc.Loc.start }
  | _ -> loc

let fix_locs_of_string_token token (insert_loc, replace_loc) =
  let insert_loc = fix_loc_of_string_token token insert_loc in
  let replace_loc = fix_loc_of_string_token token replace_loc in
  (insert_loc, replace_loc)

let autocomplete_member
    ~env
    ~reader
    ~options
    ~cx
    ~file_sig
    ~ast
    ~typed_ast
    ~imports
    ~imports_ranked_usage
    ~edit_locs
    ~token
    this
    in_optional_chain
    ac_aloc
    ~tparams_rev
    ~bracket_syntax
    ~member_loc
    ~is_type_annotation
    ~force_instance =
  let edit_locs = fix_locs_of_string_token token edit_locs in
  let exact_by_default = Context.exact_by_default cx in
  (* When autocompleting a type annotation, it is extremely unlikely that someone wants the type
   * of a member from the prototype of the object type. If they really want that they can get the
   * type from the prototype directly. *)
  let exclude_proto_members = is_type_annotation in
  match
    members_of_type
      ~reader
      ~exclude_proto_members
      ~force_instance
      cx
      file_sig
      typed_ast
      this
      ~tparams_rev
  with
  | Error err -> AcFatalError err
  | Ok (mems, errors_to_log, in_idx) ->
    let items =
      mems
      |> Base.List.map
           ~f:(fun
                ( name,
                  documentation,
                  tags,
                  Ty_members.{ ty; from_proto; from_nullable; def_loc = _ }
                )
              ->
             let rank =
               if from_proto then
                 1
               else
                 0
             in
             let opt_chain_ty =
               Ty_utils.simplify_type ~merge_kinds:true (Ty.Union (false, Ty.Void, ty, []))
             in
             let name_as_indexer =
               lazy
                 (let expression =
                    match Base.String.chop_prefix ~prefix:"@@" name with
                    | None -> Ast_builder.Expressions.literal (Ast_builder.Literals.string name)
                    | Some symbol ->
                      Ast_builder.Expressions.member_expression_ident_by_name
                        (Ast_builder.Expressions.identifier "Symbol")
                        symbol
                  in
                  expression
                  |> Js_layout_generator.expression
                       ~opts:(Code_action_service.layout_options options)
                  |> Pretty_printer.print ~source_maps:None ~skip_endline:true
                  |> Source.contents
                 )
             in
             let name_is_valid_identifier = Parser_flow.string_is_valid_identifier_name name in
             let edit_loc_of_member_loc member_loc =
               if Loc.(member_loc.start.line = member_loc._end.line) then
                 Autocomplete_sigil.remove_from_loc member_loc
               else
                 Loc.{ member_loc with _end = member_loc.start }
             in
             match
               ( from_nullable,
                 in_optional_chain,
                 in_idx,
                 bracket_syntax,
                 member_loc,
                 name_is_valid_identifier
               )
             with
             (* TODO: only complete obj destructuring pattern when name is valid identifier *)
             | (_, _, _, _, None, _)
             | (false, _, _, None, _, true)
             | (_, true, _, None, _, true)
             | (_, _, true, None, _, true) ->
               let ty =
                 if from_nullable && in_optional_chain then
                   opt_chain_ty
                 else
                   ty
               in
               autocomplete_create_result
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"member"
                 (name, edit_locs)
                 ty
             | (false, _, _, Some _, _, _)
             | (_, true, _, Some _, _, _)
             | (_, _, true, Some _, _, _) ->
               let insert_text = Lazy.force name_as_indexer in
               autocomplete_create_result
                 ~insert_text
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"bracket syntax member"
                 (insert_text, edit_locs)
                 ty
             | (false, _, _, None, Some member_loc, false)
             | (_, true, _, None, Some member_loc, false)
             | (_, _, true, None, Some member_loc, false) ->
               let insert_text = Printf.sprintf "[%s]" (Lazy.force name_as_indexer) in
               let edit_loc = edit_loc_of_member_loc member_loc in
               autocomplete_create_result
                 ~insert_text
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"dot-member switched to bracket-syntax member"
                 (insert_text, (edit_loc, edit_loc))
                 ty
             | (true, false, false, _, Some member_loc, _) ->
               let opt_chain_name =
                 match (bracket_syntax, name_is_valid_identifier) with
                 | (None, true) -> Printf.sprintf "?.%s" name
                 | (Some _, _)
                 | (_, false) ->
                   Printf.sprintf "?.[%s]" (Lazy.force name_as_indexer)
               in
               let edit_loc = Autocomplete_sigil.remove_from_loc member_loc in
               autocomplete_create_result
                 ~insert_text:opt_chain_name
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"start optional chain"
                 (opt_chain_name, (edit_loc, edit_loc))
                 opt_chain_ty
         )
    in
    (match bracket_syntax with
    | None ->
      let result = { ServerProt.Response.Completion.items; is_incomplete = false } in
      AcResult { result; errors_to_log }
    | Some Autocomplete_js.{ include_this; include_super; type_; _ } ->
      let {
        result = { ServerProt.Response.Completion.items = id_items; is_incomplete };
        errors_to_log = id_errors_to_log;
      } =
        if is_type_annotation then
          autocomplete_unqualified_type
            ~env
            ~options
            ~reader
            ~cx
            ~imports
            ~imports_ranked_usage
            ~tparams_rev
            ~ac_loc:ac_aloc
            ~ast
            ~typed_ast
            ~file_sig
            ~edit_locs
            ~token
        else
          autocomplete_id
            ~env
            ~options
            ~reader
            ~cx
            ~ac_loc:ac_aloc
            ~file_sig
            ~ast
            ~typed_ast
            ~include_super
            ~include_this
            ~imports
            ~imports_ranked_usage
            ~tparams_rev
            ~edit_locs
            ~token
            ~type_
      in
      let result = { ServerProt.Response.Completion.items = items @ id_items; is_incomplete } in
      let errors_to_log = errors_to_log @ id_errors_to_log in
      AcResult { result; errors_to_log })

let rec binds_react = function
  | File_sig.With_ALoc.BindIdent (_, name) -> name = "React"
  | File_sig.With_ALoc.BindNamed bindings ->
    Base.List.exists ~f:(fun (_remote, local) -> binds_react local) bindings

(** Determines whether to autoimport React when autocompleting a JSX element.

    By default JSX transforms into [React.createElement] which needs [React] to be
    in scope. However, when [react.runtime=automatic] is set in [.flowconfig], this
    happens behind the scenes.

    We use a bit of a heuristic here. If [React] is imported or required anywhere
    in the file, we won't autoimport it, even if it's not in scope for the JSX
    component being completed. This is because imports are top-level so we'd cause
    potential shadowing issues elsewhere in the file. *)
let should_autoimport_react ~options ~imports ~file_sig =
  if imports then
    match Options.react_runtime options with
    | Options.ReactRuntimeAutomatic -> false
    | Options.ReactRuntimeClassic ->
      let open File_sig.With_ALoc in
      let requires_react =
        Base.List.exists
          ~f:(function
            | Require { bindings = Some bindings; _ } -> binds_react bindings
            | Import { ns = Some (_, "React"); _ } -> true
            | Import { named; _ } ->
              SMap.exists
                (fun _remote local -> SMap.exists (fun name _locs -> name = "React") local)
                named
            | Require { bindings = None; _ }
            | Import0 _
            | ImportDynamic _
            | ExportFrom _ ->
              false)
          file_sig.module_sig.requires
      in
      not requires_react
  else
    false

let autocomplete_jsx_element
    ~env
    ~options
    ~reader
    ~cx
    ~ac_loc
    ~file_sig
    ~ast
    ~typed_ast
    ~imports
    ~imports_ranked_usage
    ~tparams_rev
    ~edit_locs
    ~token
    ~type_ =
  let ({ result; errors_to_log } as results) =
    autocomplete_id
      ~env
      ~options
      ~reader
      ~cx
      ~ac_loc
      ~file_sig
      ~ast
      ~typed_ast
      ~include_super:false
      ~include_this:false
      ~imports
      ~imports_ranked_usage
      ~tparams_rev
      ~edit_locs
      ~token
      ~type_
  in
  if should_autoimport_react ~options ~imports ~file_sig then
    let open ServerProt.Response.Completion in
    let import_edit =
      let src_dir = src_dir_of_loc (loc_of_aloc ~reader ac_loc) in
      let kind = Export_index.Namespace in
      let name = "React" in
      (* TODO: make this configurable between React and react *)
      let source = Export_index.Builtin "react" in
      Code_action_service.text_edits_of_import ~options ~reader ~src_dir ~ast kind name source
    in
    match import_edit with
    | None -> AcResult results
    | Some { Code_action_service.title = _; edits; from = _ } ->
      let edits = Base.List.map ~f:flow_text_edit_of_lsp_text_edit edits in
      let { items; _ } = result in
      let items =
        Base.List.map
          ~f:(fun item ->
            let { additional_text_edits; _ } = item in
            let additional_text_edits = additional_text_edits @ edits in
            { item with additional_text_edits })
          items
      in
      let result = { result with items } in
      AcResult { result; errors_to_log }
  else
    AcResult results

(* Similar to autocomplete_member, except that we're not directly given an
   object type whose members we want to enumerate: instead, we are given a
   component class and we want to enumerate the members of its declared props
   type, so we need to extract that and then route to autocomplete_member. *)
let autocomplete_jsx_attribute
    ~reader cx file_sig typed_ast cls attribute ~used_attr_names ~has_value ~tparams_rev ~edit_locs
    =
  let open Flow_js in
  let reason =
    let (aloc, name) = attribute in
    Reason.mk_reason (Reason.RCustom name) aloc
  in
  let props_object =
    Tvar.mk_where cx reason (fun tvar ->
        let use_op = Type.Op Type.UnknownUse in
        flow cx (cls, Type.ReactKitT (use_op, reason, Type.React.GetConfig tvar))
    )
  in
  let exact_by_default = Context.exact_by_default cx in
  (* The `children` prop (if it exists) is set with the contents between the opening and closing
   * elements, rather than through an explicit `children={...}` attribute, so we should exclude
   * it from the autocomplete results, along with already used attribute names. *)
  let exclude_keys = SSet.add "children" used_attr_names in
  (* Only include own properties, so we don't suggest things like `hasOwnProperty` as potential JSX properties *)
  let mems_result =
    members_of_type
      ~reader
      ~exclude_proto_members:true
      ~exclude_keys
      cx
      file_sig
      typed_ast
      props_object
      ~tparams_rev
  in
  match mems_result with
  | Error err -> AcFatalError err
  | Ok (mems, errors_to_log, _) ->
    let items =
      mems
      |> Base.List.map ~f:(fun (name, documentation, tags, Ty_members.{ ty; _ }) ->
             let insert_text =
               if has_value then
                 name
               else
                 name ^ "="
             in
             autocomplete_create_result
               ~insert_text
               ?documentation
               ?tags
               ~exact_by_default
               ~log_info:"jsx attribute"
               (name, edit_locs)
               ty
         )
    in
    let result = { ServerProt.Response.Completion.items; is_incomplete = false } in
    AcResult { result; errors_to_log }

let autocomplete_qualified_type ~reader ~cx ~file_sig ~typed_ast ~tparams_rev ~qtype ~edit_locs =
  let qtype_scheme = Type.TypeScheme.{ tparams_rev; type_ = qtype } in
  let exact_by_default = Context.exact_by_default cx in
  let module_ty_res =
    Ty_normalizer.from_scheme
      ~options:ty_normalizer_options
      ~genv:(Ty_normalizer_env.mk_genv ~full_cx:cx ~file:(Context.file cx) ~typed_ast ~file_sig)
      qtype_scheme
  in
  let documentation_and_tags_of_module_member =
    documentation_and_tags_of_def_loc ~reader ~typed_ast
  in
  let (items, errors_to_log) =
    match module_ty_res with
    | Error err -> ([], [Ty_normalizer.error_to_string err])
    | Ok module_ty ->
      ( type_exports_of_module_ty
          ~edit_locs
          ~exact_by_default
          ~documentation_and_tags_of_module_member
          module_ty,
        []
      )
  in
  AcResult
    { result = { ServerProt.Response.Completion.items; is_incomplete = false }; errors_to_log }

let autocomplete_object_key
    ~reader
    ~options
    ~cx
    ~file_sig
    ~typed_ast
    ~edit_locs
    ~token
    ~used_keys
    ~spreads
    obj_type
    ~tparams_rev =
  let edit_locs = fix_locs_of_string_token token edit_locs in
  let (insert_loc, _replace_loc) = edit_locs in
  let exact_by_default = Context.exact_by_default cx in
  let exclude_keys =
    Base.List.fold ~init:used_keys spreads ~f:(fun acc (spread_loc, spread_type) ->
        (* Only exclude the keys of spreads after our prop. If the spread is before our
           insertion we do not use it to exclude properties from our autcomplete
           suggestions. It is a common pattern to use a spread to set default values and
           then override some of those defaults. *)
        if Loc.compare spread_loc insert_loc < 0 then
          acc
        else
          let spread_keys =
            match
              members_of_type
                ~reader
                ~exclude_proto_members:true
                cx
                file_sig
                typed_ast
                spread_type
                ~tparams_rev
            with
            | Error _ -> SSet.empty
            | Ok (members, _, _) ->
              Base.List.map members ~f:(fun (name, _, _, _) -> name) |> SSet.of_list
          in
          SSet.union acc spread_keys
    )
  in
  let upper_bound = upper_bound_t_of_t ~cx obj_type in
  match
    members_of_type
      ~reader
      ~exclude_keys
      ~exclude_proto_members:true
      cx
      file_sig
      typed_ast
      upper_bound
      ~tparams_rev
  with
  | Error err -> AcFatalError err
  | Ok (mems, errors_to_log, _in_idx) ->
    let items =
      mems
      |> Base.List.map ~f:(fun (name, documentation, tags, Ty_members.{ ty; _ }) ->
             let rank = 0 in
             let name_is_valid_identifier = Parser_flow.string_is_valid_identifier_name name in
             if name_is_valid_identifier then
               autocomplete_create_result
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"object key"
                 (name, edit_locs)
                 ty
             else
               let insert_text =
                 let expression =
                   match Base.String.chop_prefix ~prefix:"@@" name with
                   | None -> Ast_builder.Expressions.literal (Ast_builder.Literals.string name)
                   | Some symbol ->
                     Ast_builder.Expressions.member_expression_ident_by_name
                       (Ast_builder.Expressions.identifier "Symbol")
                       symbol
                 in
                 expression
                 |> Js_layout_generator.expression ~opts:(Code_action_service.layout_options options)
                 |> Pretty_printer.print ~source_maps:None ~skip_endline:true
                 |> Source.contents
               in
               autocomplete_create_result
                 ~insert_text
                 ~rank
                 ?documentation
                 ?tags
                 ~exact_by_default
                 ~log_info:"bracket syntax object key"
                 (insert_text, edit_locs)
                 ty
         )
    in
    let result = { ServerProt.Response.Completion.items; is_incomplete = false } in
    AcResult { result; errors_to_log }

let autocomplete_get_results
    ~env
    ~options
    ~reader
    ~cx
    ~file_sig
    ~ast
    ~typed_ast
    ~imports
    ~imports_ranked_usage
    trigger_character
    cursor =
  let file_sig = File_sig.abstractify_locs file_sig in
  let open Autocomplete_js in
  match process_location ~trigger_character ~cursor ~typed_ast with
  | None ->
    let result = { ServerProt.Response.Completion.items = []; is_incomplete = false } in
    ( None,
      None,
      ("None", AcResult { result; errors_to_log = ["Autocomplete token not found in AST"] })
    )
  | Some { tparams_rev; ac_loc; token; autocomplete_type } ->
    (* say you're completing `foo|Baz`. the token is "fooBaz" and ac_loc points at
       "fooAUTO332Baz". if the suggestion is "fooBar", the user can choose to insert
       into the token, yielding "fooBarBaz", or they can choose to replace the token,
       yielding "fooBar". *)
    let edit_locs =
      let replace_loc = loc_of_aloc ~reader ac_loc |> Autocomplete_sigil.remove_from_loc in
      (* invariant: the cursor must be inside ac_loc *)
      let insert_loc = Loc.btwn replace_loc cursor in
      (insert_loc, replace_loc)
    in
    ( Some token,
      Some ac_loc,
      (match autocomplete_type with
      | Ac_binding -> ("Empty", AcEmpty "Binding")
      | Ac_ignored -> ("Empty", AcEmpty "Ignored")
      | Ac_comment -> ("Empty", AcEmpty "Comment")
      | Ac_jsx_text -> ("Empty", AcEmpty "JSXText")
      | Ac_class_key ->
        (* TODO: include superclass keys *)
        ("Ac_class_key", AcEmpty "ClassKey")
      | Ac_module ->
        (* TODO: complete module names *)
        ("Acmodule", AcEmpty "Module")
      | Ac_enum -> ("Acenum", AcEmpty "Enum")
      | Ac_key { obj_type; used_keys; spreads } ->
        ( "Ackey",
          autocomplete_object_key
            ~reader
            ~options
            ~cx
            ~file_sig
            ~typed_ast
            ~edit_locs
            ~token
            ~used_keys
            ~spreads
            obj_type
            ~tparams_rev
        )
      | Ac_literal { lit_type } ->
        let genv =
          Ty_normalizer_env.mk_genv ~full_cx:cx ~file:(Context.file cx) ~typed_ast ~file_sig
        in
        let upper_bound = upper_bound_t_of_t ~cx lit_type in
        let prefer_single_quotes = Options.format_single_quotes options in
        let items =
          autocomplete_literals ~prefer_single_quotes ~cx ~genv ~tparams_rev ~edit_locs ~upper_bound
        in
        let result = ServerProt.Response.Completion.{ items; is_incomplete = false } in
        ("Acliteral", AcResult { result; errors_to_log = [] })
      | Ac_id { include_super; include_this; type_; enclosing_class_t } ->
        ( "Acid",
          let result_id =
            autocomplete_id
              ~env
              ~options
              ~reader
              ~cx
              ~ac_loc
              ~file_sig
              ~ast
              ~typed_ast
              ~include_super
              ~include_this
              ~imports
              ~imports_ranked_usage
              ~tparams_rev
              ~edit_locs
              ~token
              ~type_
          in
          (match enclosing_class_t with
          | Some t ->
            let result_member =
              autocomplete_member
                ~env
                ~reader
                ~options
                ~cx
                ~file_sig
                ~ast
                ~typed_ast
                ~imports
                ~imports_ranked_usage
                ~edit_locs
                ~token
                t
                false
                ac_loc
                ~tparams_rev
                ~bracket_syntax:None
                ~member_loc:None
                ~is_type_annotation:false
                ~force_instance:true
            in
            (match result_member with
            | AcFatalError _ as err -> err
            | AcEmpty _ -> AcResult result_id
            | AcResult result_member ->
              let open ServerProt.Response.Completion in
              let items =
                result_id.result.items
                @ Base.List.map
                    ~f:(fun item ->
                      let name = "this." ^ item.name in
                      {
                        item with
                        name;
                        text_edit = Some (text_edit ?insert_text:(Some name) name edit_locs);
                      })
                    result_member.result.items
                |> fun l -> filter_by_token l token
              in
              AcResult
                {
                  result =
                    {
                      ServerProt.Response.Completion.items;
                      is_incomplete =
                        result_id.result.is_incomplete || result_member.result.is_incomplete;
                    };
                  errors_to_log = result_id.errors_to_log @ result_member.errors_to_log;
                })
          | _ -> AcResult result_id)
        )
      | Ac_member { obj_type; in_optional_chain; bracket_syntax; member_loc; is_type_annotation } ->
        ( "Acmem",
          autocomplete_member
            ~env
            ~reader
            ~options
            ~cx
            ~file_sig
            ~ast
            ~typed_ast
            ~imports
            ~imports_ranked_usage
            ~edit_locs
            ~token
            obj_type
            in_optional_chain
            ac_loc
            ~tparams_rev
            ~bracket_syntax
            ~member_loc
            ~is_type_annotation
            ~force_instance:false
        )
      | Ac_jsx_element { type_ } ->
        ( "Ac_jsx_element",
          autocomplete_jsx_element
            ~env
            ~options
            ~reader
            ~cx
            ~ac_loc
            ~file_sig
            ~ast
            ~typed_ast
            ~imports
            ~imports_ranked_usage
            ~tparams_rev
            ~edit_locs
            ~token
            ~type_
        )
      | Ac_jsx_attribute { attribute_name; used_attr_names; component_t; has_value } ->
        ( "Acjsx",
          autocomplete_jsx_attribute
            ~reader
            cx
            file_sig
            typed_ast
            component_t
            (ac_loc, attribute_name)
            ~used_attr_names
            ~has_value
            ~tparams_rev
            ~edit_locs
        )
      | Ac_type ->
        ( "Actype",
          AcResult
            (autocomplete_unqualified_type
               ~env
               ~options
               ~reader
               ~cx
               ~imports
               ~imports_ranked_usage
               ~tparams_rev
               ~ac_loc
               ~ast
               ~typed_ast
               ~file_sig
               ~edit_locs
               ~token
            )
        )
      | Ac_qualified_type qtype ->
        ( "Acqualifiedtype",
          autocomplete_qualified_type
            ~reader
            ~cx
            ~file_sig
            ~typed_ast
            ~tparams_rev
            ~qtype
            ~edit_locs
        ))
    )
