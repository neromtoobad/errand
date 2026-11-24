// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Testnet only: a Morpho oracle that always returns the same price (1 collateral = 1 loan token,
/// both 18 decimals). Morpho scales oracle prices by 1e36.
contract FixedPriceOracle {
    function price() external pure returns (uint256) {
        return 1e36;
    }
}
