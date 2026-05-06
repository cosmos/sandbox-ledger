// SPDX-License-Identifier: Apache-2.0
// PoC deploy script. Registers two variants with the factory:
//   - Zeto_Anon            (commitment-graph linkable; simpler circuit)
//   - Zeto_AnonNullifier   (nullifier + on-chain SMT; better privacy)
//
// The verifiers for both are generated from our locally-built zkeys (see
// sandbox-backend/scripts/build-circuits.sh). Vendored Zeto verifiers are
// bypassed because their IC constants don't match our zkeys.
//
// Library linking: Zeto_AnonNullifier pulls in iden3 SmtLib + PoseidonUnit2L/3L.
// `forge script` is invoked with --libraries pointing at addresses already
// deployed by deploy-zeto.sh (cast send for raw Poseidon hex; forge create
// for SmtLib).
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

// Local verifiers (snarkjs-generated, matching our local zkeys).
import {Groth16Verifier_Anon} from "../src/verifiers/Verifier_Anon.sol";
import {Groth16Verifier_AnonNullifierTransfer} from "../src/verifiers/Verifier_AnonNullifierTransfer.sol";

// Vendored verifiers we don't actually exercise but that still need real
// addresses in some factory slots. Anon batch + deposit/withdraw are unused
// by the PoC; they register the matching slots so the factory record is
// valid even if those code paths are never invoked.
import {Groth16Verifier_AnonBatch} from "zeto/verifiers/verifier_anon_batch.sol";
import {Groth16Verifier_Deposit} from "zeto/verifiers/verifier_deposit.sol";
import {Groth16Verifier_Withdraw} from "zeto/verifiers/verifier_withdraw.sol";
import {Groth16Verifier_WithdrawBatch} from "zeto/verifiers/verifier_withdraw_batch.sol";
import {Groth16Verifier_WithdrawNullifier} from "zeto/verifiers/verifier_withdraw_nullifier.sol";
import {Groth16Verifier_WithdrawNullifierBatch} from "zeto/verifiers/verifier_withdraw_nullifier_batch.sol";
import {Groth16Verifier_AnonNullifierTransferBatch} from "zeto/verifiers/verifier_anon_nullifier_transfer_batch.sol";

import {Zeto_Anon} from "zeto/zeto_anon.sol";
import {Zeto_AnonNullifier} from "zeto/zeto_anon_nullifier.sol";
import {ZetoTokenFactory} from "zeto/factory.sol";
import {IZetoInitializable} from "zeto/lib/interfaces/IZetoInitializable.sol";
import {IGroth16Verifier} from "zeto/lib/interfaces/IZetoVerifier.sol";

contract DeployZetoAnon is Script {
    IGroth16Verifier constant ZERO = IGroth16Verifier(address(0));

    function run() external {
        vm.startBroadcast();

        // ----- Verifiers -----
        address anonV = address(new Groth16Verifier_Anon());
        address anonBatchV = address(new Groth16Verifier_AnonBatch());
        address anonNullV = address(new Groth16Verifier_AnonNullifierTransfer());
        address anonNullBatchV = address(new Groth16Verifier_AnonNullifierTransferBatch());
        address depositV = address(new Groth16Verifier_Deposit());
        address withdrawV = address(new Groth16Verifier_Withdraw());
        address withdrawBatchV = address(new Groth16Verifier_WithdrawBatch());
        address withdrawNullV = address(new Groth16Verifier_WithdrawNullifier());
        address withdrawNullBatchV = address(new Groth16Verifier_WithdrawNullifierBatch());

        // ----- Token implementations (cloneable, not initialized) -----
        address implAnon = address(new Zeto_Anon());
        address implAnonNullifier = address(new Zeto_AnonNullifier());

        // ----- Factory -----
        ZetoTokenFactory factory = new ZetoTokenFactory();

        // VerifiersInfo packs 9 slots: verifier, deposit, withdraw, lock,
        // burn, batchVerifier, batchWithdraw, batchLock, batchBurn.

        factory.registerImplementation(
            "Zeto_Anon",
            ZetoTokenFactory.ImplementationInfo({
                implementation: implAnon,
                verifiers: IZetoInitializable.VerifiersInfo({
                    verifier: IGroth16Verifier(anonV),
                    depositVerifier: IGroth16Verifier(depositV),
                    withdrawVerifier: IGroth16Verifier(withdrawV),
                    lockVerifier: IGroth16Verifier(anonV),
                    burnVerifier: ZERO,
                    batchVerifier: IGroth16Verifier(anonBatchV),
                    batchWithdrawVerifier: IGroth16Verifier(withdrawBatchV),
                    batchLockVerifier: IGroth16Verifier(anonBatchV),
                    batchBurnVerifier: ZERO
                })
            })
        );

        // Zeto_AnonNullifier: locked variants are not exercised; reuse the
        // transfer verifier in the lock slot the way the .full script does.
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

        console.log("Groth16Verifier_Anon:", anonV);
        console.log("Groth16Verifier_AnonNullifierTransfer:", anonNullV);
        console.log("Zeto_Anon (impl):", implAnon);
        console.log("Zeto_AnonNullifier (impl):", implAnonNullifier);
        console.log("ZetoTokenFactory:", address(factory));
    }
}
