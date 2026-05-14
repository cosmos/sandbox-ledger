// SPDX-License-Identifier: Apache-2.0
// Deploys the STACK-2757 WrappedZeto ERC20 bridge.
//
// The wrapper's constructor calls ZetoTokenFactory.deployZetoFungibleToken
// with `address(this)` as initial owner, so the Zeto is born already owned
// by the wrapper. No staging or acceptOwnership step.
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

import {WrappedZeto} from "../src/WrappedZeto.sol";

contract DeployWrappedZeto is Script {
    string constant DEFAULT_NAME = "Wrapped Zeto Sandbox";
    string constant DEFAULT_SYMBOL = "wZETO";
    /// @dev 4 decimals matches ZetoCommon.decimals — 1 wrapper unit == 1 ledger unit.
    uint8 constant DEFAULT_DECIMALS = 4;

    /// @dev Path is relative to `contracts/` (forge's cwd via `forge script`).
    string constant MANIFEST_PATH = "deployments/sandbox-dev-1.json";

    /// @dev Must match the name DeployZetoAnon.s.sol registered with the factory.
    string constant IMPL_NAME = "Zeto_AnonNullifier_Burnable";

    function run() external {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        address factoryAddr = _readContractAddress(manifest, "ZetoTokenFactory");
        require(factoryAddr != address(0), "DeployWrappedZeto: factory not in manifest");

        string memory name = _envOr("WRAPPED_ZETO_NAME", DEFAULT_NAME);
        string memory symbol = _envOr("WRAPPED_ZETO_SYMBOL", DEFAULT_SYMBOL);
        uint8 decimals_ = _envU8Or("WRAPPED_ZETO_DECIMALS", DEFAULT_DECIMALS);

        vm.startBroadcast();

        // Constructor spawns the Zeto via the factory and takes ownership.
        WrappedZeto wrapper = new WrappedZeto(factoryAddr, IMPL_NAME, name, symbol, decimals_);
        address zetoInstance = address(wrapper.zeto());

        vm.stopBroadcast();

        _appendWrappedZetoToManifest(address(wrapper), zetoInstance, name, symbol, decimals_);

        console.log("Zeto instance:", zetoInstance);
        console.log("WrappedZeto:", address(wrapper));
        console.log("Manifest updated:", MANIFEST_PATH);
    }

    function _readContractAddress(
        string memory manifest,
        string memory target
    ) internal pure returns (address) {
        string memory query = string.concat(
            ".contracts[?(@.name==\"",
            target,
            "\")].address"
        );
        bytes memory raw = vm.parseJson(manifest, query);
        if (raw.length == 0) return address(0);
        return abi.decode(raw, (address));
    }

    function _appendWrappedZetoToManifest(
        address wrapperAddr,
        address zetoInstance,
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) internal {
        string memory obj = "wrapped_zeto_obj";
        vm.serializeAddress(obj, "wrapper", wrapperAddr);
        vm.serializeAddress(obj, "zeto", zetoInstance);
        vm.serializeString(obj, "name", name);
        vm.serializeString(obj, "symbol", symbol);
        string memory serialized = vm.serializeUint(obj, "decimals", uint256(decimals_));
        vm.writeJson(serialized, MANIFEST_PATH, ".wrapped_zeto");
    }

    function _envOr(string memory key, string memory dflt) internal view returns (string memory) {
        try vm.envString(key) returns (string memory v) {
            if (bytes(v).length == 0) return dflt;
            return v;
        } catch {
            return dflt;
        }
    }

    function _envU8Or(string memory key, uint8 dflt) internal view returns (uint8) {
        try vm.envUint(key) returns (uint256 v) {
            require(v <= type(uint8).max, "DeployWrappedZeto: decimals overflow");
            return uint8(v);
        } catch {
            return dflt;
        }
    }
}
