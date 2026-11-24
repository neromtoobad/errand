// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {ErrandMorphoWallet} from "../src/ErrandMorphoWallet.sol";
import {ErrandMorpho} from "../src/ErrandMorpho.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {TestToken} from "../src/testnet/TestToken.sol";
import {FixedPriceOracle} from "../src/testnet/FixedPriceOracle.sol";
import {DemoDeposit} from "../src/testnet/DemoDeposit.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

/// @notice Runs against a fork of Base Sepolia: the real Morpho Blue contract, a market we create on it,
/// and a lender wallet delegated with a real EIP-7702 authorization.
/// Run with: BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-contract MorphoFork
contract ErrandMorphoWalletMorphoForkTest is Test {
    IMorpho constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    /// @dev Reactive Omni callback proxy on Base Sepolia (docs: Origins & Destinations).
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant LENDER_KEY = 0xA11CE;

    address lender;
    address borrower = makeAddr("borrower");
    address errandOnReactive = makeAddr("errand on Reactive Network");
    TestToken loan;
    TestToken collateral;
    MarketParams params;
    bytes32 marketId;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        loan = new TestToken("Test USD", "tUSD");
        collateral = new TestToken("Test ETH", "tETH");
        params = MarketParams(address(loan), address(collateral), address(new FixedPriceOracle()), address(0), 0.86e18);
        marketId = keccak256(abi.encode(params));
        MORPHO.createMarket(params);

        lender = vm.addr(LENDER_KEY);
        _delegateLenderTo(errandOnReactive);

        // The lender supplies 100 tUSD; a borrower takes all of it: the market is 100% borrowed.
        loan.mint(lender, 100 ether);
        vm.startPrank(lender);
        loan.approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(params, 100 ether, 0, lender, "");
        vm.stopPrank();

        collateral.mint(borrower, 200 ether);
        loan.mint(borrower, 1_000 ether);
        vm.startPrank(borrower);
        collateral.approve(address(MORPHO), type(uint256).max);
        loan.approve(address(MORPHO), type(uint256).max);
        MORPHO.supplyCollateral(params, 200 ether, borrower, "");
        MORPHO.borrow(params, 100 ether, 0, borrower, borrower);
        vm.stopPrank();
    }

    modifier onlyForked() {
        vm.skip(!forked);
        _;
    }

    function _delegateLenderTo(address errand) internal returns (ErrandMorphoWallet impl) {
        impl = new ErrandMorphoWallet(IPayable(payable(PROXY)), errand, MORPHO, params, 0.001 ether);
        vm.signAndAttachDelegation(address(impl), LENDER_KEY);
        (bool ok,) = lender.call(""); // the authorization takes effect with this transaction
        assertTrue(ok);
    }

    function _repay(uint256 assets) internal {
        vm.prank(borrower);
        MORPHO.repay(params, assets, 0, borrower, "");
    }

    function _shares() internal view returns (uint256 s) {
        (s,,) = MORPHO.position(marketId, lender);
    }

    function _exit() internal {
        vm.prank(PROXY);
        ErrandMorphoWallet(payable(lender)).exitMorpho(errandOnReactive);
    }

    function test_theProblem_lenderCannotWithdrawFromAFullyBorrowedMarket() public onlyForked {
        vm.prank(lender);
        vm.expectRevert(bytes("insufficient liquidity"));
        MORPHO.withdraw(params, 1 ether, 0, lender, lender);
    }

    function test_walletIsDelegatedAndKnowsItsMarket() public onlyForked {
        assertEq(lender.code.length, 23, "0xef0100 || implementation");
        assertEq(ErrandMorphoWallet(payable(lender)).MARKET_ID(), marketId);
    }

    function test_errandTakesWhatARepayFreedAndKeepsTheRestIn() public onlyForked {
        _repay(30 ether);
        uint256 sharesBefore = _shares();
        vm.recordLogs();
        _exit();
        assertEq(loan.balanceOf(lender), 30 ether, "all of the freed liquidity");
        assertGt(_shares(), 0);
        assertLt(_shares(), sharesBefore);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory progress = logs[logs.length - 1];
        assertEq(progress.emitter, lender);
        assertEq(progress.topics[0], keccak256("ExitProgress(bytes32,uint256,uint256)"));
        (uint256 withdrawn, uint256 remaining) = abi.decode(progress.data, (uint256, uint256));
        assertEq(withdrawn, 30 ether);
        assertEq(remaining, _shares());
    }

    function test_errandTakesEverythingOnceItFits() public onlyForked {
        _repay(100 ether);
        _exit();
        assertEq(loan.balanceOf(lender), 100 ether);
        assertEq(_shares(), 0, "no dust left in the market");
    }

    function test_nothingFreeMeansAnEmptyAttemptNotARevert() public onlyForked {
        _exit();
        assertEq(loan.balanceOf(lender), 0);
        assertEq(_shares(), 100 ether * 1e6, "position untouched");
    }

    function test_onlyTheProxyAndOnlyOurErrand() public onlyForked {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ErrandMorphoWallet.NotCallbackProxy.selector, attacker));
        ErrandMorphoWallet(payable(lender)).exitMorpho(errandOnReactive);

        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(ErrandMorphoWallet.NotMyErrand.selector, attacker, errandOnReactive));
        ErrandMorphoWallet(payable(lender)).exitMorpho(attacker);
    }

    function test_onlyTheWalletCanAskToExit() public onlyForked {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ErrandMorphoWallet.NotWallet.selector, attacker));
        ErrandMorphoWallet(payable(lender)).requestExit();

        vm.expectEmit(true, false, false, false, lender);
        emit ErrandMorphoWallet.ExitRequested(marketId);
        vm.prank(lender);
        ErrandMorphoWallet(payable(lender)).requestExit();
    }

    /// @notice The whole loop with the real Reactive contract: the wallet's real ExitRequested log and
    /// Morpho's real Repay log go into ErrandMorpho, and the callback it requests is delivered by the proxy
    /// (sender injected the way the network does it). Also proves our topic constants match Morpho's logs.
    function test_fullLoop_realMorphoEventsDriveTheExit() public onlyForked {
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        ErrandMorpho errand = new ErrandMorpho(lender, block.chainid, address(MORPHO), marketId);
        _delegateLenderTo(address(errand));

        vm.recordLogs();
        vm.prank(lender);
        ErrandMorphoWallet(payable(lender)).requestExit();
        _feed(errand, vm.getRecordedLogs());
        assertTrue(errand.armed());
        _deliver(errand, 0); // nothing free yet: empty attempt
        assertEq(loan.balanceOf(lender), 0);

        vm.recordLogs();
        _repay(40 ether);
        _feed(errand, vm.getRecordedLogs()); // Morpho's real Repay event
        assertEq(MockSystem(payable(SYSTEM)).callbackCount(), 2);
        vm.recordLogs();
        _deliver(errand, 1);
        assertEq(loan.balanceOf(lender), 40 ether);
        _feed(errand, vm.getRecordedLogs()); // the wallet's ExitProgress: still in, stays armed
        assertTrue(errand.armed());

        vm.recordLogs();
        _repay(60 ether);
        _feed(errand, vm.getRecordedLogs());
        vm.recordLogs();
        _deliver(errand, 2);
        _feed(errand, vm.getRecordedLogs()); // ExitProgress with 0 shares left: errand stands down
        assertEq(loan.balanceOf(lender), 100 ether);
        assertFalse(errand.armed());
    }

    function _feed(ErrandMorpho errand, Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            IReactive.LogRecord memory r;
            r.chainId = block.chainid;
            r.contractAddress = l.emitter;
            r.topic0 = uint256(l.topics[0]);
            if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
            if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
            if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
            r.data = l.data;
            r.opCode = l.topics.length;
            vm.prank(SYSTEM);
            errand.react(r);
        }
    }

    function _deliver(ErrandMorpho errand, uint256 i) internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = MockSystem(payable(SYSTEM)).callbackAt(i);
        assertEq(cb.recipient, lender);
        bytes memory payload = cb.payload;
        address sender = address(errand);
        assembly {
            // The network overwrites the first argument (bytes 4..36) with the requesting contract.
            mstore(add(payload, 36), sender)
        }
        vm.prank(PROXY);
        (bool delivered,) = lender.call{gas: cb.gasLimit}(payload);
        assertTrue(delivered);
    }

    /// @notice The demo page's one-click deposit: a visitor's deposit is a Supply on their behalf,
    /// which frees liquidity that the errand then withdraws for the lender.
    function test_demoDepositFreesLiquidityTheErrandTakes() public onlyForked {
        DemoDeposit demo = new DemoDeposit(MORPHO, params);
        address visitor = makeAddr("visitor");
        vm.recordLogs();
        vm.prank(visitor);
        demo.deposit(10 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 supplyTopic = keccak256("Supply(bytes32,address,address,uint256,uint256)");
        Vm.Log memory supply;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(MORPHO) && logs[i].topics[0] == supplyTopic) supply = logs[i];
        }
        assertEq(supply.emitter, address(MORPHO), "Morpho emitted a Supply");
        assertEq(supply.topics[1], marketId);
        assertEq(supply.topics[3], bytes32(uint256(uint160(visitor))), "the deposit is on the visitor's behalf");
        (uint256 visitorShares,,) = MORPHO.position(marketId, visitor);
        assertGt(visitorShares, 0);

        _exit();
        assertEq(loan.balanceOf(lender), 10 ether, "the lender got out exactly what the visitor freed");

        vm.expectRevert(abi.encodeWithSelector(DemoDeposit.AmountOutOfRange.selector, 51 ether));
        demo.deposit(51 ether);
    }
}
