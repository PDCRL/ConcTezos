(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

open Protocol
open Alpha_context

let originated_rollup op =
  let nonce =
    Origination_nonce.Internal_for_tests.initial (Operation.hash_packed op)
  in
  Contract.Internal_for_tests.originated_contract nonce

module In_memory_context = struct
  open Tezos_context_memory

  module Tree = struct
    include Context.Tree

    type tree = Context.tree

    type t = Context.t

    type key = string list

    type value = bytes
  end

  type tree = Tree.tree

  type proof = Context.Proof.tree Context.Proof.t

  let hash_tree _ = assert false

  let verify_proof p f =
    Lwt.map Result.to_option (Context.verify_tree_proof p f)

  let produce_proof context state step =
    let open Lwt_syntax in
    let* context = Context.add_tree context [] state in
    let* h = Context.commit ~time:Time.Protocol.epoch context in
    let index = Context.index context in
    let* context = Context.checkout_exn index h in
    match Tree.kinded_key state with
    | Some k ->
        let index = Context.index context in
        let* p = Context.produce_tree_proof index k step in
        return (Some p)
    | None -> return None

  let kinded_hash_to_state_hash = function
    | `Value hash | `Node hash ->
        Sc_rollup.State_hash.context_hash_to_state_hash hash

  let proof_before proof = kinded_hash_to_state_hash proof.Context.Proof.before

  let proof_after proof = kinded_hash_to_state_hash proof.Context.Proof.after

  let proof_encoding =
    Tezos_context_helpers.Merkle_proof_encoding.V1.Tree32.tree_proof_encoding
end

module Arith_pvm :
  Sc_rollup.PVM.S
    with type context = In_memory_context.Tree.t
     and type state = In_memory_context.tree
     and type proof =
      Tezos_context_memory.Context.Proof.tree
      Tezos_context_memory.Context.Proof.t
      Sc_rollup.ArithPVM.proof =
  Sc_rollup.ArithPVM.Make (In_memory_context)

module Wasm_pvm :
  Sc_rollup.PVM.S
    with type context = In_memory_context.Tree.t
     and type state = In_memory_context.tree
     and type proof =
      Tezos_context_memory.Context.Proof.tree
      Tezos_context_memory.Context.Proof.t
      Sc_rollup.Wasm_2_0_0PVM.proof =
  Sc_rollup.Wasm_2_0_0PVM.Make (In_memory_context)

let origination_proof ~boot_sector = function
  | Sc_rollup.Kind.Example_arith ->
      let open Lwt_syntax in
      let context = Tezos_context_memory.make_empty_context () in
      let* proof = Arith_pvm.produce_origination_proof context boot_sector in
      let proof = WithExceptions.Result.get_ok ~loc:__LOC__ proof in
      return
        (Sc_rollup.Arith_pvm_with_proof
           (module struct
             include Arith_pvm

             let proof = proof
           end))
  | Sc_rollup.Kind.Wasm_2_0_0 ->
      let open Lwt_syntax in
      let context = Tezos_context_memory.make_empty_context () in
      let* proof = Wasm_pvm.produce_origination_proof context boot_sector in
      let proof = WithExceptions.Result.get_ok ~loc:__LOC__ proof in
      return
        (Sc_rollup.Wasm_2_0_0_pvm_with_proof
           (module struct
             include Wasm_pvm

             let proof = proof
           end))
