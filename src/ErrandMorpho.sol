// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title ErrandMorpho
/// @notice Runs on Reactive Network for one wallet and one Morpho Blue market. Once the wallet asks to
/// exit, every repay or supply in the market (each one frees liquidity) sends the wallet the errand
/// "withdraw what's free now" (see ErrandMorphoWallet.exitMorpho), until the wallet reports it is out.
/// @dev Subscriptions, all on the wallet's chain:
///   - Morpho Repay(marketId, ...) and Supply(marketId, ...): liquidity just arrived  -> errand, if armed
///   - wallet ExitRequested(marketId)                      -> arm, and try right away
///   - wallet ExitCancelled(marketId)                      -> disarm
///   - wallet ExitProgress(marketId, withdrawn, remaining) -> disarm when remaining == 0
contract ErrandMorpho is AbstractReactive {
    /// @dev keccak256("Repay(bytes32,address,address,uint256,uint256)")
    uint256 internal constant REPAY_TOPIC = 0x52acb05cebbd3cd39715469f22afbf5a17496295ef3bc9bb5944056c63ccaa09;
    /// @dev keccak256("Supply(bytes32,address,address,uint256,uint256)")
    uint256 internal constant SUPPLY_TOPIC = 0xedf8870433c83823eb071d3df1caa8d008f12f6440918c20d75a3602cda30fe0;
    /// @dev keccak256("ExitRequested(bytes32)")
    uint256 internal constant EXIT_REQUESTED_TOPIC = uint256(keccak256("ExitRequested(bytes32)"));
    /// @dev keccak256("ExitCancelled(bytes32)")
    uint256 internal constant EXIT_CANCELLED_TOPIC = uint256(keccak256("ExitCancelled(bytes32)"));
    /// @dev keccak256("ExitProgress(bytes32,uint256,uint256)")
    uint256 internal constant EXIT_PROGRESS_TOPIC = uint256(keccak256("ExitProgress(bytes32,uint256,uint256)"));

    /// @dev Accrue + read + withdraw is ~120k gas; the rest is headroom for the proxy's accounting.
    uint64 public constant CALLBACK_GAS = 400_000;

    /// @notice Who deployed this errand (normally the same key as the wallet). Can withdraw unused REACT.
    address public immutable OWNER;
    /// @notice The lending wallet. Delegates to an ErrandMorphoWallet via EIP-7702.
    address public immutable WALLET;
    /// @notice Chain the wallet and the market live on.
    uint256 public immutable CHAIN_ID;
    /// @notice Morpho Blue on that chain.
    address public immutable MORPHO;
    /// @notice The market the wallet exits from.
    bytes32 public immutable MARKET_ID;

    /// @notice True between the wallet's ExitRequested and the moment it is fully out (or cancels).
    bool public armed;
    /// @notice How many withdraw errands this contract has sent.
    uint256 public errandsSent;

    event Armed(uint256 triggeredByTxHash);
    event Disarmed(uint256 triggeredByTxHash, bool exited);
    event ErrandSent(uint256 indexed errandNumber, uint256 triggeredByTxHash);

    error NotOwner(address caller);
    error ZeroAddress();

    constructor(address wallet_, uint256 chainId_, address morpho_, bytes32 marketId_) payable {
        if (wallet_ == address(0) || morpho_ == address(0)) revert ZeroAddress();
        OWNER = msg.sender;
        WALLET = wallet_;
        CHAIN_ID = chainId_;
        MORPHO = morpho_;
        MARKET_ID = marketId_;

        uint256 market = uint256(marketId_);
        SYSTEM.subscribe(chainId_, morpho_, REPAY_TOPIC, market, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, morpho_, SUPPLY_TOPIC, market, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, wallet_, EXIT_REQUESTED_TOPIC, market, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, wallet_, EXIT_CANCELLED_TOPIC, market, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, wallet_, EXIT_PROGRESS_TOPIC, market, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        _;
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != CHAIN_ID || log_.topic1 != uint256(MARKET_ID)) return;

        if (log_.contractAddress == MORPHO) {
            if (log_.topic0 != REPAY_TOPIC && log_.topic0 != SUPPLY_TOPIC) return;
            // The wallet's own supply is not liquidity it can exit with.
            if (log_.topic0 == SUPPLY_TOPIC && log_.topic3 == uint256(uint160(WALLET))) return;
            if (armed) _sendWithdrawErrand(log_.txHash);
        } else if (log_.contractAddress == WALLET) {
            if (log_.topic0 == EXIT_REQUESTED_TOPIC) {
                armed = true;
                emit Armed(log_.txHash);
                _sendWithdrawErrand(log_.txHash); // there may already be liquidity free
            } else if (log_.topic0 == EXIT_CANCELLED_TOPIC) {
                _disarm(log_.txHash, false);
            } else if (log_.topic0 == EXIT_PROGRESS_TOPIC) {
                (, uint256 remainingShares) = abi.decode(log_.data, (uint256, uint256));
                if (remainingShares == 0) _disarm(log_.txHash, true);
            }
        }
    }

    /// @notice Settle any debt to the system contract from this contract's balance. Anyone may call it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Return unused REACT to the owner.
    function withdraw(uint256 amount_) external onlyOwner {
        _pay(payable(OWNER), amount_);
    }

    function _disarm(uint256 triggeredBy_, bool exited_) internal {
        if (!armed) return;
        armed = false;
        emit Disarmed(triggeredBy_, exited_);
    }

    function _sendWithdrawErrand(uint256 triggeredBy_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: CHAIN_ID,
                recipient: WALLET,
                gasLimit: CALLBACK_GAS,
                payload: abi.encodeWithSignature("exitMorpho(address)", address(0))
            })
        );
        emit ErrandSent(++errandsSent, triggeredBy_);
    }
}
