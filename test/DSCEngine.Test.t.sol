// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from  "forge-std/Test.sol";

import {DeployDsc} from "../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
contract DSCEngineTest is Test {
    DeployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUSDPriceFeed;
    address weth;

    address public user=makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL=10 ether;
    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine,config) = deployer.run();
        (ethUSDPriceFeed,,weth,,)=config.activeNetworkConfig();
         ERC20Mock(weth).mint(user, AMOUNT_COLLATERAL);
    }

    function testGetUsdPriceFeed() external {
        uint256 ethAmount = 15e18;
        uint256 expectedPrice = 30000e18;
        uint256 actualPrice = dscEngine.getPrice(weth,ethAmount);
        assertEq(actualPrice, expectedPrice);
    }
    function testRevertsIfCollateralZero() external {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(address(weth), 0);
        vm.stopPrank();
    }
}