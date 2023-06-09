(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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
module Smart_contracts = Client_proto_stresstest_contracts

type transfer_strategy =
  | Fixed_amount of {mutez : Tez.t}  (** Amount to transfer *)
  | Evaporation of {fraction : float}
      (** Maximum fraction of current wealth to transfer.
          Minimum amount is 1 mutez regardless of total wealth. *)

type limit =
  | Abs of int  (** Absolute level at which we should stop  *)
  | Rel of int  (** Relative number of levels before stopping *)

type parameters = {
  seed : int;
  fresh_probability : float;
      (** Per-transfer probability that the destination will be fresh *)
  tps : float;  (** Transaction per seconds target *)
  strategy : transfer_strategy;
  regular_transfer_fee : Tez.t;
      (** fees for each transfer (except for transfers to smart contracts), in mutez *)
  regular_transfer_gas_limit : Gas.Arith.integral;
      (** gas limit per operation (except for transfers to smart contracts) *)
  storage_limit : Z.t;  (** storage limit per operation *)
  account_creation_storage : Z.t;
      (** upper bound on bytes consumed when creating a tz1 account *)
  total_transfers : int option;
      (** total number of transfers to perform; unbounded if None *)
  single_op_per_pkh_per_block : bool;
      (** if true, a single operation will be injected by pkh by block to
          improve the chance for the injected operations to be included in the
          next block *)
  level_limit : limit option;
      (** total number of levels during which the stresstest is run; unbounded if None *)
  smart_contracts : Smart_contracts.t;
      (** An opaque type that stores all the information that is necessary for
    efficient sampling of smart contract calls. *)
}

type origin = Explicit | Wallet_pkh | Wallet_alias of string

type source = {
  pkh : public_key_hash;
  pk : public_key;
  sk : Signature.secret_key;
}

type input_source =
  | Explicit of source
  | Wallet_alias of string
  | Wallet_pkh of public_key_hash

type source_origin = {source : source; origin : origin}

(** Destination of a call: either an implicit contract or an originated one
   with all the necessary data (entrypoint and the argument). *)
type destination =
  | Implicit of Signature.Public_key_hash.t
  | Originated of Smart_contracts.invocation_parameters

type transfer = {
  src : source;
  dst : destination;
  fee : Tez.t;
  gas_limit : Gas.Arith.integral;
  amount : Tez.t;
  counter : Z.t option;
  fresh_dst : bool;
}

type state = {
  rng_state : Random.State.t;
  current_head_on_start : Block_hash.t;
  counters : (Block_hash.t * Z.t) Signature.Public_key_hash.Table.t;
  mutable pool : source_origin list;
  mutable pool_size : int;
      (** [Some l] if [single_op_per_pkh_per_block] is true *)
  mutable shuffled_pool : source list option;
  mutable revealed : Signature.Public_key_hash.Set.t;
  mutable last_block : Block_hash.t;
  mutable last_level : int;
  mutable target_block : Block_hash.t;
      (** The block on top of which we are injecting transactions (HEAD~2). *)
  new_block_condition : unit Lwt_condition.t;
  injected_operations : Operation_hash.t list Block_hash.Table.t;
}

(** Cost estimations for every kind of transaction used in the stress test.
   *)
type transaction_costs = {
  regular : Gas.Arith.integral;  (** Cost of a regular transaction. *)
  smart_contracts : (string * Gas.Arith.integral) list;
      (** Cost of a smart contract call (per contract alias). *)
}

type verbosity = Notice | Info | Debug

let verbosity = ref Notice

let log level msg =
  match (level, !verbosity) with
  | Notice, _ | Info, Info | Info, Debug | Debug, Debug -> msg ()
  | _ -> Lwt.return_unit

let pp_sep ppf () = Format.fprintf ppf ",@ "

let default_parameters =
  {
    seed = 0x533D;
    fresh_probability = 0.001;
    tps = 5.0;
    strategy = Fixed_amount {mutez = Tez.one};
    regular_transfer_fee = Tez.of_mutez_exn 2_000L;
    regular_transfer_gas_limit = Gas.Arith.integral_of_int_exn 1_600;
    (* [gas_limit] corresponds to a slight overapproximation of the
       gas needed to inject an operation. It was obtained by simulating
       the operation using the client. *)
    storage_limit = Z.zero;
    account_creation_storage = Z.of_int 300;
    (* [account_creation_storage] corresponds to a slight overapproximation
       of the storage consumed when allocating a new implicit account.
       It was obtained by simulating the operation using the client. *)
    total_transfers = None;
    single_op_per_pkh_per_block = false;
    level_limit = None;
    smart_contracts = Smart_contracts.no_contracts;
  }

let input_source_encoding =
  let open Data_encoding in
  union
    [
      case
        ~title:"explicit"
        (Tag 0)
        (obj3
           (req "pkh" Signature.Public_key_hash.encoding)
           (req "pk" Signature.Public_key.encoding)
           (req "sk" Signature.Secret_key.encoding))
        (function Explicit {pkh; pk; sk} -> Some (pkh, pk, sk) | _ -> None)
        (fun (pkh, pk, sk) -> Explicit {pkh; pk; sk});
      case
        ~title:"alias"
        (Tag 1)
        (obj1 (req "alias" Data_encoding.string))
        (function Wallet_alias alias -> Some alias | _ -> None)
        (fun alias -> Wallet_alias alias);
      case
        ~title:"pkh"
        (Tag 2)
        (obj1 (req "pkh" Signature.Public_key_hash.encoding))
        (function Wallet_pkh pkh -> Some pkh | _ -> None)
        (fun pkh -> Wallet_pkh pkh);
    ]

let input_source_list_encoding = Data_encoding.list input_source_encoding

let injected_operations_encoding =
  let open Data_encoding in
  list
    (obj2
       (req "block_hash_when_injected" Block_hash.encoding)
       (req "operation_hashes" (list Operation_hash.encoding)))

let transaction_costs_encoding =
  let open Data_encoding in
  conv
    (fun {regular; smart_contracts} -> (regular, smart_contracts))
    (fun (regular, smart_contracts) -> {regular; smart_contracts})
    (obj2
       (req "regular" Gas.Arith.n_integral_encoding)
       (req "smart_contracts" (assoc Gas.Arith.n_integral_encoding)))

let destination_to_contract dst =
  match dst with
  | Implicit x -> Contract.Implicit x
  | Originated x -> x.destination

let parse_strategy s =
  match String.split ~limit:1 ':' s with
  | ["fixed"; parameter] -> (
      match int_of_string parameter with
      | exception _ -> Error "invalid integer literal"
      | mutez when mutez <= 0 -> Error "negative amount"
      | mutez -> (
          match Tez.of_mutez (Int64.of_int mutez) with
          | None -> Error "invalid mutez"
          | Some mutez -> Ok (Fixed_amount {mutez})))
  | ["evaporation"; parameter] -> (
      match float_of_string parameter with
      | exception _ -> Error "invalid float literal"
      | fraction when fraction < 0.0 || fraction > 1.0 ->
          Error "invalid evaporation rate"
      | fraction -> Ok (Evaporation {fraction}))
  | _ -> Error "invalid argument"

(** This command uses two different data structures for sources:
    - The in-output files one,
    - The normalized one.

    The data structure used for in-output files does not directly contain the
    data required to forge operations. For efficiency purposes, the sources are
    converted into a normalized data structure that contains all the required
    data to forge operations and the format originally used to be able to
    revert this conversion. *)

(** [normalize_source cctxt src] converts [src] from in-output data structure
    to normalized one. If the conversion fails, [None] is returned and a
    warning message is printed in [cctxt].

    Only unencrypted and encrypted sources from the wallet of [cctxt] are
    supported. *)
let normalize_source cctxt =
  let open Lwt_syntax in
  let sk_of_sk_uri sk_uri =
    match
      Signature.Secret_key.of_b58check
        (Uri.path (sk_uri : Client_keys.sk_uri :> Uri.t))
    with
    | Ok sk -> Lwt.return_some sk
    | Error _ ->
        let+ r = Tezos_signer_backends.Encrypted.decrypt cctxt sk_uri in
        Option.of_result r
  in
  let key_from_alias alias =
    let warning msg alias =
      let* () = cctxt#warning msg alias in
      return_none
    in
    let* key =
      let* r = Client_keys.alias_keys cctxt alias in
      match r with
      | Error _ | Ok None ->
          warning "Alias \"%s\" not found in the wallet" alias
      | Ok (Some (_, None, _)) | Ok (Some (_, _, None)) ->
          warning
            "Alias \"%s\" does not contain public or secret key and could not \
             be used for stresstest"
            alias
      | Ok (Some (pkh, Some pk, Some sk_uri)) -> (
          let* o = sk_of_sk_uri sk_uri in
          match o with
          | None ->
              warning
                "Cannot extract the secret key form the alias \"%s\" of the \
                 wallet"
                alias
          | Some sk ->
              Lwt.return_some
                {source = {pkh; pk; sk}; origin = Wallet_alias alias})
    in
    match key with
    | None -> warning "Source given as alias \"%s\" ignored" alias
    | key -> Lwt.return key
  in
  let key_from_wallet pkh =
    let warning msg pkh =
      let* () = cctxt#warning msg Signature.Public_key_hash.pp pkh in
      return_none
    in
    let* key =
      let* r = Client_keys.get_key cctxt pkh in
      match r with
      | Error _ -> warning "Pkh \"%a\" not found in the wallet" pkh
      | Ok (alias, pk, sk_uri) -> (
          let* o = sk_of_sk_uri sk_uri in
          match o with
          | None ->
              let* () =
                cctxt#warning
                  "Cannot extract the secret key form the pkh \"%a\" (alias: \
                   \"%s\") of the wallet"
                  Signature.Public_key_hash.pp
                  pkh
                  alias
              in
              Lwt.return_none
          | Some sk ->
              Lwt.return_some {source = {pkh; pk; sk}; origin = Wallet_pkh})
    in
    match key with
    | None -> warning "Source given as pkh \"%a\" ignored" pkh
    | key -> Lwt.return key
  in
  function
  | Explicit source -> Lwt.return_some {source; origin = Explicit}
  | Wallet_alias alias -> key_from_alias alias
  | Wallet_pkh pkh -> key_from_wallet pkh

(** [unnormalize_source src_org] converts [src_org] from normalized data
    structure to in-output one. *)
let unnormalize_source src_org =
  match src_org.origin with
  | Explicit -> Explicit src_org.source
  | Wallet_pkh -> Wallet_pkh src_org.source.pkh
  | Wallet_alias alias -> Wallet_alias alias

(** Samples from [state.pool]. Used to generate the destination of a
    transfer, and its source only when [state.shuffled_pool] is [None]
    meaning that [--single-op-per-pkh-per-block] is not set. *)
let sample_any_source_from_pool state =
  let idx = Random.State.int state.rng_state state.pool_size in
  match List.nth state.pool idx with
  | None -> assert false
  | Some src_org -> Lwt.return src_org.source

(** Generates the source of a transfer. If [state.shuffled_pool] has a
    value (meaning that [--single-op-per-pkh-per-block] is active) then
    it is sampled from there, otherwise from [state.pool]. *)
let rec sample_source_from_pool state (cctxt : Protocol_client_context.full) =
  let open Lwt_syntax in
  match state.shuffled_pool with
  | None -> sample_any_source_from_pool state
  | Some (source :: l) ->
      state.shuffled_pool <- Some l ;
      let* () =
        log Debug (fun () ->
            cctxt#message
              "sample_transfer: %d unused sources for the block next to %a"
              (List.length l)
              Block_hash.pp
              state.last_block)
      in
      Lwt.return source
  | Some [] ->
      let* () =
        cctxt#message
          "all available sources have been used for block next to %a"
          Block_hash.pp
          state.last_block
      in
      let* () = Lwt_condition.wait state.new_block_condition in
      sample_source_from_pool state cctxt

let random_seed rng =
  Bytes.init 32 (fun _ -> Char.chr (Random.State.int rng 256))

let generate_fresh_source state =
  let seed = random_seed state.rng_state in
  let pkh, pk, sk = Signature.generate_key ~seed () in
  let fresh = {source = {pkh; pk; sk}; origin = Explicit} in
  state.pool <- fresh :: state.pool ;
  state.pool_size <- state.pool_size + 1 ;
  fresh.source

(* [heads_iter cctxt f] calls [f head] each time there is a new head received
   by the streamed RPC /monitor/heads/main and returns [promise, stopper].
   [promise] resolved when the stream is closed. [stopper ()] closes the
   stream. *)
let heads_iter (cctxt : Protocol_client_context.full)
    (f : Block_hash.t * Tezos_base.Block_header.t -> unit tzresult Lwt.t) :
    (unit tzresult Lwt.t * RPC_context.stopper) tzresult Lwt.t =
  let open Lwt_result_syntax in
  let* heads_stream, stopper = Shell_services.Monitor.heads cctxt `Main in
  let rec loop () : unit tzresult Lwt.t =
    let*! block_hash_and_header = Lwt_stream.get heads_stream in
    match block_hash_and_header with
    | None -> Error_monad.failwith "unexpected end of block stream@."
    | Some ((new_block_hash, _block_header) as block_hash_and_header) ->
        Lwt.catch
          (fun () ->
            let*! () =
              log Debug (fun () ->
                  cctxt#message
                    "heads_iter: new block received %a@."
                    Block_hash.pp
                    new_block_hash)
            in
            let* protocols =
              Shell_services.Blocks.protocols
                cctxt
                ~block:(`Hash (new_block_hash, 0))
                ()
            in
            if Protocol_hash.(protocols.current_protocol = Protocol.hash) then
              let* () = f block_hash_and_header in
              loop ()
            else
              let*! () =
                log Debug (fun () ->
                    cctxt#message
                      "heads_iter: new block on protocol %a. Stopping \
                       iteration.@."
                      Protocol_hash.pp
                      protocols.current_protocol)
              in
              return_unit)
          (fun exn ->
            Error_monad.failwith
              "An exception occurred on a function bound on new heads : %s@."
              (Printexc.to_string exn))
  in
  let promise = loop () in
  let*! () =
    log Debug (fun () ->
        cctxt#message
          "head iteration for proto %a stopped@."
          Protocol_hash.pp
          Protocol.hash)
  in
  return (promise, stopper)

let sample_smart_contracts smart_contracts rng_state =
  let smart_contract =
    Smart_contracts.select smart_contracts (Random.State.float rng_state 1.0)
  in
  Option.map
    (fun invocation_parameters ->
      ( Originated invocation_parameters,
        invocation_parameters.fee,
        invocation_parameters.gas_limit ))
    smart_contract

(* We perform rejection sampling of valid sources.
   We could maintain a local cache of existing contracts with sufficient balance. *)
let rec sample_transfer (cctxt : Protocol_client_context.full) chain block
    (parameters : parameters) (state : state) =
  let open Lwt_result_syntax in
  let*! src = sample_source_from_pool state cctxt in
  let* tez =
    Alpha_services.Contract.balance
      cctxt
      (chain, block)
      (Contract.Implicit src.pkh)
  in
  if Tez.(tez = zero) then
    let*! () =
      log Debug (fun () ->
          cctxt#message
            "sample_transfer: invalid balance %a"
            Signature.Public_key_hash.pp
            src.pkh)
    in
    (* Sampled source has zero balance: the transfer that created that
       address was not included yet. Retry *)
    sample_transfer cctxt chain block parameters state
  else
    let fresh =
      Random.State.float state.rng_state 1.0 < parameters.fresh_probability
    in
    let* dst, fee, gas_limit =
      match
        sample_smart_contracts parameters.smart_contracts state.rng_state
      with
      | None ->
          let*! dest =
            if fresh then Lwt.return (generate_fresh_source state)
            else sample_any_source_from_pool state
          in
          return
            ( Implicit dest.pkh,
              parameters.regular_transfer_fee,
              parameters.regular_transfer_gas_limit )
      | Some v -> return v
    in
    let amount =
      match parameters.strategy with
      | Fixed_amount {mutez} -> mutez
      | Evaporation {fraction} ->
          let mutez = Int64.to_float (Tez.to_mutez tez) in
          let max_fraction = Int64.of_float (mutez *. fraction) in
          let amount =
            if max_fraction = 0L then 1L
            else max 1L (Random.State.int64 state.rng_state max_fraction)
          in
          Tez.of_mutez_exn amount
    in
    return {src; dst; fee; gas_limit; amount; counter = None; fresh_dst = fresh}

let inject_contents (cctxt : Protocol_client_context.full) branch sk contents =
  let bytes =
    Data_encoding.Binary.to_bytes_exn
      Operation.unsigned_encoding
      ({branch}, Contents_list contents)
  in
  let signature =
    Some (Signature.sign ~watermark:Signature.Generic_operation sk bytes)
  in
  let op : _ Operation.t =
    {shell = {branch}; protocol_data = {contents; signature}}
  in
  let bytes =
    Data_encoding.Binary.to_bytes_exn Operation.encoding (Operation.pack op)
  in
  Shell_services.Injection.operation cctxt bytes

(* counter _must_ be set before calling this function *)
let manager_op_of_transfer parameters
    {src; dst; fee; gas_limit; amount; counter; fresh_dst} =
  let source = src.pkh in
  let storage_limit =
    if fresh_dst then
      Z.add parameters.account_creation_storage parameters.storage_limit
    else parameters.storage_limit
  in
  let operation =
    let parameters =
      let open Tezos_micheline in
      Script.lazy_expr
        (match dst with
        | Implicit _ ->
            Micheline.strip_locations
              (Prim (0, Michelson_v1_primitives.D_Unit, [], []))
        | Originated x -> x.arg)
    in
    let entrypoint =
      match dst with
      | Implicit _ -> Entrypoint.default
      | Originated x -> x.entrypoint
    in
    let destination = destination_to_contract dst in
    Transaction {amount; parameters; entrypoint; destination}
  in
  match counter with
  | None -> assert false
  | Some counter ->
      Manager_operation
        {source; fee; counter; operation; gas_limit; storage_limit}

let cost_of_manager_operation = Gas.Arith.integral_of_int_exn 1_000

let inject_transfer (cctxt : Protocol_client_context.full) parameters state
    transfer =
  let open Lwt_result_syntax in
  let* branch = Shell_services.Blocks.hash cctxt () in
  let* pcounter =
    Alpha_services.Contract.counter cctxt (`Main, `Head 0) transfer.src.pkh
  in
  let freshest_counter =
    match
      Signature.Public_key_hash.Table.find state.counters transfer.src.pkh
    with
    | None ->
        (* This is the first operation we inject for this pkh: the counter given
           by the RPC _must_ be the freshest one. *)
        pcounter
    | Some (previous_branch, previous_counter) ->
        if Block_hash.equal branch previous_branch then
          (* We already injected an operation on top of this block: the one stored
             locally is the freshest one. *)
          previous_counter
        else
          (* It seems the block changed since we last injected an operation:
             this invalidates the previously stored counter. We return the counter
             given by the RPC. *)
          pcounter
  in
  let* already_revealed =
    if Signature.Public_key_hash.Set.mem transfer.src.pkh state.revealed then
      return true
    else (
      (* Either the [manager_key] RPC tells us the key is already
         revealed, or we immediately inject a reveal operation: in any
         case the key is revealed in the end. *)
      state.revealed <-
        Signature.Public_key_hash.Set.add transfer.src.pkh state.revealed ;
      let* pk_opt =
        Alpha_services.Contract.manager_key
          cctxt
          (`Main, `Head 0)
          transfer.src.pkh
      in
      return (Option.is_some pk_opt))
  in
  let*! r =
    if not already_revealed then (
      let reveal_counter = Z.succ freshest_counter in
      let transf_counter = Z.succ reveal_counter in
      let reveal =
        Manager_operation
          {
            source = transfer.src.pkh;
            fee = Tez.zero;
            counter = reveal_counter;
            gas_limit = cost_of_manager_operation;
            storage_limit = Z.zero;
            operation = Reveal transfer.src.pk;
          }
      in
      let manager_op =
        manager_op_of_transfer
          parameters
          {transfer with counter = Some transf_counter}
      in
      let list = Cons (reveal, Single manager_op) in
      Signature.Public_key_hash.Table.remove state.counters transfer.src.pkh ;
      Signature.Public_key_hash.Table.add
        state.counters
        transfer.src.pkh
        (branch, transf_counter) ;
      let*! () =
        log Info (fun () ->
            cctxt#message
              "injecting reveal+transfer from %a (counters=%a,%a) to %a"
              Signature.Public_key_hash.pp
              transfer.src.pkh
              Z.pp_print
              reveal_counter
              Z.pp_print
              transf_counter
              Contract.pp
              (destination_to_contract transfer.dst))
      in
      (* NB: regardless of our best efforts to keep track of counters, injection can fail with
         "counter in the future" if a block switch happens in between the moment we
         get the branch and the moment we inject, and the new block does not include
         all the operations we injected. *)
      inject_contents cctxt state.target_block transfer.src.sk list)
    else
      let transf_counter = Z.succ freshest_counter in
      let manager_op =
        manager_op_of_transfer
          parameters
          {transfer with counter = Some transf_counter}
      in
      let list = Single manager_op in
      Signature.Public_key_hash.Table.remove state.counters transfer.src.pkh ;
      Signature.Public_key_hash.Table.add
        state.counters
        transfer.src.pkh
        (branch, transf_counter) ;
      let*! () =
        log Info (fun () ->
            cctxt#message
              "injecting transfer from %a (counter=%a) to %a"
              Signature.Public_key_hash.pp
              transfer.src.pkh
              Z.pp_print
              transf_counter
              Contract.pp
              (destination_to_contract transfer.dst))
      in
      (* See comment above. *)
      inject_contents cctxt state.target_block transfer.src.sk list
  in
  match r with
  | Ok op_hash ->
      let*! () =
        log Debug (fun () ->
            cctxt#message
              "inject_transfer: op injected %a"
              Operation_hash.pp
              op_hash)
      in
      let ops =
        Option.value
          ~default:[]
          (Block_hash.Table.find state.injected_operations branch)
      in
      Block_hash.Table.replace state.injected_operations branch (op_hash :: ops) ;
      return_unit
  | Error e ->
      let*! () =
        log Debug (fun () ->
            cctxt#message
              "inject_transfer: error, op not injected: %a"
              Error_monad.pp_print_trace
              e)
      in
      return_unit

let save_injected_operations (cctxt : Protocol_client_context.full) state =
  let open Lwt_syntax in
  let json =
    Data_encoding.Json.construct
      injected_operations_encoding
      (Block_hash.Table.fold
         (fun k v acc -> (k, v) :: acc)
         state.injected_operations
         [])
  in
  let path =
    Filename.temp_file "client-stresstest-injected_operations-" ".json"
  in
  let* () = cctxt#message "writing injected operations in file %s" path in
  let* r = Lwt_utils_unix.Json.write_file path json in
  match r with
  | Error e ->
      cctxt#message
        "could not write injected operations json file: %a"
        Error_monad.pp_print_trace
        e
  | Ok _ -> Lwt.return_unit

let stat_on_exit (cctxt : Protocol_client_context.full) state =
  let open Lwt_result_syntax in
  let ratio_injected_included_op () =
    let* current_head_on_exit = Shell_services.Blocks.hash cctxt () in
    let inter_cardinal s1 s2 =
      Operation_hash.Set.cardinal
        (Operation_hash.Set.inter
           (Operation_hash.Set.of_list s1)
           (Operation_hash.Set.of_list s2))
    in
    let get_included_ops older_block =
      let rec get_included_ops block acc_included_ops =
        if block = older_block then return acc_included_ops
        else
          let* included_ops =
            Shell_services.Chain.Blocks.Operation_hashes
            .operation_hashes_in_pass
              cctxt
              ~chain:`Main
              ~block:(`Hash (block, 0))
              3
          in
          let* bs =
            Shell_services.Blocks.list
              cctxt
              ~chain:`Main
              ~heads:[block]
              ~length:2
              ()
          in
          match bs with
          | [[current; predecessor]] when current = block ->
              get_included_ops
                predecessor
                (List.append acc_included_ops included_ops)
          | _ -> cctxt#error "Error while computing stats: invalid block list"
      in
      get_included_ops current_head_on_exit []
    in
    let injected_ops =
      Block_hash.Table.fold
        (fun k l acc ->
          (* The operations injected during the last block are ignored because
             they should not be currently included. *)
          if current_head_on_exit <> k then List.append acc l else acc)
        state.injected_operations
        []
    in
    let* included_ops = get_included_ops state.current_head_on_start in
    let included_ops_count = inter_cardinal injected_ops included_ops in
    let*! () =
      log Debug (fun () ->
          cctxt#message
            "injected : [%a]@.included: [%a]"
            (Format.pp_print_list ~pp_sep Operation_hash.pp)
            injected_ops
            (Format.pp_print_list ~pp_sep Operation_hash.pp)
            included_ops)
    in
    let injected_ops_count = List.length injected_ops in
    let*! () =
      cctxt#message
        "%s of the injected operations have been included (%d injected, %d \
         included). Note that the operations injected during the last block \
         are ignored because they should not be currently included."
        (if Int.equal injected_ops_count 0 then "N/A"
        else
          Format.sprintf "%d%%" (included_ops_count * 100 / injected_ops_count))
        injected_ops_count
        included_ops_count
    in
    return_unit
  in
  ratio_injected_included_op ()

let launch (cctxt : Protocol_client_context.full) (parameters : parameters)
    state save_pool_callback =
  let injected = ref 0 in
  let target_level =
    match parameters.level_limit with
    | None -> None
    | Some (Abs target) -> Some target
    | Some (Rel offset) -> Some (state.last_level + offset)
  in
  let dt = 1. /. parameters.tps in
  let terminated () =
    let open Lwt_syntax in
    if
      match parameters.total_transfers with
      | None -> false
      | Some bound -> bound <= !injected
    then
      let* () =
        cctxt#message
          "Stopping after %d injections (target %a)."
          !injected
          Format.(pp_print_option pp_print_int)
          parameters.total_transfers
      in
      Lwt.return_true
    else
      match target_level with
      | None -> Lwt.return_false
      | Some target ->
          if target <= state.last_level then
            let* () =
              cctxt#message
                "Stopping at level %d (target level: %d)."
                state.last_level
                target
            in
            Lwt.return_true
          else Lwt.return_false
  in

  let rec loop () =
    let open Lwt_result_syntax in
    let*! terminated = terminated () in
    if terminated then
      let*! () = save_pool_callback () in
      let*! () = save_injected_operations cctxt state in
      stat_on_exit cctxt state
    else
      let start = Mtime_clock.elapsed () in
      let*! () =
        log Debug (fun () ->
            cctxt#message "launch.loop: invoke sample_transfer")
      in
      let* transfer =
        sample_transfer cctxt cctxt#chain cctxt#block parameters state
      in
      let*! () =
        log Debug (fun () ->
            cctxt#message "launch.loop: invoke inject_transfer")
      in
      let* () = inject_transfer cctxt parameters state transfer in
      incr injected ;
      let stop = Mtime_clock.elapsed () in
      let elapsed = Mtime.Span.(to_s stop -. to_s start) in
      let remaining = dt -. elapsed in
      let*! () =
        if remaining <= 0.0 then
          cctxt#warning
            "warning: tps target could not be reached, consider using a lower \
             value for --tps"
        else Lwt_unix.sleep remaining
      in
      loop ()
  in
  let on_new_head :
      Block_hash.t * Tezos_base.Block_header.t -> unit tzresult Lwt.t =
    (* Because of how Tenderbake works the target block should stay 2
       blocks in the past because this guarantees that we are targeting a
       block that is decided. *)
    let open Lwt_result_syntax in
    let update_target_block () =
      let* target_block =
        Shell_services.Blocks.hash cctxt ~block:(`Head 2) ()
      in
      state.target_block <- target_block ;
      return_unit
    in
    match state.shuffled_pool with
    (* Some _ if and only if [single_op_per_pkh_per_block] is true. *)
    | Some _ ->
        fun (new_block_hash, new_block_header) ->
          let* () = update_target_block () in
          if not (Block_hash.equal new_block_hash state.last_block) then (
            state.last_block <- new_block_hash ;
            state.last_level <- Int32.to_int new_block_header.shell.level ;
            state.shuffled_pool <-
              Some
                (List.shuffle
                   ~rng:state.rng_state
                   (List.map (fun src_org -> src_org.source) state.pool))) ;
          Lwt_condition.broadcast state.new_block_condition () ;
          return_unit
    | None ->
        (* only wait for the end of the head stream; don't act on heads *)
        fun _ -> update_target_block ()
  in
  let open Lwt_result_syntax in
  let* heads_iteration, stopper = heads_iter cctxt on_new_head in
  (* The head iteration stops at protocol change. *)
  let* () = Lwt.pick [loop (); heads_iteration] in
  (match Lwt.state heads_iteration with Lwt.Return _ -> () | _ -> stopper ()) ;
  return_unit

let group =
  Clic.{name = "stresstest"; title = "Commands for stress-testing the network"}

type pool_source =
  | From_string of {json : Ezjsonm.value}
  | From_file of {path : string; json : Ezjsonm.value}

let json_of_pool_source = function
  | From_string {json} | From_file {json; _} -> json

let json_file_or_text_parameter =
  Clic.parameter (fun _ p ->
      let open Lwt_result_syntax in
      match String.split ~limit:1 ':' p with
      | ["text"; text] -> return (From_string {json = Ezjsonm.from_string text})
      | ["file"; path] ->
          let+ json = Lwt_utils_unix.Json.read_file path in
          From_file {path; json}
      | _ -> (
          if Sys.file_exists p then
            let+ json = Lwt_utils_unix.Json.read_file p in
            From_file {path = p; json}
          else
            try return (From_string {json = Ezjsonm.from_string p})
            with Ezjsonm.Parse_error _ ->
              failwith "Neither an existing file nor valid JSON: '%s'" p))

let seed_arg =
  let open Clic in
  arg
    ~long:"seed"
    ~placeholder:"int"
    ~doc:"random seed"
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         match int_of_string s with
         | exception _ ->
             cctxt#error
               "While parsing --seed: could not convert argument to int"
         | i -> Lwt_result_syntax.return i))

let tps_arg =
  let open Clic in
  arg
    ~long:"tps"
    ~placeholder:"float"
    ~doc:"transactions per seconds target"
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         match float_of_string s with
         | exception _ ->
             cctxt#error
               "While parsing --tps: could not convert argument to float"
         | f when f < 0.0 ->
             cctxt#error "While parsing --tps: negative argument"
         | f -> Lwt_result_syntax.return f))

let fresh_probability_arg =
  let open Clic in
  arg
    ~long:"fresh-probability"
    ~placeholder:"float in [0;1]"
    ~doc:
      (Format.sprintf
         "Probability for each transaction's destination to be a fresh \
          account. The default value is %g. This new account may then be used \
          as source or destination of subsequent transactions, just like the \
          accounts that were initially provided to the command. Note that when \
          [--single-op-per-pkh-per-block] is set, the new account will not be \
          used as source until the head changes."
         default_parameters.fresh_probability)
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         match float_of_string s with
         | exception _ ->
             cctxt#error
               "While parsing --fresh-probability: could not convert argument \
                to float"
         | f when f < 0.0 || f > 1.0 ->
             cctxt#error "While parsing --fresh-probability: invalid argument"
         | f -> Lwt_result_syntax.return f))

let smart_contract_parameters_arg =
  let open Clic in
  arg
    ~long:"smart-contract-parameters"
    ~placeholder:"JSON file with smart contract parameters"
    ~doc:
      (Format.sprintf
         "A JSON object that maps smart contract aliases to objects with three \
          fields: probability in [0;1], invocation_fee, and \
          invocation_gas_limit.")
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         match Data_encoding.Json.from_string s with
         | Ok json ->
             Lwt_result_syntax.return
               (Data_encoding.Json.destruct
                  Smart_contracts.contract_parameters_collection_encoding
                  json)
         | Error _ ->
             cctxt#error
               "While parsing --smart-contract-parameters: invalid JSON %s"
               s))

let strategy_arg =
  let open Clic in
  arg
    ~long:"strategy"
    ~placeholder:"fixed:mutez | evaporation:[0;1]"
    ~doc:"wealth redistribution strategy"
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         match parse_strategy s with
         | Error msg -> cctxt#error "While parsing --strategy: %s" msg
         | Ok strategy -> Lwt_result_syntax.return strategy))

let gas_limit_arg =
  let open Clic in
  let gas_limit_kind =
    parameter (fun _ s ->
        try
          let v = Z.of_string s in
          Lwt_result_syntax.return (Gas.Arith.integral_exn v)
        with _ -> failwith "invalid gas limit (must be a positive number)")
  in
  arg
    ~long:"gas-limit"
    ~short:'G'
    ~placeholder:"amount"
    ~doc:
      (Format.asprintf
         "Set the gas limit of the transaction instead of using the default \
          value of %a"
         Gas.Arith.pp_integral
         default_parameters.regular_transfer_gas_limit)
    gas_limit_kind

let storage_limit_arg =
  let open Clic in
  let storage_limit_kind =
    parameter (fun _ s ->
        try
          let v = Z.of_string s in
          assert (Compare.Z.(v >= Z.zero)) ;
          Lwt_result_syntax.return v
        with _ ->
          failwith "invalid storage limit (must be a positive number of bytes)")
  in
  arg
    ~long:"storage-limit"
    ~short:'S'
    ~placeholder:"amount"
    ~doc:
      (Format.asprintf
         "Set the storage limit of the transaction instead of using the \
          default value of %a"
         Z.pp_print
         default_parameters.storage_limit)
    storage_limit_kind

let transfers_arg =
  let open Clic in
  arg
    ~long:"transfers"
    ~placeholder:"integer"
    ~doc:"total number of transfers to perform, unbounded if not specified"
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         match int_of_string s with
         | exception _ ->
             cctxt#error "While parsing --transfers: invalid integer literal"
         | i when i <= 0 ->
             cctxt#error "While parsing --transfers: negative integer"
         | i -> Lwt_result_syntax.return i))

let single_op_per_pkh_per_block_arg =
  Clic.switch
    ~long:"single-op-per-pkh-per-block"
    ~doc:
      "ensure that the operations are not rejected by limiting the injection \
       to 1 operation per public_key_hash per block."
    ()

let level_limit_arg =
  let open Clic in
  arg
    ~long:"level-limit"
    ~placeholder:"integer | +integer"
    ~doc:
      "Level at which the stresstest will stop (if prefixed by '+', the level \
       is relative to the current head)"
    (parameter (fun (cctxt : Protocol_client_context.full) s ->
         let open Lwt_result_syntax in
         match int_of_string s with
         | exception _ ->
             cctxt#error "While parsing --levels: invalid integer literal"
         | i when i <= 0 ->
             cctxt#error "While parsing --levels: negative integer or zero"
         | i -> if String.get s 0 = '+' then return (Rel i) else return (Abs i)))

let verbose_arg =
  Clic.switch
    ~long:"verbose"
    ~short:'v'
    ~doc:"Display detailed logs of the injected operations"
    ()

let debug_arg =
  Clic.switch ~long:"debug" ~short:'V' ~doc:"Display debug logs" ()

let set_option opt f x = Option.fold ~none:x ~some:(f x) opt

let save_pool_callback (cctxt : Protocol_client_context.full) pool_source state
    =
  let json =
    Data_encoding.Json.construct
      input_source_list_encoding
      (List.map unnormalize_source state.pool)
  in
  let catch_write_error = function
    | Error e ->
        cctxt#message
          "could not write back json file: %a"
          Error_monad.pp_print_trace
          e
    | Ok () -> Lwt.return_unit
  in
  let open Lwt_syntax in
  match pool_source with
  | From_string _ ->
      (* If the initial pool was given directly as json, save pool to
         a temp file. *)
      let path = Filename.temp_file "client-stresstest-pool-" ".json" in
      let* () = cctxt#message "writing back address pool in file %s" path in
      let* r = Lwt_utils_unix.Json.write_file path json in
      catch_write_error r
  | From_file {path; _} ->
      (* If the pool specification was a json file, save pool to
         the same file. *)
      let* () = cctxt#message "writing back address pool in file %s" path in
      let* r = Lwt_utils_unix.Json.write_file path json in
      catch_write_error r

let generate_random_transactions =
  let open Clic in
  command
    ~group
    ~desc:"Generate random transactions"
    (args13
       seed_arg
       tps_arg
       fresh_probability_arg
       smart_contract_parameters_arg
       strategy_arg
       Client_proto_args.fee_arg
       gas_limit_arg
       storage_limit_arg
       transfers_arg
       single_op_per_pkh_per_block_arg
       level_limit_arg
       verbose_arg
       debug_arg)
    (prefixes ["stresstest"; "transfer"; "using"]
    @@ param
         ~name:"sources.json"
         ~desc:
           {|List of accounts from which to perform transfers in JSON format. The input JSON must be an array of objects of the form {"pkh":"<pkh>","pk":"<pk>","sk":"<sk>"} or  {"alias":"<alias from wallet>"} or {"pkh":"<pkh from wallet>"} with the pkh, pk and sk encoded in B58 form."|}
         json_file_or_text_parameter
    @@ stop)
    (fun ( seed,
           tps,
           freshp,
           smart_contract_parameters,
           strat,
           fee,
           gas_limit,
           storage_limit,
           transfers,
           single_op_per_pkh_per_block,
           level_limit,
           verbose_flag,
           debug_flag )
         sources_json
         (cctxt : Protocol_client_context.full) ->
      let open Lwt_result_syntax in
      (verbosity :=
         match (debug_flag, verbose_flag) with
         | true, _ -> Debug
         | false, true -> Info
         | false, false -> Notice) ;
      let* smart_contracts =
        Smart_contracts.init
          cctxt
          (Option.value ~default:[] smart_contract_parameters)
      in
      let parameters =
        {default_parameters with smart_contracts}
        |> set_option seed (fun parameter seed -> {parameter with seed})
        |> set_option tps (fun parameter tps -> {parameter with tps})
        |> set_option freshp (fun parameter fresh_probability ->
               {parameter with fresh_probability})
        |> set_option strat (fun parameter strategy ->
               {parameter with strategy})
        |> set_option fee (fun parameter regular_transfer_fee ->
               {parameter with regular_transfer_fee})
        |> set_option gas_limit (fun parameter regular_transfer_gas_limit ->
               {parameter with regular_transfer_gas_limit})
        |> set_option storage_limit (fun parameter storage_limit ->
               {parameter with storage_limit})
        |> set_option transfers (fun parameter transfers ->
               {parameter with total_transfers = Some transfers})
        |> fun parameter ->
        {parameter with single_op_per_pkh_per_block}
        |> set_option level_limit (fun parameter level_limit ->
               {parameter with level_limit = Some level_limit})
      in
      match
        Data_encoding.Json.destruct
          input_source_list_encoding
          (json_of_pool_source sources_json)
      with
      | exception _ -> cctxt#error "Could not decode list of sources"
      | [] -> cctxt#error "It is required to provide sources"
      | sources ->
          let*! () =
            log Info (fun () -> cctxt#message "starting to normalize sources")
          in
          let*! sources = List.filter_map_s (normalize_source cctxt) sources in
          let*! () =
            log Info (fun () ->
                cctxt#message "all sources have been normalized")
          in
          let sources =
            List.sort_uniq
              (fun src1 src2 ->
                Signature.Secret_key.compare src1.source.sk src2.source.sk)
              sources
          in
          let counters = Signature.Public_key_hash.Table.create 1023 in
          let rng_state = Random.State.make [|parameters.seed|] in
          let* current_head_on_start = Shell_services.Blocks.hash cctxt () in
          let* header_on_start =
            Shell_services.Blocks.Header.shell_header cctxt ()
          in
          let* () =
            if header_on_start.level <= 2l then
              cctxt#error
                "The level of the head (%a) needs to be greater than 2 and is \
                 actually %ld."
                Block_hash.pp
                current_head_on_start
                header_on_start.level
            else return_unit
          in
          let* current_target_block =
            Shell_services.Blocks.hash cctxt ~block:(`Head 2) ()
          in
          let state =
            {
              rng_state;
              current_head_on_start;
              counters;
              pool = sources;
              pool_size = List.length sources;
              shuffled_pool =
                (if parameters.single_op_per_pkh_per_block then
                 Some
                   (List.shuffle
                      ~rng:rng_state
                      (List.map (fun src_org -> src_org.source) sources))
                else None);
              revealed = Signature.Public_key_hash.Set.empty;
              last_block = current_head_on_start;
              last_level = Int32.to_int header_on_start.level;
              target_block = current_target_block;
              new_block_condition = Lwt_condition.create ();
              injected_operations = Block_hash.Table.create 1023;
            }
          in
          let exit_callback_id =
            Lwt_exit.register_clean_up_callback ~loc:__LOC__ (fun _retcode ->
                let*! r = stat_on_exit cctxt state in
                match r with
                | Ok () -> Lwt.return_unit
                | Error e ->
                    cctxt#message "Error: %a" Error_monad.pp_print_trace e)
          in
          let save_pool () = save_pool_callback cctxt sources_json state in
          (* Register a callback for saving the pool when the tool is interrupted
             through ctrl-c *)
          let exit_callback_id =
            Lwt_exit.register_clean_up_callback
              ~loc:__LOC__
              ~after:[exit_callback_id]
              (fun _retcode -> save_pool ())
          in
          let save_injected_operations () =
            save_injected_operations cctxt state
          in
          ignore
            (Lwt_exit.register_clean_up_callback
               ~loc:__LOC__
               ~after:[exit_callback_id]
               (fun _retcode -> save_injected_operations ())) ;
          launch cctxt parameters state save_pool)

let estimate_transaction_cost ?smart_contracts
    (cctxt : Protocol_client_context.full) : Gas.Arith.integral tzresult Lwt.t =
  let open Lwt_result_syntax in
  let*! src = normalize_source cctxt (Wallet_alias "bootstrap1") in
  let*! dst = normalize_source cctxt (Wallet_alias "bootstrap2") in
  let rng_state = Random.State.make [|default_parameters.seed|] in
  let* src, dst =
    match (src, dst) with
    | Some src, Some dst -> return (src, dst)
    | _ ->
        cctxt#error
          "Cannot find bootstrap1 or bootstrap2 accounts in the wallet."
  in
  let chain = cctxt#chain in
  let block = cctxt#block in
  let selected_smart_contract =
    Option.bind smart_contracts (fun smart_contracts ->
        sample_smart_contracts smart_contracts rng_state)
  in
  let dst, fee, gas_limit =
    Option.value
      selected_smart_contract
      ~default:
        ( Implicit dst.source.pkh,
          default_parameters.regular_transfer_fee,
          default_parameters.regular_transfer_gas_limit )
  in
  let* current_counter =
    Alpha_services.Contract.counter cctxt (chain, block) src.source.pkh
  in
  let transf_counter = Z.succ current_counter in
  let transfer =
    {
      src = src.source;
      dst;
      fee;
      gas_limit;
      amount = Tez.of_mutez_exn (Int64.of_int 1);
      counter = Some transf_counter;
      fresh_dst = false;
    }
  in
  let manager_op =
    manager_op_of_transfer
      {
        default_parameters with
        regular_transfer_gas_limit =
          Default_parameters.constants_mainnet.hard_gas_limit_per_operation;
      }
      transfer
  in
  let* _oph, op, result =
    Injection.simulate cctxt ~chain ~block (Single manager_op)
  in
  match result.contents with
  | Single_result (Manager_operation_result {operation_result; _}) -> (
      match operation_result with
      | Applied
          (Transaction_result
            (Transaction_to_contract_result {consumed_gas; _})) ->
          return (Gas.Arith.ceil consumed_gas)
      | _ ->
          (match operation_result with
          | Failed (_, errors) ->
              Error_monad.pp_print_trace
                Format.err_formatter
                (Environment.wrap_tztrace errors)
          | _ -> assert false) ;
          cctxt#error
            "@[<v 2>Simulation result:@,%a@]"
            Operation_result.pp_operation_result
            (op.protocol_data.contents, result.contents))

let estimate_transaction_costs : Protocol_client_context.full Clic.command =
  let open Clic in
  command
    ~group
    ~desc:"Output gas estimations for transactions that stresstest uses"
    no_options
    (prefixes ["stresstest"; "estimate"; "gas"] @@ stop)
    (fun () cctxt ->
      let open Lwt_result_syntax in
      let* regular = estimate_transaction_cost cctxt in
      let* smart_contracts =
        Smart_contracts.with_every_known_smart_contract
          cctxt
          (fun smart_contracts ->
            estimate_transaction_cost ~smart_contracts cctxt)
      in
      let transaction_costs : transaction_costs = {regular; smart_contracts} in
      let json =
        Data_encoding.Json.construct
          transaction_costs_encoding
          transaction_costs
      in
      Format.printf "%a" Data_encoding.Json.pp json ;
      return_unit)

let commands network () =
  match network with
  | Some `Mainnet -> []
  | Some `Testnet | None ->
      [
        generate_random_transactions;
        estimate_transaction_costs;
        Smart_contracts.originate_command;
      ]
