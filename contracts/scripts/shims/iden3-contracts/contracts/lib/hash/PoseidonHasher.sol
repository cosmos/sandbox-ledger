// SPDX-License-Identifier: Apache-2.0
// Local shim. Pinned iden3-contracts (5286d50) doesn't ship this file; newer
// Zeto imports it. The constructor + hash() are functionally never invoked
// because our SmtLib.setHasher is a no-op (the SMT keeps using its built-in
// PoseidonUnit{2,3}L paths). This shim exists only to satisfy compilation.
pragma solidity ^0.8.27;

import {IHasher} from "../../interfaces/IHasher.sol";
import {PoseidonUnit3L} from "../Poseidon.sol";

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
