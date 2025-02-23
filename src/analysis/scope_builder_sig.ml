(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module type S = sig
  module L : Loc_sig.S

  module Api : Scope_api_sig.S with module L = L

  module Acc : sig
    type t = Api.info

    val init : t
  end

  val program :
    ?flowmin_compatibility:bool ->
    enable_enums:bool ->
    with_types:bool ->
    (L.t, L.t) Flow_ast.Program.t ->
    Acc.t

  class scope_builder :
    flowmin_compatibility:bool
    -> enable_enums:bool
    -> with_types:bool
    -> object
         inherit [Acc.t, L.t] Flow_ast_visitor.visitor

         method with_bindings : 'a. ?lexical:bool -> L.t -> L.t Bindings.t -> ('a -> 'a) -> 'a -> 'a

         method private scoped_for_statement :
           L.t -> (L.t, L.t) Flow_ast.Statement.For.t -> (L.t, L.t) Flow_ast.Statement.For.t

         method private scoped_for_in_statement :
           L.t -> (L.t, L.t) Flow_ast.Statement.ForIn.t -> (L.t, L.t) Flow_ast.Statement.ForIn.t

         method private scoped_for_of_statement :
           L.t -> (L.t, L.t) Flow_ast.Statement.ForOf.t -> (L.t, L.t) Flow_ast.Statement.ForOf.t

         method private switch_cases :
           L.t ->
           (L.t, L.t) Flow_ast.Expression.t ->
           (L.t, L.t) Flow_ast.Statement.Switch.Case.t list ->
           (L.t, L.t) Flow_ast.Statement.Switch.Case.t list

         method private class_identifier_opt :
           class_loc:L.t -> (L.t, L.t) Flow_ast.Identifier.t option -> unit

         method private this_binding_function_id_opt :
           fun_loc:L.t -> (L.t, L.t) Flow_ast.Identifier.t option -> unit

         method private lambda :
           is_arrow:bool ->
           fun_loc:L.t ->
           generator_return_loc:L.t option ->
           (L.t, L.t) Flow_ast.Function.Params.t ->
           (L.t, L.t) Flow_ast.Type.Predicate.t option ->
           (L.t, L.t) Flow_ast.Function.body ->
           unit

         method private hoist_annotations : (unit -> unit) -> unit
       end
end
