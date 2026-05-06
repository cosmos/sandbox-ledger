// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {Zeto_AnonNullifier} from "zeto/zeto_anon_nullifier.sol";
import {IZetoInitializable} from "zeto/lib/interfaces/IZetoInitializable.sol";
import {IGroth16Verifier} from "zeto/lib/interfaces/IZetoVerifier.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Groth16Verifier_Anon} from "../src/verifiers/Verifier_Anon.sol";
import {Groth16Verifier_AnonNullifierTransfer} from "../src/verifiers/Verifier_AnonNullifierTransfer.sol";

// Tests for the AnonNullifier variant — the one we actually use.
//
// The variant pulls in iden3 PoseidonUnit2L/3L (raw bytecode, off-chain-
// generated) plus SmtLib (a Solidity library with `external` functions
// that internally call Poseidon). For production deploys, deploy-zeto.sh
// deploys all three before linking via `forge script --libraries`.
//
// For these forge tests, foundry.toml fixes the library addresses at
// compile time (Poseidon at 0x5002/0x5003, SmtLib at 0x5a47). setUp then
// etches the actual bytecode at those addresses so runtime calls work.
//
// Why bother: this gates the whole cascade — Poseidon hex bytecode,
// SmtLib link, Zeto_AnonNullifier clone+init+mint, on-chain SMT root
// updates — without needing a running chain or backend.
contract ZetoAnonNullifierTest is Test {
    address constant POSEIDON2 = 0x0000000000000000000000000000000000005002;
    address constant POSEIDON3 = 0x0000000000000000000000000000000000005003;
    address constant SMTLIB = 0x0000000000000000000000000000000000005a47;

    Zeto_AnonNullifier internal zeto;
    address internal owner = address(0xA11CE);

    function setUp() public {
        // 1. Deploy Poseidon libraries from pre-built creation bytecode and
        //    relocate the runtime code to the foundry.toml-fixed addresses.
        bytes memory p2Creation = vm.parseBytes(vm.readFile("poseidon/PoseidonUnit2L.hex"));
        bytes memory p3Creation = vm.parseBytes(vm.readFile("poseidon/PoseidonUnit3L.hex"));
        vm.etch(POSEIDON2, _runtimeCodeFromCreation(p2Creation));
        vm.etch(POSEIDON3, _runtimeCodeFromCreation(p3Creation));

        // 2. Etch SmtLib at its fixed address. Forge's compile already
        //    linked SmtLib's bytecode to Poseidon@0x5002/0x5003 because
        //    of the libraries entry in foundry.toml.
        bytes memory smtCode = vm.getDeployedCode(
            "lib/iden3-contracts/contracts/lib/SmtLib.sol:SmtLib"
        );
        vm.etch(SMTLIB, smtCode);

        // 3. Set up the verifier slots required by the variant.
        IGroth16Verifier transferV = IGroth16Verifier(address(new Groth16Verifier_AnonNullifierTransfer()));
        IGroth16Verifier anonV = IGroth16Verifier(address(new Groth16Verifier_Anon()));
        IGroth16Verifier zero = IGroth16Verifier(address(0xBEEF));

        IZetoInitializable.VerifiersInfo memory verifiers = IZetoInitializable.VerifiersInfo({
            verifier: transferV,
            depositVerifier: zero,
            withdrawVerifier: zero,
            lockVerifier: anonV,
            burnVerifier: zero,
            batchVerifier: zero,
            batchWithdrawVerifier: zero,
            batchLockVerifier: zero,
            batchBurnVerifier: zero
        });

        // 4. Clone the impl and initialize. Direct construction is blocked
        //    by `_disableInitializers()` in the impl constructor (UUPS).
        Zeto_AnonNullifier impl = new Zeto_AnonNullifier();
        zeto = Zeto_AnonNullifier(Clones.clone(address(impl)));
        zeto.initialize("Sandbox CBDC", "USDCBDC", owner, verifiers);
    }

    function test_NameSymbolOwner() public view {
        assertEq(zeto.name(), "Sandbox CBDC");
        assertEq(zeto.symbol(), "USDCBDC");
        assertEq(zeto.owner(), owner);
    }

    function test_MintByNonOwnerReverts() public {
        uint256[] memory commitments = new uint256[](1);
        commitments[0] = 0x1234;
        vm.expectRevert();
        zeto.mint(commitments, "");
    }

    function test_MintByOwnerSucceeds() public {
        // Successful mint exercises the full SMT insert path: the library
        // calls into PoseidonUnit2L+3L (runtime bytecode etched in setUp)
        // and updates the on-chain root. If linking is wrong, the call
        // reverts inside SmtLib.
        uint256[] memory commitments = new uint256[](1);
        commitments[0] = 0xDEADBEEF;
        vm.prank(owner);
        zeto.mint(commitments, hex"01746573742d6d656d6f");
    }

    function test_MintRejectsDuplicateCommitment() public {
        uint256[] memory c = new uint256[](1);
        c[0] = 0xCAFEBABE;
        vm.prank(owner);
        zeto.mint(c, "");

        // Inserting the same commitment twice must revert (per-token
        // commitment uniqueness — the same property the backend's notedb
        // mirrors via its (token, commitment) UNIQUE).
        vm.prank(owner);
        vm.expectRevert();
        zeto.mint(c, "");
    }

    function test_TransferRevertsWithBadProof() public {
        // Transfer with all-zero proof must not pass verifier; expect a
        // revert. This gates the verifier wiring at the Zeto_AnonNullifier
        // boundary — without a valid Groth16 proof generation pipeline
        // here (lives in the backend), this is the strongest assertion
        // we can make on the transfer path.
        uint256[] memory inputs = new uint256[](2); // 2 nullifiers
        uint256[] memory outputs = new uint256[](2); // 2 new commitments
        inputs[0] = 0xAA;
        inputs[1] = 0xBB;
        outputs[0] = 0xCC;
        outputs[1] = 0xDD;

        bytes memory badProof = hex"00";
        vm.expectRevert();
        zeto.transfer(inputs, outputs, badProof, "");
    }

    /// @dev Run a contract creation from the given creation bytecode and
    /// return the deployed runtime bytecode. Used so we can vm.etch the
    /// runtime code at a foundry.toml-fixed address.
    function _runtimeCodeFromCreation(bytes memory creationCode) internal returns (bytes memory) {
        address temp;
        assembly {
            temp := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(temp != address(0), "raw deploy failed");
        return temp.code;
    }
}
