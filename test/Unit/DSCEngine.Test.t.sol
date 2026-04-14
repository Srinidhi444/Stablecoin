// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from  "forge-std/Test.sol";

import {DeployDsc} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";
contract DSCEngineTest is Test {
    DeployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUSDPriceFeed;
    address weth;

    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    // 10 ETH * $2000 = $20,000 collateral → max safe mint = $10,000 (50% threshold)
    uint256 public constant AMOUNT_DSC_TO_MINT = 5000e18;

    // Liquidation scenario: price crashes from $2000 → $800
    //   user health factor: (8000 * 50%) * 1e18 / 5000 = 0.8e18  (liquidatable)
    // Cover 4000 DSC → 5 ETH token amount + 10% bonus = 5.5 ETH to liquidator
    //   user health factor after: (3600 * 50%) * 1e18 / 1000 = 1.8e18 (healthy)
    int256  public constant CRASHED_ETH_PRICE   = 800e8;
    uint256 public constant DEBT_TO_COVER        = 4000e18;
    uint256 public constant LIQUIDATOR_COLLATERAL = 20 ether;
    // 5 ETH (debt coverage at $800) + 10% bonus = 5.5 ETH
    uint256 public constant EXPECTED_LIQUIDATION_PAYOUT = 5.5 ether;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine, config) = deployer.run();
        (ethUSDPriceFeed,,weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(user, AMOUNT_COLLATERAL);
        ERC20Mock(weth).mint(liquidator, LIQUIDATOR_COLLATERAL);
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

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInformation() external depositedCollateral {
        (uint256 dscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountBalance(user);
        assertEq(dscMinted, 0);
        assertEq(collateralValueInUsd, 20000e18); // 10 ETH * $2000/ETH = $20,000
    }

    // ========================= MINT TESTS =========================

    function testMintDscRevertsIfHealthFactorBreaks() external depositedCollateral {
        // collateral = $20,000 → max safe = $10,000; minting $10,001 breaks health factor
        uint256 overMintAmount = 10001e18;
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine_BreaksHealthFactor.selector);
        dscEngine.mintDsc(overMintAmount);
        vm.stopPrank();
    }

    function testCanMintDsc() external depositedCollateral {
        vm.startPrank(user);
        dscEngine.mintDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        (uint256 dscMinted,) = dscEngine.getAccountBalance(user);
        assertEq(dscMinted, AMOUNT_DSC_TO_MINT);
    }

    function testCanDepositCollateralAndMintDsc() external depositedCollateralAndMintedDsc {
        (uint256 dscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountBalance(user);
        assertEq(dscMinted, AMOUNT_DSC_TO_MINT);
        assertEq(collateralValueInUsd, 20000e18);
    }

    // ========================= BURN TESTS =========================

    function testCanBurnDsc() external depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.burnDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        (uint256 dscMinted,) = dscEngine.getAccountBalance(user);
        assertEq(dscMinted, 0);
    }

    function testBurnDscRevertsIfZero() external depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    // ========================= REDEEM COLLATERAL FOR DSC TESTS =========================

    function testCanRedeemCollateralForDsc() external depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        dscEngine.redeemCollateralForDsc(address(weth), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        (uint256 dscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountBalance(user);
        assertEq(dscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    function testRedeemCollateralForDscRevertsIfZeroCollateral() external depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), AMOUNT_DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(address(weth), 0, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    // ========================= STALE PRICE TESTS =========================

    function testGetPriceRevertsOnStalePrice() external {
        // advance time past the 3-hour staleness window
        vm.warp(block.timestamp + 4 hours);
        vm.expectRevert(DSCEngine.DSCEngine__StalePrice.selector);
        dscEngine.getPrice(weth, 1e18);
    }

    function testGetTokenAmountFromUsdRevertsOnStalePrice() external {
        vm.warp(block.timestamp + 4 hours);
        vm.expectRevert(DSCEngine.DSCEngine__StalePrice.selector);
        dscEngine.getTokenAmountFromUsd(weth, 1e18);
    }

    // ========================= LIQUIDATION TESTS =========================

    // Sets up: user deposits + mints at $2000, then price crashes to $800
    // making the user's health factor 0.8e18 (below the 1e18 threshold).
    modifier userIsLiquidatable() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(CRASHED_ETH_PRICE);
        _;
    }

    function testLiquidateRevertsIfHealthFactorOk() external depositedCollateralAndMintedDsc {
        // user health factor = 2e18 — well above threshold, should not be liquidatable
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(address(weth), user, DEBT_TO_COVER);
        vm.stopPrank();
    }

    function testLiquidateRevertsIfDebtToCoversIsZero() external userIsLiquidatable {
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.liquidate(address(weth), user, 0);
        vm.stopPrank();
    }

    function testCanLiquidate() external userIsLiquidatable {
        // liquidator deposits collateral and mints enough DSC to cover debt
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), LIQUIDATOR_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(address(weth), LIQUIDATOR_COLLATERAL, DEBT_TO_COVER);
        dsc.approve(address(dscEngine), DEBT_TO_COVER);
        dscEngine.liquidate(address(weth), user, DEBT_TO_COVER);
        vm.stopPrank();

        (uint256 userDscMinted,) = dscEngine.getAccountBalance(user);
        assertEq(userDscMinted, AMOUNT_DSC_TO_MINT - DEBT_TO_COVER);
    }

    function testLiquidatedUserHealthFactorImproves() external userIsLiquidatable {
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), LIQUIDATOR_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(address(weth), LIQUIDATOR_COLLATERAL, DEBT_TO_COVER);
        dsc.approve(address(dscEngine), DEBT_TO_COVER);
        dscEngine.liquidate(address(weth), user, DEBT_TO_COVER);
        vm.stopPrank();

        // after liquidation: 4.5 ETH * $800 = $3600 collateral, 1000 DSC
        // health factor = (3600 * 50%) * 1e18 / 1000 = 1.8e18
        (uint256 userDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountBalance(user);
        uint256 expectedHealthFactor = (collateralValueInUsd / 2) * 1e18 / userDscMinted;
        assertGt(expectedHealthFactor, 1e18);
    }

    function testLiquidationPaysOutCorrectBonus() external userIsLiquidatable {
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), LIQUIDATOR_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(address(weth), LIQUIDATOR_COLLATERAL, DEBT_TO_COVER);
        dsc.approve(address(dscEngine), DEBT_TO_COVER);

        // liquidator deposited all weth — balance is 0 before liquidation
        uint256 wethBefore = ERC20Mock(weth).balanceOf(liquidator);
        dscEngine.liquidate(address(weth), user, DEBT_TO_COVER);
        uint256 wethAfter = ERC20Mock(weth).balanceOf(liquidator);
        vm.stopPrank();

        // 4000 DSC / $800 per ETH = 5 ETH + 10% bonus = 5.5 ETH
        assertEq(wethAfter - wethBefore, EXPECTED_LIQUIDATION_PAYOUT);
    }
}