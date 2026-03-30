// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Create2Deployer, FortuneMarketFactory, FortuneMarketHook} from "../src/FortuneMarket.sol";
import {MarketConfig} from "../src/MarketConfig.sol";

contract DeployScript is Script {
    function run() external returns (FortuneMarketHook hook, FortuneMarketFactory factory) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        address deployer = vm.addr(privateKey);
        MarketConfig.NetworkConstants memory networkConstants = MarketConfig.getNetworkConstants(block.chainid);

        require(networkConstants.poolManager.code.length != 0, "PoolManager missing");

        vm.startBroadcast(privateKey);

        Create2Deployer create2Deployer = new Create2Deployer();
        bytes memory constructorArgs = abi.encode(IPoolManager(networkConstants.poolManager), deployer);
        bytes memory initCode = bytes.concat(type(FortuneMarketHook).creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 salt = _mineSalt(address(create2Deployer), initCodeHash);
        address hookAddress = _computeCreate2Address(address(create2Deployer), salt, initCodeHash);

        create2Deployer.deploy(salt, initCode);
        hook = FortuneMarketHook(hookAddress);

        factory = new FortuneMarketFactory(
            IPoolManager(networkConstants.poolManager), IERC20(networkConstants.usdc), hook, treasury
        );

        hook.setFactory(address(factory));

        vm.stopBroadcast();

        console2.log("Deployer:", deployer);
        console2.log("Create2Deployer:", address(create2Deployer));
        console2.log("Hook:", address(hook));
        console2.log("Factory:", address(factory));
        console2.log("Treasury:", treasury);
    }

    function _mineSalt(address deployer, bytes32 initCodeHash) internal pure returns (bytes32) {
        for (uint256 i = 0; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address candidate = _computeCreate2Address(deployer, salt, initCodeHash);
            if ((uint256(uint160(candidate)) & MarketConfig.HOOK_FLAGS_MASK) == MarketConfig.FORTUNE_MARKET_HOOK_FLAGS)
            {
                return salt;
            }
        }

        revert("Hook salt not found");
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }
}
