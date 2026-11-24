// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IMorpho, MarketParams} from "../interfaces/IMorpho.sol";
import {TestToken} from "./TestToken.sol";

/// @notice TESTNET ONLY. Lets a visitor of the demo page free liquidity in the demo market with one
/// transaction: it mints test tUSD (worthless, open-mint) and supplies it to Morpho Blue on the visitor's
/// behalf. That Supply event is what ErrandMorpho reacts to. The deposit belongs to the visitor.
contract DemoDeposit {
    uint256 public constant MAX_DEPOSIT = 50 ether;

    IMorpho public immutable MORPHO;
    TestToken public immutable LOAN_TOKEN;
    address public immutable COLLATERAL_TOKEN;
    address public immutable ORACLE;
    address public immutable IRM;
    uint256 public immutable LLTV;

    error AmountOutOfRange(uint256 amount);

    constructor(IMorpho morpho_, MarketParams memory market_) {
        MORPHO = morpho_;
        LOAN_TOKEN = TestToken(market_.loanToken);
        COLLATERAL_TOKEN = market_.collateralToken;
        ORACLE = market_.oracle;
        IRM = market_.irm;
        LLTV = market_.lltv;
        LOAN_TOKEN.approve(address(morpho_), type(uint256).max);
    }

    /// @notice Mint `assets` test tUSD and lend it into the demo market as the caller.
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0 || assets > MAX_DEPOSIT) revert AmountOutOfRange(assets);
        LOAN_TOKEN.mint(address(this), assets);
        (, shares) = MORPHO.supply(
            MarketParams(address(LOAN_TOKEN), COLLATERAL_TOKEN, ORACLE, IRM, LLTV), assets, 0, msg.sender, ""
        );
    }
}
