// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice The parts of Lido's WithdrawalQueueERC721 that Errand uses.
/// Mainnet: 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
interface ILidoWithdrawalQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    /// @notice Emitted once a day (after the Lido oracle report) for the range of requests that became claimable.
    event WithdrawalsFinalized(
        uint256 indexed from, uint256 indexed to, uint256 amountOfETHLocked, uint256 sharesToBurn, uint256 timestamp
    );

    /// @notice Every withdrawal request is an NFT; mint, burn (on claim) and transfers emit this.
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    function getLastCheckpointIndex() external view returns (uint256);

    function findCheckpointHints(uint256[] calldata requestIds, uint256 firstIndex, uint256 lastIndex)
        external
        view
        returns (uint256[] memory hintIds);

    function getClaimableEther(uint256[] calldata requestIds, uint256[] calldata hints)
        external
        view
        returns (uint256[] memory claimableEthValues);

    /// @notice Claims finalized requests owned by msg.sender and sends the ETH to msg.sender.
    function claimWithdrawals(uint256[] calldata requestIds, uint256[] calldata hints) external;

    function requestWithdrawals(uint256[] calldata amounts, address owner) external returns (uint256[] memory requestIds);

    function getLastFinalizedRequestId() external view returns (uint256);

    function getLastRequestId() external view returns (uint256);

    function transferFrom(address from, address to, uint256 requestId) external;
}
