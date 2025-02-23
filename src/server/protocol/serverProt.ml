(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Request = struct
  type command =
    | AUTOCOMPLETE of {
        input: File_input.t;
        cursor: int * int;
        trigger_character: string option;
        wait_for_recheck: bool option;
        imports: bool;  (** include auto-import suggestions *)
        imports_ranked_usage: bool;
      }
    | AUTOFIX_EXPORTS of {
        input: File_input.t;
        verbose: Verbose.t option;
        wait_for_recheck: bool option;
      }
    | CHECK_FILE of {
        input: File_input.t;
        verbose: Verbose.t option;
        force: bool;
        include_warnings: bool;
        wait_for_recheck: bool option;
      }
    | COVERAGE of {
        input: File_input.t;
        force: bool;
        wait_for_recheck: bool option;
        trust: bool;
      }
    | BATCH_COVERAGE of {
        batch: string list;
        wait_for_recheck: bool option;
        trust: bool;
      }
    | CYCLE of {
        filename: string;
        types_only: bool;
      }
    | DUMP_TYPES of {
        input: File_input.t;
        evaluate_type_destructors: bool;
        wait_for_recheck: bool option;
      }
    | FIND_MODULE of {
        moduleref: string;
        filename: string;
        wait_for_recheck: bool option;
      }
    | FORCE_RECHECK of {
        files: string list;
        focus: bool;
      }
    | GET_DEF of {
        filename: File_input.t;
        line: int;
        char: int;
        wait_for_recheck: bool option;
      }
    | GET_IMPORTS of {
        module_names: string list;
        wait_for_recheck: bool option;
      }
    | GRAPH_DEP_GRAPH of {
        root: string;
        strip_root: bool;
        outfile: string;
        types_only: bool;
      }
    | INFER_TYPE of {
        input: File_input.t;
        line: int;
        char: int;
        verbose: Verbose.t option;
        omit_targ_defaults: bool;
        evaluate_type_destructors: bool;
        wait_for_recheck: bool option;
        verbose_normalizer: bool;
        max_depth: int;
      }
    | INSERT_TYPE of {
        input: File_input.t;
        target: Loc.t;
        verbose: Verbose.t option;
        location_is_strict: bool;
        ambiguity_strategy: Autofix_options.ambiguity_strategy;
        wait_for_recheck: bool option;
        omit_targ_defaults: bool;
      }
    | RAGE of { files: string list }
    | SAVE_STATE of { outfile: Path.t }
    | STATUS of { include_warnings: bool }

  let to_string = function
    | AUTOCOMPLETE
        {
          input;
          cursor = _;
          wait_for_recheck = _;
          trigger_character = _;
          imports = _;
          imports_ranked_usage = _;
        } ->
      Printf.sprintf "autocomplete %s" (File_input.filename_of_file_input input)
    | AUTOFIX_EXPORTS { input; _ } ->
      Printf.sprintf "autofix exports %s" (File_input.filename_of_file_input input)
    | CHECK_FILE { input; verbose = _; force = _; include_warnings = _; wait_for_recheck = _ } ->
      Printf.sprintf "check %s" (File_input.filename_of_file_input input)
    | BATCH_COVERAGE { batch = _; wait_for_recheck = _; trust = _ } ->
      Printf.sprintf "%s" "batch-coverage"
    | COVERAGE { input; force = _; wait_for_recheck = _; trust = _ } ->
      Printf.sprintf "coverage %s" (File_input.filename_of_file_input input)
    | CYCLE { filename; types_only } ->
      Printf.sprintf "cycle (types_only: %b) %s" types_only filename
    | GRAPH_DEP_GRAPH _ -> Printf.sprintf "dep-graph"
    | DUMP_TYPES { input; evaluate_type_destructors = _; wait_for_recheck = _ } ->
      Printf.sprintf "dump-types %s" (File_input.filename_of_file_input input)
    | FIND_MODULE { moduleref; filename; wait_for_recheck = _ } ->
      Printf.sprintf "find-module %s %s" moduleref filename
    | FORCE_RECHECK { files; focus } ->
      Printf.sprintf "force-recheck %s (focus = %b)" (String.concat " " files) focus
    | GET_DEF { filename; line; char; wait_for_recheck = _ } ->
      Printf.sprintf "get-def %s:%d:%d" (File_input.filename_of_file_input filename) line char
    | GET_IMPORTS { module_names; wait_for_recheck = _ } ->
      Printf.sprintf "get-imports %s" (String.concat " " module_names)
    | INFER_TYPE
        {
          input;
          line;
          char;
          verbose = _;
          omit_targ_defaults = _;
          evaluate_type_destructors = _;
          wait_for_recheck = _;
          verbose_normalizer = _;
          max_depth = _;
        } ->
      Printf.sprintf "type-at-pos %s:%d:%d" (File_input.filename_of_file_input input) line char
    | INSERT_TYPE { input; target; _ } ->
      Loc.(
        Printf.sprintf
          "autofix insert-type %s:%d:%d-%d:%d"
          (File_input.filename_of_file_input input)
          target.start.line
          target.start.column
          target._end.line
          target._end.column
      )
    | RAGE { files } -> Printf.sprintf "rage %s" (String.concat " " files)
    | STATUS { include_warnings = _ } -> "status"
    | SAVE_STATE { outfile } -> Printf.sprintf "save-state %s" (Path.to_string outfile)

  type command_with_context = {
    client_logging_context: FlowEventLogger.logging_context;
    command: command;
  }
end

module Response = struct
  type lazy_stats = {
    lazy_mode: bool;
    checked_files: int;
    total_files: int;
  }

  (* Details about functions to be added in json output *)
  type func_param_result = {
    param_documentation: string option;
    param_name: string;
    param_ty: string;
  }

  type func_details_result = {
    func_documentation: string option;
    param_tys: func_param_result list;
    return_ty: string;
  }

  type textedit = Loc.t * string

  type insert_replace_edit = {
    newText: string;
    insert: Loc.t;
    replace: Loc.t;
  }

  module Completion = struct
    type completion_item = {
      detail: string;
      kind: Lsp.Completion.completionItemKind option;
      name: string;
      text_edit: insert_replace_edit option;
      additional_text_edits: textedit list;
      sort_text: string option;
      preselect: bool;
      documentation: string option;
      tags: Lsp.CompletionItemTag.t list option;
      log_info: string;
      source: string option;  (** autoimport source *)
      type_: string option;
    }

    type t = {
      items: completion_item list;
      is_incomplete: bool;
    }
  end

  type autocomplete_response = (Completion.t, string) result

  type autofix_exports_response = (Replacement_printer.patch * string list, string) result

  type coverage_response = ((Loc.t * Coverage_response.expression_coverage) list, string) result

  type batch_coverage_response =
    ((File_key.t * Coverage_response.file_coverage) list, string) result

  type dump_types_response = ((Loc.t * string) list, string) result

  type get_def_response = (Loc.t, string) result

  type get_imports_response = Loc.t Nel.t Modulename.Map.t SMap.t * SSet.t

  type infer_type_response_ok =
    | Infer_type_response of {
        loc: Loc.t;
        ty: Ty.elt option;
        exact_by_default: bool;
        documentation: string option;
      }

  type infer_type_response = (infer_type_response_ok, string) result

  type insert_type_response = (Replacement_printer.patch, string) result

  type rage_response = (string * string) list

  type graph_response = (graph_response_subgraph, string) result

  and graph_response_subgraph = (string * string list) list

  type status_response =
    | ERRORS of {
        errors: Errors.ConcreteLocPrintableErrorSet.t;
        warnings: Errors.ConcreteLocPrintableErrorSet.t;
        suppressed_errors: (Loc.t Errors.printable_error * Loc_collections.LocSet.t) list;
      }
    | NO_ERRORS
    | NOT_COVERED

  type check_file_response = status_response

  type find_module_response = File_key.t option

  type response =
    | AUTOCOMPLETE of autocomplete_response
    | AUTOFIX_EXPORTS of autofix_exports_response
    | CHECK_FILE of check_file_response
    | COVERAGE of coverage_response
    | BATCH_COVERAGE of batch_coverage_response
    | CYCLE of graph_response
    | GRAPH_DEP_GRAPH of (unit, string) result
    | DUMP_TYPES of dump_types_response
    | FIND_MODULE of find_module_response
    | FORCE_RECHECK
    | GET_DEF of get_def_response
    | GET_IMPORTS of get_imports_response
    | INFER_TYPE of infer_type_response
    | INSERT_TYPE of insert_type_response
    | RAGE of rage_response
    | STATUS of {
        status_response: status_response;
        lazy_stats: lazy_stats;
      }
    | SAVE_STATE of (unit, string) result

  let to_string = function
    | AUTOCOMPLETE _ -> "autocomplete response"
    | AUTOFIX_EXPORTS _ -> "autofix exports response"
    | CHECK_FILE _ -> "check_file response"
    | COVERAGE _ -> "coverage response"
    | BATCH_COVERAGE _ -> "batch-coverage response"
    | CYCLE _ -> "cycle response"
    | GRAPH_DEP_GRAPH _ -> "dep-graph response"
    | DUMP_TYPES _ -> "dump_types response"
    | FIND_MODULE _ -> "find_module response"
    | FORCE_RECHECK -> "force_recheck response"
    | GET_DEF _ -> "get_def response"
    | GET_IMPORTS _ -> "get_imports response"
    | INFER_TYPE _ -> "infer_type response"
    | INSERT_TYPE _ -> "insert_type response"
    | RAGE _ -> "rage response"
    | STATUS _ -> "status response"
    | SAVE_STATE _ -> "save_state response"
end
