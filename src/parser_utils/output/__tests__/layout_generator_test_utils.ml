(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Ast_builder

let space_regex = Str.regexp_string " "

let newline_regex = Str.regexp_string "\n"

let opts = Js_layout_generator.default_opts

let preserve_formatting_opts = Js_layout_generator.{ default_opts with preserve_formatting = true }

let no_bracket_spacing opts = Js_layout_generator.{ opts with bracket_spacing = false }

let assert_output ~ctxt ?msg ?(pretty = false) expected_str layout =
  let print =
    if pretty then
      Pretty_printer.print ~source_maps:None ~skip_endline:false
    else
      Compact_printer.print ~source_maps:None
  in
  let out = print layout |> Source.contents in
  let out =
    (* remove trailing \n *)
    String.sub out 0 (String.length out - 1)
  in
  let open_box = "\xE2\x90\xA3" in
  let not_sign = "\xC2\xAC\n" in
  let printer x =
    x |> Str.global_replace space_regex open_box |> Str.global_replace newline_regex not_sign
  in
  assert_equal ~ctxt ?msg ~printer expected_str out

let assert_expression
    ~ctxt
    ?msg
    ?pretty
    ?(expr_ctxt = Js_layout_generator.normal_context)
    ?(opts = Js_layout_generator.default_opts)
    expected_str
    ast =
  let layout = Js_layout_generator.expression ~ctxt:expr_ctxt ~opts ast in
  assert_output ~ctxt ?msg ?pretty expected_str layout

let assert_expression_string
    ~ctxt ?msg ?pretty ?expr_ctxt ?(opts = Js_layout_generator.default_opts) str =
  let ast = expression_of_string str in
  assert_expression ~ctxt ~opts ?msg ?pretty ?expr_ctxt str ast

let assert_statement ~ctxt ?msg ?pretty ?(opts = Js_layout_generator.default_opts) expected_str ast
    =
  let layout = Js_layout_generator.statement ~opts ast in
  assert_output ~ctxt ?msg ?pretty expected_str layout

let assert_statement_string ~ctxt ?msg ?pretty ?(opts = Js_layout_generator.default_opts) str =
  let ast = statement_of_string str in
  let layout = Js_layout_generator.statement ~opts ast in
  assert_output ~ctxt ?msg ?pretty str layout

let assert_program_string ~ctxt ?msg ?pretty str =
  let ast = program_of_string str in
  let layout = Js_layout_generator.program_simple ast in
  assert_output ~ctxt ?msg ?pretty str layout
