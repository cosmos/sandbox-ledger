// SPDX-License-Identifier: Apache-2.0
// Registers Zeto_AnonEncNullifierNonRepudiation with the factory.
// Filename kept as DeployZetoAnon.s.sol — broadcast log path is consumed
// by deploy-zeto.sh and the sandbox demo scripts.
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

// Non-repudiation transfer verifiers (vendored upstream).
import {Groth16Verifier_AnonEncNullifierNonRepudiation} from "zeto/verifiers/verifier_anon_enc_nullifier_non_repudiation.sol";
import {Groth16Verifier_AnonEncNullifierNonRepudiationBatch} from "zeto/verifiers/verifier_anon_enc_nullifier_non_repudiation_batch.sol";

// Vendored verifiers for unused-but-required factory slots.
import {Groth16Verifier_Deposit} from "zeto/verifiers/verifier_deposit.sol";
import {Groth16Verifier_WithdrawNullifier} from "zeto/verifiers/verifier_withdraw_nullifier.sol";
import {Groth16Verifier_WithdrawNullifierBatch} from "zeto/verifiers/verifier_withdraw_nullifier_batch.sol";

import {Zeto_AnonEncNullifierNonRepudiation} from "zeto/zeto_anon_enc_nullifier_non_repudiation.sol";
import {ZetoTokenFactory} from "zeto/factory.sol";
import {IZetoInitializable} from "zeto/lib/interfaces/IZetoInitializable.sol";
import {IGroth16Verifier} from "zeto/lib/interfaces/IZetoVerifier.sol";

contract DeployZetoAnon is Script {
    IGroth16Verifier constant ZERO = IGroth16Verifier(address(0));

    function run() external {
        vm.startBroadcast();

        // ----- Verifiers -----
        address transferV = address(new Groth16Verifier_AnonEncNullifierNonRepudiation());
        address transferBatchV = address(new Groth16Verifier_AnonEncNullifierNonRepudiationBatch());
        address depositV = address(new Groth16Verifier_Deposit());
        address withdrawNullV = address(new Groth16Verifier_WithdrawNullifier());
        address withdrawNullBatchV = address(new Groth16Verifier_WithdrawNullifierBatch());

        // ----- Token implementation (cloneable, not initialized) -----
        address implNonRepudiation = address(new Zeto_AnonEncNullifierNonRepudiation());

        // ----- Factory -----
        ZetoTokenFactory factory = new ZetoTokenFactory();

        // Lock + burn slots are ZERO — neither path is exercised by the PoC.
        factory.registerImplementation(
            "Zeto_AnonEncNullifierNonRepudiation",
            ZetoTokenFactory.ImplementationInfo({
                implementation: implNonRepudiation,
                verifiers: IZetoInitializable.VerifiersInfo({
                    verifier: IGroth16Verifier(transferV),
                    depositVerifier: IGroth16Verifier(depositV),
                    withdrawVerifier: IGroth16Verifier(withdrawNullV),
                    lockVerifier: ZERO,
                    burnVerifier: ZERO,
                    batchVerifier: IGroth16Verifier(transferBatchV),
                    batchWithdrawVerifier: IGroth16Verifier(withdrawNullBatchV),
                    batchLockVerifier: ZERO,
                    batchBurnVerifier: ZERO
                })
            })
        );

        vm.stopBroadcast();

        console.log("Groth16Verifier_AnonEncNullifierNonRepudiation:", transferV);
        console.log("Groth16Verifier_AnonEncNullifierNonRepudiationBatch:", transferBatchV);
        console.log("Zeto_AnonEncNullifierNonRepudiation (impl):", implNonRepudiation);
        console.log("ZetoTokenFactory:", address(factory));
    }
}
