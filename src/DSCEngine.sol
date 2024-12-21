// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/foundry-chainlink-toolkit/src/interfaces/feeds/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Prowlerx15
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 *
 * This stablecoin has the following properties:
 * -> Exogenous Collateral
 * -> Dollar Pegged
 * -> Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH & WBTC.
 *
 * Our DSC system should be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of the all DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic of miniting and reedeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /* errors */
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAdrressesMustBeSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TranferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealyhFactorOK();
    error DSCEngine__BreaksHealthFactorNotImproved();

    /* Type declarations */
    using OracleLib for AggregatorV3Interface;

    /* State variables */
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200%  overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means a 10% Bonus
    DecentralizedStableCoin private immutable i_DSC;

    /* Events */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /* Modifiers */
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
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

    /* Functions */

    /* constructor */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddreses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddreses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAdrressesMustBeSame();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddreses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_DSC = DecentralizedStableCoin(dscAddress);
    }

    /* external */

    /**
     *
     * @param tokenCollateralAddress The address of the token to be deposited as the collateral
     * @param amountCollateral The amount of the collateral to be deposited
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI - Checks, Effects, Interactions
     * @param tokenCollateralAddress The address of the token to be deposited as the collateral
     * @param amountCollateral The amount of the collateral to be deposited
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TranferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress The collateral address to be redeemed
     * @param amountCollateral The amount of collateral to be redeemed
     * @param amount The amount of DSC to burn
     * @notice The function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amount)
        external
    {
        burnDSc(amount);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral() already checks health factor
    }

    // Inorder to reedem collateral:
    // -> Health Factor MUST BE GREATER THAN 1 AFTER COLLATERAL PULLED
    // DRY -> Don't Repeat Yourself
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice They  must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_DSC.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSc(uint256 amount) public moreThanZero(amount) {
        _burnDSc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If we do start to nearing undercollateraliztion, we need someone to liquidate positions

    // $100 ETH backing $50 DSC
    // $20 ETH backing $50 DSC -> DSC isn't working!!!

    // $75 backing $50 DSC
    // Liquidator take $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     *
     * @param collateral The ERC20 address collateral to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount DSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user's funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollaterized in order of this to work
     * @notice A know bug would be if the protocol were 100% or less collateralized teh we wouldn't be able to incentive the liquidators.
     *         For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealyhFactorOK();
        }

        // We want to burn their DSC "debt"
        // And take their collateral
        // BAD USER: $140 ETH, $100 DSC
        // debtToCover = $100 DSC
        // $100 of DSC == how much ETH?

        uint256 tokenAmountOfDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // We are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        // 0.005 * 0.1
        uint256 bonusCollateral = (tokenAmountOfDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountOfDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        // Burn the DSC
        _burnDSc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__BreaksHealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /* public */
    /* internal */
    /* private */

    /* internal & private view & pure functions */

    /**
     * @dev Low level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDSc(uint256 amount, address onBehalfOf, address dscFrom) private moreThanZero(amount) {
        s_DscMinted[onBehalfOf] -= amount;
        bool success = i_DSC.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TranferFailed();
        }
        i_DSC.burn(amount);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TranferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _getAccountInfo(address user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is.
     * If a user goes below 1, then they can get liquidated
     * @param user The address of the user
     */
    function _healthFactor(address user) internal view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInfo(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /* external & public view & pure functions */

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH -> ETH?
        // $2000/ETH , $1000 is the amount -> ETH = 0.5

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        // 0.005e18 or 5e15
        // amount of ETH -> 0.005 ETH
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * (amount)) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInfo(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinimumHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getDsc() external view returns (address) {
        return address(i_DSC);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
