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

    function testRevertsIfTokenLengthDoesNotMatchPriceFeedLength() external {
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](2);
        tokenAddresses[0] = weth;
        priceFeedAddresses[0] = ethUSDPriceFeed;
        priceFeedAddresses[1] = ethUSDPriceFeed; // Extra price feed to cause mismatch

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    function testGetTokenAmountFromUsd() external {
        uint256 usdAmount = 30000e18;
        uint256 expectedTokenAmount = 15e18; // at $2000/ETH, $30000 = 15 ETH
        uint256 actualTokenAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualTokenAmount, expectedTokenAmount);
    }
    function testRevertsWithUnapprovedCollateral () public {
        address unapprovedToken = makeAddr("unapprovedToken");
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(unapprovedToken, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }
    function testCanDepositCollateralAndGetAccountInformation() external depositedCollateral {
        (uint256 dscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountBalance(user);
        assertEq(dscMinted, 0);
        assertEq(collateralValueInUsd, 20000e18); // 10 ETH * $2000/ETH = $20,000
    }
}