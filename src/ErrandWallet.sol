// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPayer} from "reactive-lib/interfaces/IPayer.sol";
import {ILidoWithdrawalQueue} from "./interfaces/ILidoWithdrawalQueue.sol";

/// @title ErrandWallet
/// @notice The code an ordinary wallet points to with EIP-7702. After that one signature the wallet
/// stays the same address with the same key, and it gains exactly one thing it will do on its own:
/// claim its finalized Lido withdrawals to itself, when told to by its own errand contract on
/// Reactive Network, delivered through Reactive's callback proxy.
/// @dev Runs in the wallet's own context, so `address(this)` is the user's wallet. It keeps no
/// storage; everything it needs is immutable and lives in this contract's code. Each wallet gets its
/// own deployment, because `ERRAND` (the only reactive contract it trusts) differs per wallet.
/// It mirrors reactive-lib's AbstractCallback checks, but implements `pay()` itself so it can cap
/// how much the proxy can collect in one call (AbstractPayer's `pay()` is not overridable).
contract ErrandWallet is IPayer {
    /// @notice Reactive's callback proxy on this chain. The only caller allowed to deliver errands or collect fees.
    IPayable public immutable CALLBACK_PROXY;
    /// @notice The reactive contract on Reactive Network that may send this wallet errands.
    address public immutable ERRAND;
    /// @notice Lido's withdrawal queue.
    ILidoWithdrawalQueue public immutable LIDO_QUEUE;
    /// @notice Most the callback proxy can collect in a single `pay()`. Bounds what the proxy could ever take.
    uint256 public immutable MAX_FEE_PER_PAYMENT;

    /// @notice The wallet claimed these requests and received `ethReceived`.
    event LidoClaimed(address indexed errand, uint256[] requestIds, uint256 ethReceived);
    /// @notice A request in the errand was not claimable (not finalized, already claimed, not ours, or out of order).
    event LidoSkipped(uint256 indexed requestId);
    /// @notice Fee paid to the callback proxy for delivering an errand.
    event FeePaid(uint256 amount);

    error NotCallbackProxy(address caller);
    error NotMyErrand(address sender, address expected);
    error FeeAboveCap(uint256 amount, uint256 cap);
    error NotWallet(address caller);
    error TransferFailed();
    error ZeroAddress();

    constructor(IPayable callbackProxy_, address errand_, ILidoWithdrawalQueue lidoQueue_, uint256 maxFeePerPayment_) {
        if (address(callbackProxy_) == address(0) || errand_ == address(0) || address(lidoQueue_) == address(0)) {
            revert ZeroAddress();
        }
        CALLBACK_PROXY = callbackProxy_;
        ERRAND = errand_;
        LIDO_QUEUE = lidoQueue_;
        MAX_FEE_PER_PAYMENT = maxFeePerPayment_;
    }

    modifier onlyCallbackProxy() {
        if (msg.sender != address(CALLBACK_PROXY)) revert NotCallbackProxy(msg.sender);
        _;
    }

    /// @notice Claim the given Lido withdrawal requests to this wallet.
    /// @param errand_ Injected by Reactive Network: the reactive contract that requested this callback.
    /// @param requestIds_ Request ids, ascending. Anything not claimable right now is skipped, not reverted,
    /// so a stale or duplicate errand costs only gas.
    function claimLido(address errand_, uint256[] calldata requestIds_) external onlyCallbackProxy {
        if (errand_ != ERRAND) revert NotMyErrand(errand_, ERRAND);

        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = LIDO_QUEUE.getWithdrawalStatus(requestIds_);
        uint256[] memory claimable = new uint256[](requestIds_.length);
        uint256 count = 0;
        uint256 previous = 0;
        for (uint256 i; i < requestIds_.length; ++i) {
            ILidoWithdrawalQueue.WithdrawalRequestStatus memory s = statuses[i];
            bool ordered = count == 0 || requestIds_[i] > previous;
            if (s.isFinalized && !s.isClaimed && s.owner == address(this) && ordered) {
                claimable[count++] = requestIds_[i];
                previous = requestIds_[i];
            } else {
                emit LidoSkipped(requestIds_[i]);
            }
        }
        if (count == 0) return;
        assembly {
            mstore(claimable, count)
        }

        uint256[] memory hints = LIDO_QUEUE.findCheckpointHints(claimable, 1, LIDO_QUEUE.getLastCheckpointIndex());
        uint256 balanceBefore = address(this).balance;
        LIDO_QUEUE.claimWithdrawals(claimable, hints);
        emit LidoClaimed(errand_, claimable, address(this).balance - balanceBefore);
    }

    /// @inheritdoc IPayer
    /// @dev Called by the callback proxy when a delivery fee is due and reserves are empty. Capped per call.
    function pay(uint256 amount_) external onlyCallbackProxy {
        _payProxy(amount_);
    }

    /// @notice Settle any outstanding callback debt from the wallet's balance. Only the wallet itself can call this.
    function coverDebt() external {
        if (msg.sender != address(this)) revert NotWallet(msg.sender);
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

    /// @inheritdoc IPayer
    receive() external payable {}

    /// @dev A call with data to a plain wallet succeeds and does nothing; keep it that way.
    fallback() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
