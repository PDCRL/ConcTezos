(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

(** [originate context ~kind ~boot_sector] produces an address [a] for
   a smart contract rollup using the origination nonce found in
   [context]. This function also initializes the storage with a new
   entry indexed by [a] to remember the [kind] of the rollup at
   address [a] and also to remember its [boot_sector].

   Also returns the number of allocated bytes.  *)
val originate :
  Raw_context.t ->
  kind:Sc_rollups.Kind.t ->
  boot_sector:string ->
  parameters_ty:Script_repr.lazy_expr ->
  genesis_commitment:Sc_rollup_commitment_repr.t ->
  (Sc_rollup_repr.Address.t
  * Z.t
  * Sc_rollup_commitment_repr.Hash.t
  * Raw_context.t)
  tzresult
  Lwt.t

(** [kind context address] returns the kind of the given rollup [address] iff
    [address] is an existing rollup. Fails with an [Sc_rollup_does_not_exist]
    error in case the rollup does not exist. *)
val kind :
  Raw_context.t ->
  Sc_rollup_repr.t ->
  (Raw_context.t * Sc_rollups.Kind.t) tzresult Lwt.t

val list_unaccounted : Raw_context.t -> Sc_rollup_repr.t list tzresult Lwt.t

(** [genesis_info ctxt sc_rollup] returns the level at which a [sc_rollup] was
   originated, and its genesis commitment hash. *)
val genesis_info :
  Raw_context.t ->
  Sc_rollup_repr.t ->
  (Raw_context.t * Sc_rollup_commitment_repr.genesis_info) tzresult Lwt.t

(** [get_metadata ctxt rollup] retrieves the origination level of the [rollup]
    using {!Sc_rollup_commitment_repr.genesis_info} and creates a
    {!Sc_rollup_metadata_repr.t}.
    Fails with [Sc_rollup_does_not_exist {rollup}] if the genesis info is
    missing. *)
val get_metadata :
  Raw_context.t ->
  Sc_rollup_repr.t ->
  (Raw_context.t * Sc_rollup_metadata_repr.t) tzresult Lwt.t

(** [get_boot_sector ctxt sc_rollup] retrieves the boot sector for [sc_rollup]. *)
val get_boot_sector :
  Raw_context.t -> Sc_rollup_repr.t -> (Raw_context.t * string) tzresult Lwt.t

(** [parameters_type ctxt rollup] returns the registered type of a rollup.
    Returns [None] in case there is no registered type for the rollup. *)
val parameters_type :
  Raw_context.t ->
  Sc_rollup_repr.t ->
  (Script_repr.lazy_expr option * Raw_context.t) tzresult Lwt.t

module Dal_slot : sig
  (** [subscribe ctxt rollup slot_index] marks the [rollup] as subscribed to
      [slot_index] at the level indicated by [Raw_context.current_level ctxt].

      May fail with:
     {ul
       {li [Sc_rollup_does_not_exist] if [rollup] does not exist}
       {li [Dal_subscribe_rollup_invalid_slot_index of {given=slot_index; maximum}] if
         the slot_index is either negative or above [maximum], which is the maximum
       slot index (inclusive) allowed}
       {li [Dal_errors_repr.Dal_rollup_already_registered_to_slot (rollup, slot_index)]
         if [rollup] is already subscribed to [slot_index]}
     }
  *)
  val subscribe :
    Raw_context.t ->
    Sc_rollup_repr.t ->
    slot_index:Dal_slot_repr.Index.t ->
    (Dal_slot_repr.Index.t * Raw_level_repr.t * Raw_context.t) tzresult Lwt.t

  (** [subscribed_slot_indices ctxt rollup level] returns the slots to
      which [rollup] was subscribed at level [level].

      May fail with:
     {ul
       {li [Sc_rollup_does_not_exist] if [rollup] does not exist}
       {li [Dal_errors_repr.Dal_requested_subscriptions_at_future_level (current_level, level)]
       if [level] is above the current elvel, i.e.
       [current] = [Raw_context.current_level ctxt] and [level] > [current]}
     }
  *)
  val subscribed_slot_indices :
    Raw_context.t ->
    Sc_rollup_repr.t ->
    Raw_level_repr.t ->
    Dal_slot_repr.Index.t list tzresult Lwt.t
end
