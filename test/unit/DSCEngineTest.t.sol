// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {Test, console} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "lib/foundry-chainlink-toolkit/src/interfaces/feeds/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address wethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DSC_MINTED = 20;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    //CONSTRUCTOR TESTS

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLenghtDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAdrressesMustBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // PRICE TESTS
    function testgetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testgetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH ,$100 0.05 ether
        uint256 expectedEther = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEther, actualWeth);
    }

    // DEPOSIT COLLATERAL TESTS

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = engine.getUsdValue(address(weth), AMOUNT_COLLATERAL);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    // MINT DSC

    function testCanMintDsc() public depositedCollateral {
        uint256 expectedDscMinted = 20;
        vm.startPrank(USER);
        engine.mintDsc(DSC_MINTED);
        vm.stopPrank();
        (uint256 actualDscMinted,) = engine.getAccountInformation(USER);
        assertEq(expectedDscMinted, actualDscMinted);
    }

    // // After minting 10,000 DSC, the health factor is 1.
    // // Any additional DSC minting attempt will reduce the health factor below the MIN_HEALTH_FACTOR of 1
    // // Causing the transaction to revert.
    // function testMintDscFailsDueToBrokenHealthFactor() public {
    //     ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    //     (, int256 price,,,) = AggregatorV3Interface(wethUsdPriceFeed).latestRoundData();
    //     uint256 amountToMint =
    //         (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
    //     vm.startPrank(USER);
    //     uint256 expectedHealthFactor =
    //         engine.calculateHealthFactor(amountToMint, (engine.getUsdValue(weth, AMOUNT_COLLATERAL)));
    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
    //     engine.mintDsc(amountToMint);
    //     vm.stopPrank();
    // }

    // HEALTH FACTOR

    function testgethealthFactor() public depositedCollateral {
        // Checking health factor when collateral is deposited but DSC is NOT minted
        // Deposit AMOUNT_COLLATERAL = 10 ether
        // Collateral Value in USD -> 10 * $2000 -> $20,000
        // DSC Minted = 0
        // Health Factor = ( (20,000 * 50) / 100) * / 0 -> Undefined
        // Health Factor is set to maximum value of uint256

        uint256 expectedHealthFactor = UINT256_MAX;
        uint256 actualHealthFactor = engine.getHealthFactor(USER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }
}
