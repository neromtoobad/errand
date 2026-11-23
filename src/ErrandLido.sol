// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title ErrandLido
/// @notice Runs on Reactive Network for one wallet. It notices every Lido withdrawal request the wallet
/// holds, waits for Lido to finalize it, and the moment it does, sends the wallet the errand
/// "claim these" (see ErrandWallet.claimLido). Nobody has to be online and no bot holds a key.
/// @dev Three subscriptions on Lido's withdrawal queue:
///   - Transfer(*, wallet, id):  a request NFT arrived (new request, or transferred in) -> track it
///   - Transfer(wallet, *, id):  it left (claimed = burned, or transferred away)       -> drop it
///   - WithdrawalsFinalized(from, to): requests up to `to` are now claimable            -> claim ours
/// If a claim callback fails, the ids stay tracked and the next finalization retries them.
contract ErrandLido is AbstractReactive {
    /// @dev keccak256("Transfer(address,address,uint256)")
    uint256 internal constant TRANSFER_TOPIC = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    /// @dev keccak256("WithdrawalsFinalized(uint256,uint256,uint256,uint256,uint256)")
    uint256 internal constant FINALIZED_TOPIC = 0x197874c72af6a06fb0aa4fab45fd39c7cb61ac0992159872dc3295207da7e9eb;

    /// @notice Most requests claimed in one callback, to keep the callback well inside its gas limit.
    uint256 public constant MAX_BATCH = 20;
    /// @dev Callback gas: the proxy keeps ~200k for its own accounting; Lido needs roughly 60-90k per request.
    uint64 internal constant CALLBACK_GAS_BASE = 400_000;
    uint64 internal constant CALLBACK_GAS_PER_REQUEST = 90_000;

    /// @notice Who deployed this errand (normally the same key as the wallet). Can top up, retry, withdraw.
    address public immutable OWNER;
    /// @notice The wallet whose withdrawals this errand claims. Delegates to an ErrandWallet via EIP-7702.
    address public immutable WALLET;
    /// @notice Chain the wallet and Lido live on (1 for Ethereum).
    uint256 public immutable CHAIN_ID;
    /// @notice Lido's withdrawal queue on that chain.
    address public immutable QUEUE;

    /// @notice Highest request id Lido has finalized, as far as this errand has seen.
    uint256 public lastFinalizedId;
    /// @notice How many claim errands this contract has sent.
    uint256 public errandsSent;

    uint256[] private _tracked;
    mapping(uint256 requestId => uint256 indexPlusOne) private _trackedIndex;

    event Tracking(uint256 indexed requestId);
    event Dropped(uint256 indexed requestId);
    event ErrandSent(uint256 indexed errandNumber, uint256[] requestIds, uint256 triggeredByTxHash);

    error NotOwner(address caller);
    error ZeroAddress();

    constructor(address wallet_, uint256 chainId_, address queue_, uint256 lastFinalizedId_) payable {
        if (wallet_ == address(0) || queue_ == address(0)) revert ZeroAddress();
        OWNER = msg.sender;
        WALLET = wallet_;
        CHAIN_ID = chainId_;
        QUEUE = queue_;
        lastFinalizedId = lastFinalizedId_;

        uint256 wallet = uint256(uint160(wallet_));
        SYSTEM.subscribe(chainId_, queue_, TRANSFER_TOPIC, REACTIVE_IGNORE, wallet, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, queue_, TRANSFER_TOPIC, wallet, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, queue_, FINALIZED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Called by Reactive Network's system contract for every matching log.
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != CHAIN_ID || log_.contractAddress != QUEUE) return;

        if (log_.topic0 == TRANSFER_TOPIC && log_.opCode == 4) {
            // Indexed address topics are left-padded addresses, so the casts are exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            address from = address(uint160(log_.topic1));
            // forge-lint: disable-next-line(unsafe-typecast)
            address to = address(uint160(log_.topic2));
            uint256 requestId = log_.topic3;
            if (to == WALLET && from != WALLET) {
                _track(requestId);
                // A request transferred in may already be claimable.
                if (requestId <= lastFinalizedId) _sendClaimErrand(log_.txHash);
            } else if (from == WALLET && to != WALLET) {
                _drop(requestId);
            }
        } else if (log_.topic0 == FINALIZED_TOPIC && log_.opCode == 3) {
            uint256 to = log_.topic2;
            if (to > lastFinalizedId) lastFinalizedId = to;
            _sendClaimErrand(log_.txHash);
        }
    }

    /// @notice Requests the wallet is waiting on.
    function tracked() external view returns (uint256[] memory) {
        return _tracked;
    }

    /// @notice Track requests the wallet already held before this errand was deployed.
    function trackExisting(uint256[] calldata requestIds_) external onlyOwner {
        for (uint256 i; i < requestIds_.length; ++i) {
            _track(requestIds_[i]);
        }
    }

    /// @notice Send the claim errand now for anything tracked and already finalized (manual retry).
    function claimNow() external onlyOwner {
        _sendClaimErrand(0);
    }

    /// @notice Settle any debt to the system contract from this contract's balance. Anyone may call it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Return unused REACT to the owner.
    function withdraw(uint256 amount_) external onlyOwner {
        _pay(payable(OWNER), amount_);
    }

    function _track(uint256 requestId_) internal {
        if (_trackedIndex[requestId_] != 0) return;
        _tracked.push(requestId_);
        _trackedIndex[requestId_] = _tracked.length;
        emit Tracking(requestId_);
    }

    function _drop(uint256 requestId_) internal {
        uint256 indexPlusOne = _trackedIndex[requestId_];
        if (indexPlusOne == 0) return;
        uint256 last = _tracked[_tracked.length - 1];
        _tracked[indexPlusOne - 1] = last;
        _trackedIndex[last] = indexPlusOne;
        _tracked.pop();
        delete _trackedIndex[requestId_];
        emit Dropped(requestId_);
    }

    /// @dev Collects tracked ids that are finalized, sorts them (Lido's hints need ascending ids) and
    /// asks Reactive Network to call ErrandWallet.claimLido on the wallet's chain.
    function _sendClaimErrand(uint256 triggeredBy_) internal {
        uint256 n = _tracked.length;
        uint256[] memory ids = new uint256[](n < MAX_BATCH ? n : MAX_BATCH);
        uint256 count = 0;
        for (uint256 i; i < n && count < ids.length; ++i) {
            uint256 id = _tracked[i];
            if (id <= lastFinalizedId) ids[count++] = id;
        }
        if (count == 0) return;
        assembly {
            mstore(ids, count)
        }
        _sortAscending(ids);

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: CHAIN_ID,
                recipient: WALLET,
                // forge-lint: disable-next-line(unsafe-typecast)
                gasLimit: CALLBACK_GAS_BASE + CALLBACK_GAS_PER_REQUEST * uint64(count), // count <= MAX_BATCH
                payload: abi.encodeWithSignature("claimLido(address,uint256[])", address(0), ids)
            })
        );
        emit ErrandSent(++errandsSent, ids, triggeredBy_);
    }

    function _sortAscending(uint256[] memory a_) internal pure {
        for (uint256 i = 1; i < a_.length; ++i) {
            uint256 v = a_[i];
            uint256 j = i;
            while (j > 0 && a_[j - 1] > v) {
                a_[j] = a_[j - 1];
                --j;
            }
            a_[j] = v;
        }
    }
}
