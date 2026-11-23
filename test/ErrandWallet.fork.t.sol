// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {ErrandWallet} from "../src/ErrandWallet.sol";
import {ErrandLido} from "../src/ErrandLido.sol";
import {ILidoWithdrawalQueue} from "../src/interfaces/ILidoWithdrawalQueue.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

/// @notice Runs against a fork of Ethereum mainnet: the real Lido queue, real finalized requests,
/// and a wallet delegated with a real EIP-7702 authorization.
/// Run with: ETHEREUM_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract Fork
contract ErrandWalletForkTest is Test {
    ILidoWithdrawalQueue constant QUEUE = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);
    /// @dev Reactive Omni callback proxy on Ethereum mainnet (docs: Origins & Destinations).
    address constant PROXY = 0xFCE1F192F489c988392aBC16E91e359d540d94Fe;
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant MAX_FEE = 0.001 ether;

    uint256 constant USER_KEY = 0xA11CE;
    address user;
    address errandOnReactive = makeAddr("errand on Reactive Network");
    ErrandWallet impl;
    uint256 requestId;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        user = vm.addr(USER_KEY);
        impl = new ErrandWallet(IPayable(payable(PROXY)), errandOnReactive, QUEUE, MAX_FEE);
        vm.signAndAttachDelegation(address(impl), USER_KEY);
        (bool ok,) = user.call(""); // the authorization takes effect with this transaction
        assertTrue(ok);

        // Take a real request that Lido has finalized but nobody has claimed, and give it to our wallet.
        requestId = _findFinalizedUnclaimed();
        address holder = _status(requestId).owner;
        vm.prank(holder);
        QUEUE.transferFrom(holder, user, requestId);
    }

    modifier onlyForked() {
        vm.skip(!forked);
        _;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _status(uint256 id) internal view returns (ILidoWithdrawalQueue.WithdrawalRequestStatus memory) {
        return QUEUE.getWithdrawalStatus(_ids(id))[0];
    }

    function _claimable(uint256 id) internal view returns (uint256) {
        uint256[] memory ids = _ids(id);
        uint256[] memory hints = QUEUE.findCheckpointHints(ids, 1, QUEUE.getLastCheckpointIndex());
        return QUEUE.getClaimableEther(ids, hints)[0];
    }

    function _findFinalizedUnclaimed() internal view returns (uint256) {
        uint256 last = QUEUE.getLastFinalizedRequestId();
        for (uint256 id = last; id > last - 500; --id) {
            ILidoWithdrawalQueue.WithdrawalRequestStatus memory s = _status(id);
            if (s.isFinalized && !s.isClaimed && s.owner.code.length == 0) return id;
        }
        revert("no finalized unclaimed request found");
    }

    function test_walletIsDelegatedAndKeepsItsAddress() public onlyForked {
        // EIP-7702 delegation designator: 0xef0100 || implementation
        assertEq(user.code, abi.encodePacked(hex"ef0100", address(impl)));
        assertEq(_status(requestId).owner, user);
    }

    function test_errandFromTheProxyClaimsToTheWallet() public onlyForked {
        uint256 expected = _claimable(requestId);
        assertGt(expected, 0);
        uint256 before = user.balance;

        vm.prank(PROXY);
        ErrandWallet(payable(user)).claimLido(errandOnReactive, _ids(requestId));

        assertEq(user.balance - before, expected, "the wallet received exactly the claimable ETH");
        assertTrue(_status(requestId).isClaimed);
    }

    function test_rejectsAnyCallerButTheProxy() public onlyForked {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ErrandWallet.NotCallbackProxy.selector, attacker));
        ErrandWallet(payable(user)).claimLido(errandOnReactive, _ids(requestId));
    }

    function test_rejectsErrandsFromOtherReactiveContracts() public onlyForked {
        address other = makeAddr("someone else's reactive contract");
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(ErrandWallet.NotMyErrand.selector, other, errandOnReactive));
        ErrandWallet(payable(user)).claimLido(other, _ids(requestId));
    }

    function test_skipsWhatIsNotClaimableAndClaimsTheRest() public onlyForked {
        uint256 notFinalized = QUEUE.getLastRequestId(); // someone else's, still waiting
        uint256[] memory ids = new uint256[](2);
        ids[0] = requestId;
        ids[1] = notFinalized;
        uint256 expected = _claimable(requestId);
        uint256 before = user.balance;

        vm.expectEmit(true, false, false, false, user);
        emit ErrandWallet.LidoSkipped(notFinalized);
        vm.prank(PROXY);
        ErrandWallet(payable(user)).claimLido(errandOnReactive, ids);

        assertEq(user.balance - before, expected);
    }

    function test_duplicateErrandCostsNothingButGas() public onlyForked {
        vm.startPrank(PROXY);
        ErrandWallet(payable(user)).claimLido(errandOnReactive, _ids(requestId));
        uint256 afterFirst = user.balance;
        ErrandWallet(payable(user)).claimLido(errandOnReactive, _ids(requestId)); // already claimed: skipped
        vm.stopPrank();
        assertEq(user.balance, afterFirst);
    }

    function test_feesAreCappedPerPayment() public onlyForked {
        vm.deal(user, 1 ether);
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(ErrandWallet.FeeAboveCap.selector, MAX_FEE + 1, MAX_FEE));
        ErrandWallet(payable(user)).pay(MAX_FEE + 1);

        uint256 proxyBefore = PROXY.balance;
        vm.prank(PROXY);
        ErrandWallet(payable(user)).pay(0.0004 ether);
        assertEq(PROXY.balance - proxyBefore, 0.0004 ether);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ErrandWallet.NotCallbackProxy.selector, attacker));
        ErrandWallet(payable(user)).pay(1);
    }

    function test_onlyTheWalletItselfCanCoverDebt() public onlyForked {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ErrandWallet.NotWallet.selector, attacker));
        ErrandWallet(payable(user)).coverDebt();
    }

    function test_stillBehavesLikeAPlainWallet() public onlyForked {
        address friend = makeAddr("friend");
        vm.deal(friend, 1 ether);
        vm.prank(friend);
        (bool sent,) = user.call{value: 0.1 ether}("");
        assertTrue(sent, "accepts plain ETH");
        vm.prank(friend);
        (bool called,) = user.call(abi.encodeWithSignature("anything(uint256)", 1));
        assertTrue(called, "a call with data does nothing, like a plain wallet");
    }

    /// @notice The whole loop with the real Reactive contract code: Lido's events go into ErrandLido,
    /// its callback request comes out, and that exact payload (sender injected the way the network
    /// does it) is delivered to the wallet by the proxy.
    function test_fullLoop_reactiveContractPayloadClaimsOnEthereum() public onlyForked {
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        ErrandLido errand = new ErrandLido(user, 1, address(QUEUE), requestId - 1);
        // Rebuild the wallet code so it trusts this errand's address.
        ErrandWallet trusting = new ErrandWallet(IPayable(payable(PROXY)), address(errand), QUEUE, MAX_FEE);
        vm.signAndAttachDelegation(address(trusting), USER_KEY);
        (bool ok,) = user.call("");
        assertTrue(ok);

        IReactive.LogRecord memory inbound;
        inbound.chainId = 1;
        inbound.contractAddress = address(QUEUE);
        inbound.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        inbound.topic1 = uint256(uint160(makeAddr("previous holder")));
        inbound.topic2 = uint256(uint160(user));
        inbound.topic3 = requestId;
        inbound.opCode = 4;
        vm.prank(SYSTEM);
        errand.react(inbound);

        IReactive.LogRecord memory finalized;
        finalized.chainId = 1;
        finalized.contractAddress = address(QUEUE);
        finalized.topic0 = uint256(keccak256("WithdrawalsFinalized(uint256,uint256,uint256,uint256,uint256)"));
        finalized.topic1 = requestId;
        finalized.topic2 = requestId;
        finalized.opCode = 3;
        vm.prank(SYSTEM);
        errand.react(finalized);

        ISystemContract.CallbackConfiguration_V_1_0 memory cb = MockSystem(payable(SYSTEM)).callbackAt(0);
        assertEq(cb.chainId, 1);
        assertEq(cb.recipient, user);
        bytes memory payload = cb.payload;
        address sender = address(errand);
        assembly {
            // The network overwrites the first argument (bytes 4..36) with the requesting contract.
            mstore(add(payload, 36), sender)
        }

        uint256 expected = _claimable(requestId);
        uint256 before = user.balance;
        vm.prank(PROXY);
        (bool delivered,) = user.call{gas: cb.gasLimit}(payload);
        assertTrue(delivered);
        assertEq(user.balance - before, expected);
        assertTrue(_status(requestId).isClaimed);
    }
}
