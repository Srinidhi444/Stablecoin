// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDsc is Script{
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    function run() external  returns(DecentralizedStableCoin, DSCEngine,HelperConfig){
        HelperConfig helperconfig=new HelperConfig();
        (address wethUsdPriceFeed,address wbtcUsdPriceFeed,address weth,address wbtc,uint256 deployerkey)=helperconfig.activeNetworkConfig();
        tokenAddresses=[weth,wbtc];
        priceFeedAddresses=[wethUsdPriceFeed,wbtcUsdPriceFeed];
        vm.startBroadcast(deployerkey);
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine dscEngine = new DSCEngine(tokenAddresses,priceFeedAddresses,address(dsc));
        dsc.transferOwnership(address(dscEngine));
        vm.stopBroadcast();
        return (dsc, dscEngine, helperconfig);
    }
}
