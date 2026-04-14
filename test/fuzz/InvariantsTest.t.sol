// SPDX-License-Identifier: MIT

// what are our invariants
// 1.total supply of dsc should always be less than the total value of collateral in the system
// 2.getter view functions should not revert

pragma solidity ^0.8.18;

import {Test} from  "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";
contract InvariantsTest is StdInvariant, Test {
    DeployDsc deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;
    address wethPriceFeed;
    address wbtcPriceFeed;
    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine, config) = deployer.run();
        (wethPriceFeed, wbtcPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc, weth, wbtc, wethPriceFeed, wbtcPriceFeed);
        targetContract(address(handler));
    }
    function invariantTotalSupplyShouldNotExceedTotalCollateralValue() external view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalwethdeposited=IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalwbtcdeposited=IERC20(wbtc).balanceOf(address(dscEngine));
        uint256 totalCollateralValueInUsd = dscEngine.getPrice(weth, totalwethdeposited) + dscEngine.getPrice(wbtc, totalwbtcdeposited);
        assert(totalSupply <= totalCollateralValueInUsd);
    }
   
}
