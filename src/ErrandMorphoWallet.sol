// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPayer} from "reactive-lib/interfaces/IPayer.sol";
import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";

/// @title ErrandMorphoWallet
/// @notice EIP-7702 code for a wallet that lends in one Morpho Blue market. When the market is fully
/// borrowed, the wallet can't withdraw: every repayment or new supply frees a little liquidity, and
/// the first withdrawal takes it. After the wallet asks to exit (`requestExit`), its errand on Reactive
/// Network calls `exitMorpho` on every repay or supply in the market, and the wallet withdraws whatever
/// is free, until its position is empty.
/// @dev Runs in the wallet's own context (`address(this)` is the wallet). No storage: the market and the
/// one reactive contract it trusts are immutables, so each wallet gets its own deployment.
contract ErrandMorphoWallet is IPayer {
    /// @dev Morpho's virtual shares and assets (SharesMathLib), used to price shares the way Morpho does.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Reactive's callback proxy on this chain. The only caller allowed to deliver errands or collect fees.
    IPayable public immutable CALLBACK_PROXY;
    /// @notice The wallet's ErrandMorpho on Reactive Network: the only sender whose errands it accepts.
    address public immutable ERRAND;
    /// @notice Morpho Blue on this chain.
    IMorpho public immutable MORPHO;
    /// @notice The one market this wallet exits from.
    bytes32 public immutable MARKET_ID;
    /// @notice The most the proxy can collect in a single `pay()` call.
    uint256 public immutable MAX_FEE_PER_PAYMENT;

    address internal immutable LOAN_TOKEN;
    address internal immutable COLLATERAL_TOKEN;
    address internal immutable ORACLE;
    address internal immutable IRM;
    uint256 internal immutable LLTV;

    /// @notice The wallet wants out of the market. ErrandMorpho arms on this event.
    event ExitRequested(bytes32 indexed marketId);
    /// @notice The wallet changed its mind. ErrandMorpho disarms on this event.
    event ExitCancelled(bytes32 indexed marketId);
    /// @notice An exit attempt ran. `withdrawn` loan tokens came out; `remainingShares` are still in.
    /// ErrandMorpho disarms when `remainingShares` reaches zero.
    event ExitProgress(bytes32 indexed marketId, uint256 withdrawn, uint256 remainingShares);
    event FeePaid(uint256 amount);

    error NotCallbackProxy(address caller);
    error NotMyErrand(address sender, address expected);
    error NotWallet(address caller);
    error FeeAboveCap(uint256 amount, uint256 cap);
    error TransferFailed();
    error ZeroAddress();

    constructor(
        IPayable callbackProxy_,
        address errand_,
        IMorpho morpho_,
        MarketParams memory market_,
        uint256 maxFeePerPayment_
    ) {
        if (address(callbackProxy_) == address(0) || errand_ == address(0) || address(morpho_) == address(0)) {
            revert ZeroAddress();
        }
        CALLBACK_PROXY = callbackProxy_;
        ERRAND = errand_;
        MORPHO = morpho_;
        MAX_FEE_PER_PAYMENT = maxFeePerPayment_;
        LOAN_TOKEN = market_.loanToken;
        COLLATERAL_TOKEN = market_.collateralToken;
        ORACLE = market_.oracle;
        IRM = market_.irm;
        LLTV = market_.lltv;
        MARKET_ID = keccak256(abi.encode(market_));
    }

    modifier onlyCallbackProxy() {
        if (msg.sender != address(CALLBACK_PROXY)) revert NotCallbackProxy(msg.sender);
        _;
    }

    /// @dev Under EIP-7702 a transaction the wallet sends to itself has msg.sender == address(this).
    modifier onlyWallet() {
        if (msg.sender != address(this)) revert NotWallet(msg.sender);
        _;
    }

    /// @notice The market this wallet exits from.
    function marketParams() public view returns (MarketParams memory) {
        return MarketParams(LOAN_TOKEN, COLLATERAL_TOKEN, ORACLE, IRM, LLTV);
    }

    /// @notice Ask Errand to get this wallet out of the market as liquidity frees up. Send it to yourself.
    function requestExit() external onlyWallet {
        emit ExitRequested(MARKET_ID);
    }

    /// @notice Stop exiting.
    function cancelExit() external onlyWallet {
        emit ExitCancelled(MARKET_ID);
    }

    /// @notice Withdraw as much of the wallet's supply as the market can pay out right now.
    /// @param errand_ Injected by Reactive Network: the reactive contract that requested this callback.
    /// @dev Never reverts for lack of liquidity: with nothing free it records an empty attempt, so a
    /// late or duplicate errand costs only gas.
    function exitMorpho(address errand_) external onlyCallbackProxy {
        if (errand_ != ERRAND) revert NotMyErrand(errand_, ERRAND);
        MarketParams memory params = marketParams();
        MORPHO.accrueInterest(params);

        (uint256 shares,,) = MORPHO.position(MARKET_ID, address(this));
        uint256 withdrawn = 0;
        if (shares > 0) {
            (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets,,,) =
                MORPHO.market(MARKET_ID);
            uint256 free = totalSupplyAssets - totalBorrowAssets;
            uint256 owned = shares * (uint256(totalSupplyAssets) + VIRTUAL_ASSETS)
                / (uint256(totalSupplyShares) + VIRTUAL_SHARES);
            if (owned <= free) {
                // Everything fits: burn all shares so no dust is left behind.
                (withdrawn,) = MORPHO.withdraw(params, 0, shares, address(this), address(this));
                shares = 0;
            } else if (free > 0) {
                uint256 burned;
                (withdrawn, burned) = MORPHO.withdraw(params, free, 0, address(this), address(this));
                shares -= burned;
            }
        }
        emit ExitProgress(MARKET_ID, withdrawn, shares);
    }

    /// @inheritdoc IPayer
    /// @dev Called by the callback proxy when a delivery fee is due and reserves are empty. Capped per call.
    function pay(uint256 amount_) external onlyCallbackProxy {
        _payProxy(amount_);
    }

    /// @notice Settle any outstanding callback debt from the wallet's balance. Only the wallet itself can call this.
    function coverDebt() external onlyWallet {
        _payProxy(CALLBACK_PROXY.debt(address(this)));
    }

    function _payProxy(uint256 amount_) private {
        if (amount_ > MAX_FEE_PER_PAYMENT) revert FeeAboveCap(amount_, MAX_FEE_PER_PAYMENT);
        if (amount_ == 0) return;
        (bool ok,) = payable(address(CALLBACK_PROXY)).call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit FeePaid(amount_);
    }

    // ---- Keep behaving like a plain wallet ----

    receive() external payable {}

    /// @dev A call with data to a plain wallet succeeds and does nothing; keep it that way.
    fallback() external payable {}
}
