// SPDX-License-Identifier: Apache-2.0
// Local shim for the @iden3/contracts/contracts/interfaces/IHasher.sol type.
// The pinned iden3-contracts version doesn't ship this file; newer Zeto
// imports it. The actual hashing is still done by SmtLib via PoseidonUnit3L,
// so the IHasher injection point is functionally a no-op for our build.
pragma solidity ^0.8.27;

interface IHasher {
    function hash(uint256[] memory inputs) external view returns (uint256);
}
