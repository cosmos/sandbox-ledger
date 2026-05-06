// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {Zeto_Anon} from "zeto/zeto_anon.sol";
import {IZetoInitializable} from "zeto/lib/interfaces/IZetoInitializable.sol";
import {IGroth16Verifier} from "zeto/lib/interfaces/IZetoVerifier.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Groth16Verifier_Anon} from "../src/verifiers/Verifier_Anon.sol";

// Zeto_Anon impl-level tests. Avoids the SmtLib/Poseidon deploy dance the
// AnonNullifier variant needs, which keeps these to plain `forge test`.
//
// The impl disables initializers in its constructor (UUPS pattern), so we
// must clone it before init — same pattern the production ZetoTokenFactory
// uses to mint per-asset deployments.
contract ZetoAnonTest is Test {
    Zeto_Anon internal zeto;
    address internal owner = address(0xA11CE);

    function setUp() public {
        // One real verifier for the transfer slot (and lock, since that
        // path also uses the anon circuit). Other slots are stub addresses;
        // mint/transfer don't touch them on the happy path.
        IGroth16Verifier anonV = IGroth16Verifier(address(new Groth16Verifier_Anon()));
        IGroth16Verifier zero = IGroth16Verifier(address(0xBEEF));

        IZetoInitializable.VerifiersInfo memory verifiers = IZetoInitializable.VerifiersInfo({
            verifier: anonV,
            depositVerifier: zero,
            withdrawVerifier: zero,
            lockVerifier: anonV,
            burnVerifier: zero,
            batchVerifier: zero,
            batchWithdrawVerifier: zero,
            batchLockVerifier: zero,
            batchBurnVerifier: zero
        });

        Zeto_Anon impl = new Zeto_Anon();
        zeto = Zeto_Anon(Clones.clone(address(impl)));
        zeto.initialize("Sandbox CBDC", "USDCBDC", owner, verifiers);
    }

    function test_NameAndSymbol() public view {
        assertEq(zeto.name(), "Sandbox CBDC", "name");
        assertEq(zeto.symbol(), "USDCBDC", "symbol");
    }

    function test_OwnerSet() public view {
        assertEq(zeto.owner(), owner, "owner");
    }

    function test_DoubleInitializeReverts() public {
        IGroth16Verifier zero = IGroth16Verifier(address(0xBEEF));
        IZetoInitializable.VerifiersInfo memory verifiers;
        verifiers.verifier = zero;

        // OZ Initializable throws InvalidInitialization on re-init.
        vm.expectRevert();
        zeto.initialize("X", "Y", owner, verifiers);
    }

    function test_MintByNonOwnerReverts() public {
        uint256[] memory commitments = new uint256[](1);
        commitments[0] = 0x1234;

        // Default msg.sender (the test contract) is NOT the owner.
        vm.expectRevert();
        zeto.mint(commitments, "");
    }

    function test_MintByOwnerSucceedsAndStoresCommitments() public {
        uint256[] memory commitments = new uint256[](2);
        commitments[0] = 0xDEADBEEF;
        commitments[1] = 0xCAFE;

        vm.prank(owner);
        zeto.mint(commitments, hex"01746573742d6d656d6f"); // memo: 0x01 "test-memo"

        // Mint stores the commitments; querying the storage layout directly
        // is brittle, so we re-mint the same commitment under owner and
        // expect a revert from the per-commitment uniqueness check that
        // every Zeto fungible variant enforces.
        uint256[] memory dup = new uint256[](1);
        dup[0] = 0xDEADBEEF;
        vm.prank(owner);
        vm.expectRevert();
        zeto.mint(dup, "");
    }
}
