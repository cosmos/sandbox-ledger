// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {Zeto_AnonEncNullifierNonRepudiation} from "zeto/zeto_anon_enc_nullifier_non_repudiation.sol";

// Smoke test for the NonRepudiation implementation contract — the one
// whose ~28 KB runtime size required forking cosmos/go-ethereum to bump
// MaxCodeSize from 24576 to 49152. Constructing it exercises the
// foundry.toml `code_size_limit` override; without that override the
// test EVM aborts with CreateContractSizeLimit before the assertion.
// Crypto correctness (proofs, encryption envelopes) is exercised
// end-to-end by sandbox-backend's Go suite against a live chain.
contract ZetoAnonEncNullifierNonRepudiationDeployTest is Test {
    function test_ImplementationDeploys() public {
        Zeto_AnonEncNullifierNonRepudiation impl = new Zeto_AnonEncNullifierNonRepudiation();
        assertGt(address(impl).code.length, 24576, "impl runtime under EIP-170 - refresh test expectations");
    }
}
