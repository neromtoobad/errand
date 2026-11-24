// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {ErrandMorpho} from "../src/ErrandMorpho.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

contract ErrandMorphoTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    uint256 constant CHAIN = 84532;
    bytes32 constant MARKET = keccak256("market");
    uint256 constant REPAY = uint256(keccak256("Repay(bytes32,address,address,uint256,uint256)"));
    uint256 constant SUPPLY = uint256(keccak256("Supply(bytes32,address,address,uint256,uint256)"));
    uint256 constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    address wallet = makeAddr("wallet");
    address stranger = makeAddr("stranger");
    MockSystem sys;
    ErrandMorpho errand;

    function setUp() public {
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        sys = MockSystem(payable(SYSTEM));
        errand = new ErrandMorpho(wallet, CHAIN, MORPHO, MARKET);
    }

    // ---- helpers ----

    function _log(address emitter, uint256 topic0, uint256 topic3, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = CHAIN;
        r.contractAddress = emitter;
        r.topic0 = topic0;
        r.topic1 = uint256(MARKET);
        r.topic3 = topic3;
        r.data = data;
        r.opCode = topic3 == 0 ? 2 : 4;
        r.txHash = 0xabc;
    }

    function _repay() internal pure returns (IReactive.LogRecord memory) {
        return _log(MORPHO, REPAY, 1, abi.encode(uint256(5 ether), uint256(5e24)));
    }

    function _walletEvent(string memory sig, bytes memory data) internal view returns (IReactive.LogRecord memory) {
        return _log(wallet, uint256(keccak256(bytes(sig))), 0, data);
    }

    function _progress(uint256 withdrawn, uint256 remaining) internal view returns (IReactive.LogRecord memory) {
        return _walletEvent("ExitProgress(bytes32,uint256,uint256)", abi.encode(withdrawn, remaining));
    }

    function _react(IReactive.LogRecord memory r) internal {
        vm.prank(SYSTEM);
        errand.react(r);
    }

    // ---- tests ----

    function test_subscribesToTheMarketAndToTheWallet() public view {
        assertEq(sys.subscriptionCount(), 5);
        (, uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) = sys.subscriptions(0);
        assertEq(c, CHAIN);
        assertEq(a, MORPHO);
        assertEq(t0, REPAY);
        assertEq(t1, uint256(MARKET), "only this market's repays");
        assertEq(t2, IGNORE);
        assertEq(t3, IGNORE);
        (,, a, t0, t1,,) = sys.subscriptions(1);
        assertEq(a, MORPHO);
        assertEq(t0, SUPPLY);
        assertEq(t1, uint256(MARKET));
        for (uint256 i = 2; i < 5; ++i) {
            (,, a,, t1,,) = sys.subscriptions(i);
            assertEq(a, wallet, "the wallet's own exit events");
            assertEq(t1, uint256(MARKET));
        }
    }

    function test_doesNothingUntilTheWalletAsksToExit() public {
        _react(_repay());
        assertEq(sys.callbackCount(), 0);
        assertFalse(errand.armed());
    }

    function test_exitRequestArmsAndTriesRightAway() public {
        _react(_walletEvent("ExitRequested(bytes32)", ""));
        assertTrue(errand.armed());
        assertEq(sys.callbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(0);
        assertEq(cb.chainId, CHAIN);
        assertEq(cb.recipient, wallet);
        assertEq(cb.gasLimit, errand.CALLBACK_GAS());
        assertEq(cb.payload, abi.encodeWithSignature("exitMorpho(address)", address(0)));
    }

    function test_everyRepayOrSupplyWhileArmedSendsAnErrand() public {
        _react(_walletEvent("ExitRequested(bytes32)", ""));
        _react(_repay());
        _react(_log(MORPHO, SUPPLY, uint256(uint160(stranger)), abi.encode(uint256(1 ether), uint256(1e24))));
        assertEq(sys.callbackCount(), 3);
        assertEq(errand.errandsSent(), 3);
    }

    function test_theWalletsOwnSupplyIsNotLiquidity() public {
        _react(_walletEvent("ExitRequested(bytes32)", ""));
        _react(_log(MORPHO, SUPPLY, uint256(uint160(wallet)), abi.encode(uint256(1 ether), uint256(1e24))));
        assertEq(sys.callbackCount(), 1, "only the arming attempt");
    }

    function test_partialProgressStaysArmedAndFullExitDisarms() public {
        _react(_walletEvent("ExitRequested(bytes32)", ""));
        _react(_progress(3 ether, 7e24));
        assertTrue(errand.armed(), "still has shares in the market");
        _react(_progress(7 ether, 0));
        assertFalse(errand.armed(), "fully out");
        _react(_repay());
        assertEq(sys.callbackCount(), 1, "no errands after the exit is done");
    }

    function test_cancelDisarms() public {
        _react(_walletEvent("ExitRequested(bytes32)", ""));
        _react(_walletEvent("ExitCancelled(bytes32)", ""));
        assertFalse(errand.armed());
        _react(_repay());
        assertEq(sys.callbackCount(), 1);
    }

    function test_ignoresOtherMarketsChainsAndContracts() public {
        _react(_walletEvent("ExitRequested(bytes32)", ""));
        IReactive.LogRecord memory r = _repay();
        r.topic1 = uint256(keccak256("another market"));
        _react(r);
        r = _repay();
        r.chainId = 1;
        _react(r);
        r = _repay();
        r.contractAddress = stranger;
        _react(r);
        r = _walletEvent("ExitRequested(bytes32)", "");
        r.contractAddress = stranger; // someone else's wallet asking to exit
        _react(r);
        assertEq(sys.callbackCount(), 1);
    }

    function test_onlyTheSystemContractCanCallReact() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM));
        errand.react(_repay());
    }

    function test_onlyOwnerCanWithdrawREACT() public {
        vm.deal(address(errand), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrandMorpho.NotOwner.selector, stranger));
        errand.withdraw(1 ether);
        uint256 before = address(this).balance;
        errand.withdraw(1 ether);
        assertEq(address(this).balance - before, 1 ether);
    }

    function test_rejectsZeroAddresses() public {
        vm.expectRevert(ErrandMorpho.ZeroAddress.selector);
        new ErrandMorpho(address(0), CHAIN, MORPHO, MARKET);
    }

    receive() external payable {}
}
