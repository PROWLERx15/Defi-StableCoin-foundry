// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "lib/foundry-chainlink-toolkit/src/interfaces/feeds/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Prowlerx15
 * @notice This library is used to check the Chainlink Oracle for stale data
 * If a price is stale, the function will revert and render the DSCEngine unstable - this is by design
 * We want the DSCEngine to freeze, if prices become stale.
 * So if the Chainlink network explodes and you have a lot of money locked in the protocol....too bad.
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10800 seconds

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
