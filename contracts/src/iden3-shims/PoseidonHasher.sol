// SPDX-License-Identifier: Apache-2.0
// Local shim for @iden3/contracts/contracts/lib/hash/PoseidonHasher.sol.
// Newer Zeto code constructs PoseidonHasher and registers it with SmtLib;
// our SmtLib's setHasher is a no-op shim, so this contract's hash() is
// never invoked. We still implement it correctly using PoseidonUnit3L for
// any future dynamic dispatch.
pragma solidity ^0.8.27;

import {IHasher} from "../iden3-shims/IHasher.sol";
import {PoseidonUnit3L} from "@iden3/contracts/contracts/lib/Poseidon.sol";

contract PoseidonHasher is IHasher {
    function hash(uint256[] memory inputs) external view returns (uint256) {
        require(inputs.length == 3, "PoseidonHasher: only 3-input variant supported");
        uint256[3] memory fixed_inputs;
        fixed_inputs[0] = inputs[0];
        fixed_inputs[1] = inputs[1];
        fixed_inputs[2] = inputs[2];
        return PoseidonUnit3L.poseidon(fixed_inputs);
    }
}
