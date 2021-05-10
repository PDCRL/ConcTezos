(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

(** Testing
    -------
    Component:    Protocol Environment
    Invocation:   dune build @src/lib_protocol_environment/runtest_mem_context_array_theory
    Dependencies: src/lib_protocol_environment/test/test_mem_context.ml
    Subject:      get/set operations on memory contexts.
*)

(**
    Tests [Memory_context] by making sure it's an instance of array theory.
    Being an array theory means honoring the following axioms (see the
    literature on the corresponding decision procedure):

    * get (set m k v) v = v
    * forall k1 <> k2, get (set m k1 v) k2 = get m k2

    The first axiom is tested in [test_get_set] while the second axiom
    is tested in [test_get_set_other].

    These tests complement [Test_mem_context]: while [Test_mem_context]
    creates values of Context.t manually, this file
    use automatically generated values; thanks to [QCheck].
*)

open Lib_test.Qcheck_helpers

type key = Context.key

let equal_key : key -> key -> bool =
 fun (a : string list) (b : string list) -> Stdlib.( = ) a b

type value = Context.value

(** Using [QCheck.small_list] for performance reasons: using [QCheck.list] here
    makes the file 40 times slower, which is not acceptable. *)
let key_arb = QCheck.small_list QCheck.string

(* As bytes are mutable this is fine because the test doesn't do any
   mutation. Otherwise [rev] could be called on a value different than
   the value passed to the test. *)
let value_arb = QCheck.map ~rev:Bytes.to_string Bytes.of_string QCheck.string

let key_value_arb = QCheck.pair key_arb value_arb

(* We generate contexts by starting from a fresh one and
   doing a sequence of calls to [Context.add].  *)
let context_arb : Context.t QCheck.arbitrary =
  let set_all key_value_list =
    Lwt_main.run
    @@ Lwt_list.fold_left_s
         (fun ctxt (k, v) -> Context.add ctxt k v)
         Memory_context.empty
         key_value_list
  in
  let rev ctxt =
    let keys = Lwt_main.run @@ Test_mem_context.domain ctxt in
    List.map
      (fun key ->
        ( key,
          Lwt_main.run @@ Context.find ctxt key
          |> WithExceptions.Option.get ~loc:__LOC__ ))
      keys
  in
  QCheck.map ~rev set_all @@ QCheck.small_list key_value_arb

(** Some printers for passing to [check_eq*] functions *)

let pp_print_value fmt v = Format.fprintf fmt "%s" (Bytes.to_string v)

(* We're done with generators. *)

(* Test that [Test_mem_context.domain] is correct. Important because
   this function is used in the test of the second axiom of array theory:
   [test_get_set_other]. Also this serves as a specification of
   [Test_mem_context.domain]. *)
let test_domain_spec (ctxt, k) =
  if k = [] then
    (* This is a bit puzzling, but the empty key is special; because
       of the implementation of memory_context.ml's [Context.mem] method which
       returns true on the empty key. This means the empty key
       is considered to exist in an empty context, on which,
       [Test_mem_contex.domain] appropriately returns an empty list. One
       could complexify this test to support this case, but I didn't want
       to spend too much time on this; we're testing a test after all here. *)
    QCheck.assume_fail ()
  else
    let domain = Lwt_main.run @@ Test_mem_context.domain ctxt in
    qcheck_eq
      ~pp:Format.pp_print_bool
      (Lwt_main.run @@ Context.mem ctxt k)
      (List.mem ~equal:equal_key k domain)

(* Tests that (get (set m k v) k) equals v.
   This is the first axiom of array theory *)
let test_get_set (ctxt, (k, v)) =
  let ctxt' = Lwt_main.run @@ Context.add ctxt k v in
  let at_k = Lwt_main.run @@ Context.find ctxt' k in
  qcheck_eq'
    ~pp:(Format.pp_print_option pp_print_value)
    ~expected:(Some v)
    ~actual:at_k
    ()

(* Tests that: forall k2 <> k1, (get (set m k1 v) k2) equals get m k2;
 * i.e. setting a key doesn't affect other keys.
 * This is the second axiom of array theory *)
let test_get_set_other (ctxt, (k1, v)) =
  let ctxt' = Lwt_main.run @@ Context.add ctxt k1 v in
  let keys = Lwt_main.run @@ Test_mem_context.domain ctxt' in
  let check_key k2 =
    if k1 = k2 then true
    else
      let v_before = Lwt_main.run @@ Context.find ctxt k2 in
      let v_after = Lwt_main.run @@ Context.find ctxt' k2 in
      qcheck_eq'
        ~pp:(Format.pp_print_option pp_print_value)
        ~expected:v_before
        ~actual:v_after
        ()
  in
  List.for_all check_key keys

let test_set_domain (ctxt, (k, v)) =
  let domain = Lwt_main.run @@ Test_mem_context.domain ctxt in
  let ctxt' = Lwt_main.run @@ Context.add ctxt k v in
  let domain' = Lwt_main.run @@ Test_mem_context.domain ctxt' in
  List.for_all
    (fun in_domain' ->
      equal_key in_domain' k || List.mem ~equal:equal_key in_domain' domain)
    domain'

let () =
  let test_domain =
    QCheck.Test.make
      ~name:"Test_mem_context.domain's specification "
      (QCheck.pair context_arb key_arb)
      test_domain_spec
  in
  let test_set =
    QCheck.Test.make
      ~name:"get (set m k v) k = v "
      (QCheck.pair context_arb key_value_arb)
      test_get_set
  in
  let test_get_set_other =
    QCheck.Test.make
      ~name:"forall k1 <> k2, get (set m k1 v) k2 = get m k2 "
      (QCheck.pair context_arb key_value_arb)
      test_get_set_other
  in
  let test_get_set =
    QCheck.Test.make
      ~name:"forall k2 in domain (set m k1 v), k2 in domain m || k1 = k2 "
      (QCheck.pair context_arb key_value_arb)
      test_set_domain
  in
  Alcotest.run
    "Memory context array theory"
    [ ("domain", qcheck_wrap [test_domain]);
      ("set", qcheck_wrap [test_set]);
      ("get_set", qcheck_wrap [test_get_set_other; test_get_set]) ]
