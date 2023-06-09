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

(** Testing
    -------
    Component:    Protocol
    Invocation:   dune runtest src/proto_alpha/lib_protocol/test/integration/validate
    Subject:      Integration > Validate
*)

let () =
  Alcotest_lwt.run
    "protocol > integration > validate"
    [
      ("sanity checks", Test_manager_operation_validation.sanity_tests);
      ("Single: gas checks", Test_manager_operation_validation.gas_tests);
      ("Single: storage checks", Test_manager_operation_validation.storage_tests);
      ("Single: fees checks", Test_manager_operation_validation.fee_tests);
      ( "Single: contract checks",
        Test_manager_operation_validation.contract_tests );
      ( "Batched: contract checks",
        Test_batched_manager_operation_validation.contract_tests );
      ( "Batched: gas checks",
        Test_batched_manager_operation_validation.gas_tests );
      ( "Batched: fees checks",
        Test_batched_manager_operation_validation.fee_tests );
      ( "Flags: feature flag checks",
        Test_manager_operation_validation.flags_tests );
      ("Mempool", Test_mempool.tests);
    ]
  |> Lwt_main.run
