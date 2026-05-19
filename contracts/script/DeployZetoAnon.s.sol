// SPDX-License-Identifier: Apache-2.0
// PoC deploy script. Registers Zeto_AnonNullifierBurnable (nullifier +
// on-chain SMT + burn primitive) with the factory.
//
// NOTE on the filename: this script is still called DeployZetoAnon.s.sol
// even though it deploys the burnable nullifier variant — the forge
// broadcast log lands at broadcast/DeployZetoAnon.s.sol/<chain>/run-latest.json
// and downstream consumers (deploy-zeto.sh in this repo, the demo scripts
// in sandbox/) read that exact path. Renaming would break them for
// cosmetic reasons; leave the filename alone.
//
// The transfer verifier is generated from our locally-built zkey (see
// sandbox-backend/scripts/build-circuits.sh). The burn verifier is taken
// from upstream Zeto since we don't yet have a locally-built burn zkey;
// the burnable variant's initializer requires a non-zero verifier
// address in that slot, and STACK-2757 will swap to a locally-built one
// once the wrapper exercises burn proofs.
//
// Library linking: Zeto_AnonNullifier(_Burnable) pulls in iden3 SmtLib +
// PoseidonUnit2L/3L. `forge script` is invoked with --libraries pointing at
// addresses already deployed by deploy-zeto.sh (cast send for raw Poseidon
// hex; forge create for SmtLib).
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
import {Groth16Verifier_BurnNullifier} from "zeto/verifiers/verifier_burn_nullifier.sol";

import {Zeto_AnonNullifierBurnable} from "zeto/zeto_anon_nullifier_burnable.sol";
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
        // Burn verifier for the nullifier variant. Vendored upstream — we
        // don't run burn proofs locally yet, so this is only the address
        // the initializer requires; STACK-2757 will swap to a locally-
        // built verifier if the burn circuit ends up regenerated.
        address burnNullV = address(new Groth16Verifier_BurnNullifier());

        // ----- Token implementation (cloneable, not initialized) -----
        address implAnonNullifierBurnable = address(new Zeto_AnonNullifierBurnable());

        // ----- Factory -----
        ZetoTokenFactory factory = new ZetoTokenFactory();

        // VerifiersInfo packs 9 slots: verifier, deposit, withdraw, lock,
        // burn, batchVerifier, batchWithdraw, batchLock, batchBurn.
        //
        // Zeto_AnonNullifierBurnable: locked variants are not exercised by
        // the PoC, so lock/batchLock stay ZERO. Burn requires a non-zero
        // burnVerifier slot (non-zero address required by the initializer).
        // Batch burn isn't deployed (no batch zkey yet) so
        // batchBurnVerifier stays ZERO.
        factory.registerImplementation(
            "Zeto_AnonNullifierBurnable",
            ZetoTokenFactory.ImplementationInfo({
                implementation: implAnonNullifierBurnable,
                verifiers: IZetoInitializable.VerifiersInfo({
                    verifier: IGroth16Verifier(anonNullV),
                    depositVerifier: IGroth16Verifier(depositV),
                    withdrawVerifier: IGroth16Verifier(withdrawNullV),
                    lockVerifier: ZERO,
                    burnVerifier: IGroth16Verifier(burnNullV),
                    batchVerifier: IGroth16Verifier(anonNullBatchV),
                    batchWithdrawVerifier: IGroth16Verifier(withdrawNullBatchV),
                    batchLockVerifier: ZERO,
                    batchBurnVerifier: ZERO
                })
            })
        );

        vm.stopBroadcast();

        console.log("Groth16Verifier_AnonNullifierTransfer:", anonNullV);
        console.log("Groth16Verifier_BurnNullifier:", burnNullV);
        console.log("Zeto_AnonNullifierBurnable (impl):", implAnonNullifierBurnable);
        console.log("ZetoTokenFactory:", address(factory));
    }
}
