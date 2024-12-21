// Have our invariants aka properties of the system that should always hold

// What are our invariants?

// 1. The total supply of DSC should be less than the total value of the collateral
// 2. Getter view functions should never revert <- Evergreen Invariant

// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Handler} from "./Handler.t.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "lib/foundry-chainlink-toolkit/src/interfaces/feeds/AggregatorV3Interface.sol";

contract OpenInvariantsTests is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    Handler handler;
    address wethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler)); // Set Handler as the target

        // hey, don't call redeem collateral unless there is collateral to redeem
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get all the value of the collateral in the protocol
        // compare it to the debt (DSC)

        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);
        console.log("totalSupply: %s", totalSupply);
        console.log("times mintdsc called: %s", handler.timesMintIsCalled());
        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        // engine.getAccountCollateralValue();
        // engine.getAccountInformation();
        // engine.getAdditionalFeedPrecision();
    }
}
