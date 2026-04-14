// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator wethPriceFeed;
    MockV3Aggregator wbtcPriceFeed;

    // Cap deposit size to avoid overflow in price calculations
    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    // Track how much each actor has deposited per token so redeemCollateral
    // is always bounded to a valid amount and never reverts on underflow.
    mapping(address => mapping(address => uint256)) public deposited;

    constructor(
        DSCEngine _dscEngine,
        DecentralizedStableCoin _dsc,
        address _weth,
        address _wbtc,
        address _wethPriceFeed,
        address _wbtcPriceFeed
    ) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        weth = ERC20Mock(_weth);
        wbtc = ERC20Mock(_wbtc);
        wethPriceFeed = MockV3Aggregator(_wethPriceFeed);
        wbtcPriceFeed = MockV3Aggregator(_wbtcPriceFeed);
    }

    // ========================= HANDLER FUNCTIONS =========================

    function depositCollateral(uint256 collateralSeed, uint256 amount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amount);
        collateral.approve(address(dscEngine), amount);
        dscEngine.depositCollateral(address(collateral), amount);
        vm.stopPrank();

        deposited[msg.sender][address(collateral)] += amount;
    }

    // Mint DSC bounded to the actor's maximum safe mintable amount so the
    // health factor invariant is never broken by the fuzzer.
    // Max safe mint = collateralValueInUsd * LIQUIDATION_THRESHOLD(50%) - alreadyMinted
    function mintDsc(uint256 amount) public {
        (uint256 currentDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountBalance(msg.sender);
        int256 maxMintable = (int256(collateralValueInUsd) / 2) - int256(currentDscMinted);
        if (maxMintable <= 0) return;

        amount = bound(amount, 1, uint256(maxMintable));
        vm.startPrank(msg.sender);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
    }

    // Redeem is bounded by both the tracked deposit and the health factor so
    // it never reverts regardless of how much DSC the actor has minted.
    // Max redeemable (in tokens) = (totalCollateral - 2*dscMinted) / pricePerToken
    function redeemCollateral(uint256 collateralSeed, uint256 amount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxRedeemable = deposited[msg.sender][address(collateral)];
        if (maxRedeemable == 0) return;

        (uint256 dscMinted, uint256 totalCollateralInUsd) = dscEngine.getAccountBalance(msg.sender);
        if (dscMinted > 0) {
            uint256 minCollateralUsd = dscMinted * 2;
            if (totalCollateralInUsd <= minCollateralUsd) return;
            uint256 maxRedeemableUsd = totalCollateralInUsd - minCollateralUsd;
            // pricePerUnit = USD value of 1e18 tokens (i.e. 1 whole token)
            uint256 pricePerUnit = dscEngine.getPrice(address(collateral), 1e18);
            if (pricePerUnit == 0) return;
            uint256 maxByHealthFactor = (maxRedeemableUsd * 1e18) / pricePerUnit;
            if (maxByHealthFactor < maxRedeemable) {
                maxRedeemable = maxByHealthFactor;
            }
        }

        amount = bound(amount, 0, maxRedeemable);
        if (amount == 0) return;

        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amount);
        vm.stopPrank();

        deposited[msg.sender][address(collateral)] -= amount;
    }

    // Re-posting the current price resets updatedAt on the mock, preventing the
    // 3-hour staleness check from firing during long fuzz runs without changing
    // the price (which would cause collateral value to diverge from DSC supply).
    function refreshPriceFeeds() public {
        wethPriceFeed.updateAnswer(wethPriceFeed.latestAnswer());
        wbtcPriceFeed.updateAnswer(wbtcPriceFeed.latestAnswer());
    }

    // ========================= HELPERS =========================

    function _getCollateralFromSeed(uint256 seed) private view returns (ERC20Mock) {
        if (seed % 2 == 0) return weth;
        return wbtc;
    }
}
