(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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
    Invocation:   dune build @src/proto_alpha/lib_protocol/runtest
    Subject:      Entrypoint
*)

let () =
  Alcotest_lwt.run
    "protocol_012_Psithaca"
    [
      ("endorsement", Test_endorsement.tests);
      ("preendorsement", Test_preendorsement.tests);
      ("double endorsement", Test_double_endorsement.tests);
      ("double preendorsement", Test_double_preendorsement.tests);
      ("double baking", Test_double_baking.tests);
      ("seed", Test_seed.tests);
      ("baking", Test_baking.tests);
      ("delegation", Test_delegation.tests);
      ("deactivation", Test_deactivation.tests);
      ("interpretation", Test_interpretation.tests);
      ("typechecking", Test_typechecking.tests);
      ("gas levels", Test_gas_levels.tests);
      ("gas cost functions", Test_gas_costs.tests);
      ("lazy storage diff", Test_lazy_storage_diff.tests);
      ("global table of constants", Test_global_constants_storage.tests);
      ("sapling", Test_sapling.tests);
      ("helpers rpcs", Test_helpers_rpcs.tests);
      ("storage description", Test_storage.tests);
      ("constants", Test_constants.tests);
      ("liquidity baking", Test_liquidity_baking.tests);
      ("temp big maps", Test_temp_big_maps.tests);
      ("timelock", Test_timelock.tests);
      ("script typed ir size", Test_script_typed_ir_size.tests);
      ("ticket storage", Test_ticket_storage.tests);
      ("ticket scanner", Test_ticket_scanner.tests);
      ("ticket balance key", Test_ticket_balance_key.tests);
      ("participation monitoring", Test_participation.tests);
      ("frozen deposits", Test_frozen_deposits.tests);
      ("token movements", Test_token.tests);
    ]
  |> Lwt_main.run
