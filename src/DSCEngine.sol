// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title DSC Engine
 * @author Srinidhi
 * @notice Core contract for minting, burning, and managing collateral
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine_BreaksHealthFactor();
    error DSCEngine__HealthFactorOk();
    // State Variables
    uint256 private constant LIQUIDATION_THRESHOLD=50;
    mapping(address => address) private s_priceFeeds; // token -> price feed
    mapping(address user => mapping(address token=>uint256 amount)) private s_collateralDeposited;
    mapping(address user=>uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant LIQUIDATION_BONUS=10; // 10% bonus for liquidators
  // events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed reedeemedFrom, address indexed reedemTo, address indexed token,uint256 amount);
    // Modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // ========================= CORE FUNCTIONS =========================

    function depositCollateralAndMintDsc(address tokenCollateralAddress,
        uint256 amountCollateral,uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress,amountCollateral);
        mintDsc(amountDscToMint);
        }

    /**
     * @param tokenCollateralAddress address of collateral token
     * @param amountCollateral amount to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender,tokenCollateralAddress,amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender,address(this),amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc(address tokenCollateralAddress,uint256 amountCollateral,uint256 amountDsc) external {
        burnDsc(amountDsc);
        _reedeemCollateral(tokenCollateralAddress,amountCollateral,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollatralAddress,uint256 amount) external
    moreThanZero(amount) nonReentrant()
    {
        _reedeemCollateral(tokenCollatralAddress,amount,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
    *@notice follows CEI
    * @param amountDscToMint amount of DSC to 
    *@notice they must have more collateral than the minimum threshold factor after minting
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant() {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__TransferFailed();
        }
    }


    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant() {
       _burnDsc(amount,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
        
    }
    // if someone is about undercollateralized,we will pay you to liquidate them
    function liquidate(address collateral,address user,uint256 debtToCover) external {
        uint256 startingHealthFactor=_healthFactor(user);
        if (startingHealthFactor >= 1e18) {
            revert DSCEngine__HealthFactorOk();
        }
        // how much collateral to give the liquidator for covering the debtToCover
        uint256 tokenAmountFromDebtCovered=getTokenAmountFromUsd(collateral,debtToCover);
        uint256 bonusCollateral= (tokenAmountFromDebtCovered*LIQUIDATION_BONUS)/100;
        uint256 totalCollateralToGive=tokenAmountFromDebtCovered+bonusCollateral;
        _reedeemCollateral(collateral,totalCollateralToGive,user,msg.sender);
       _burnDsc(debtToCover,user , msg.sender);
        uint256 endingHealthFactor=_healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor || endingHealthFactor < 1e18) {
            revert DSCEngine_BreaksHealthFactor();
        }
        _revertIfHealthFactorIsBroken(msg.sender);

    }

   

    // ========================= INTERNAL FUNCTIONS =========================
    /**
    *Returns hpw close to liquidation a user is
    *If a user goes below 1 ,then they can get liquidated
     */
    function _healthFactor(address user) private view returns(uint256){
      (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
      if (totalDscMinted == 0) return type(uint256).max;
      uint256 collateralizationRatio = (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
      return (collateralizationRatio*1e18) / totalDscMinted; // Assuming 150% collateralization is required
    }
    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 totalCollateralValueInUsd) {
      totalDscMinted = s_dscMinted[user];
      totalCollateralValueInUsd=getAccountCollateralValueInUsd(user);
      return (totalDscMinted, totalCollateralValueInUsd);
    }
    function _revertIfHealthFactorIsBroken(address user) internal view {
        if (_healthFactor(user) < 1e18) {
            revert DSCEngine_BreaksHealthFactor();
        }
    }
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        totalCollateralValueInUsd = 0;
        // Loop through all allowed tokens and calculate the total collateral value in USD
        for(uint256 i=0;i<s_collateralTokens.length;i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount > 0) {

                totalCollateralValueInUsd += getPrice(token,amount);
            }
        }
    return totalCollateralValueInUsd;
    }
    function getPrice(address token,uint256 amount) public view returns (uint256 price) {
        AggregatorV3Interface priceFeed=AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 rawPrice,,,) = priceFeed.latestRoundData();
        return (uint256(rawPrice)*1e10)*amount/1e18; // Adjusting price to 18 decimals and multiplying by amount

    }
    function getTokenAmountFromUsd(address token,uint256 usdAmount) public view returns(uint256 tokenAmount){
        AggregatorV3Interface priceFeed=AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 rawPrice,,,) = priceFeed.latestRoundData();
        uint256 tokenPriceInUsd=(uint256(rawPrice)*1e10);
        tokenAmount=(usdAmount*1e18)/tokenPriceInUsd; // Adjusting for decimals

    }
    function _reedeemCollateral(address tokenCollatralAddress,uint256 amount,address from,address to) private{
        s_collateralDeposited[from][tokenCollatralAddress] -= amount;
        emit CollateralRedeemed(from,to,tokenCollatralAddress,amount);
        bool success = IERC20(tokenCollatralAddress).transfer(to,amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    function _burnDsc(uint256 amount,address onbehalfof,address from) private{
        s_dscMinted[onbehalfof] -= amount;
        
        bool success = i_dsc.transferFrom(from, address(this),amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    } 
    function getAccountBalance(address user) external view returns(uint256 dscMinted,uint256 collateralValueInUsd){
        (dscMinted,collateralValueInUsd)=_getAccountInformation(user);
    }
}