// SPDX-License-Identifier: Apache-2.0
// PoC deploy script. Registers Zeto_AnonNullifier (nullifier + on-chain SMT)
// with the factory.
//
// NOTE: The file is named DeployZetoAnon.s.sol for historical reasons —
// previously it also registered a Zeto_Anon (non-nullifier) variant. That
// variant has been removed; only Zeto_AnonNullifier remains.
//
// The transfer verifier is generated from our locally-built zkey (see
// sandbox-backend/scripts/build-circuits.sh). Vendored Zeto verifiers
// referenced below are unused by the PoC code path but still need real
// addresses in the factory's VerifiersInfo slots.
//
// Library linking: Zeto_AnonNullifier pulls in iden3 SmtLib + PoseidonUnit2L/3L.
// `forge script` is invoked with --libraries pointing at addresses already
// deployed by deploy-zeto.sh (cast send for raw Poseidon hex; forge create
// for SmtLib).
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

// Local verifier (snarkjs-generated, matching our local zkey).
import {Groth16Verifier_AnonNullifierTransfer} from "../src/verifiers/Verifier_AnonNullifierTransfer.sol";

// Vendored verifiers we don't actually exercise but that still need real
// addresses in some factory slots. Deposit/withdraw are unused by the PoC;
// they register the matching slots so the factory record is valid even if
// those code paths are never invoked.
import {Groth16Verifier_Deposit} from "zeto/verifiers/verifier_deposit.sol";
import {Groth16Verifier_WithdrawNullifier} from "zeto/verifiers/verifier_withdraw_nullifier.sol";
import {Groth16Verifier_WithdrawNullifierBatch} from "zeto/verifiers/verifier_withdraw_nullifier_batch.sol";
import {Groth16Verifier_AnonNullifierTransferBatch} from "zeto/verifiers/verifier_anon_nullifier_transfer_batch.sol";

import {Zeto_AnonNullifier} from "zeto/zeto_anon_nullifier.sol";
import {ZetoTokenFactory} from "zeto/factory.sol";
import {IZetoInitializable} from "zeto/lib/interfaces/IZetoInitializable.sol";
import {IGroth16Verifier} from "zeto/lib/interfaces/IZetoVerifier.sol";

contract DeployZetoAnon is Script {
    IGroth16Verifier constant ZERO = IGroth16Verifier(address(0));

    function run() external {
        vm.startBroadcast();

        // ----- Verifiers -----
        address anonNullV = address(new Groth16Verifier_AnonNullifierTransfer());
        address anonNullBatchV = address(new Groth16Verifier_AnonNullifierTransferBatch());
        address depositV = address(new Groth16Verifier_Deposit());
        address withdrawNullV = address(new Groth16Verifier_WithdrawNullifier());
        address withdrawNullBatchV = address(new Groth16Verifier_WithdrawNullifierBatch());

        // ----- Token implementation (cloneable, not initialized) -----
        address implAnonNullifier = address(new Zeto_AnonNullifier());

        // ----- Factory -----
        ZetoTokenFactory factory = new ZetoTokenFactory();

        // VerifiersInfo packs 9 slots: verifier, deposit, withdraw, lock,
        // burn, batchVerifier, batchWithdraw, batchLock, batchBurn.
        //
        // Zeto_AnonNullifier: locked variants are not exercised; the lock/burn
        // slots stay ZERO.
        factory.registerImplementation(
            "Zeto_AnonNullifier",
            ZetoTokenFactory.ImplementationInfo({
                implementation: implAnonNullifier,
                verifiers: IZetoInitializable.VerifiersInfo({
                    verifier: IGroth16Verifier(anonNullV),
                    depositVerifier: IGroth16Verifier(depositV),
                    withdrawVerifier: IGroth16Verifier(withdrawNullV),
                    lockVerifier: ZERO,
                    burnVerifier: ZERO,
                    batchVerifier: IGroth16Verifier(anonNullBatchV),
                    batchWithdrawVerifier: IGroth16Verifier(withdrawNullBatchV),
                    batchLockVerifier: ZERO,
                    batchBurnVerifier: ZERO
                })
            })
        );

        vm.stopBroadcast();

        console.log("Groth16Verifier_AnonNullifierTransfer:", anonNullV);
        console.log("Zeto_AnonNullifier (impl):", implAnonNullifier);
        console.log("ZetoTokenFactory:", address(factory));
    }
}
