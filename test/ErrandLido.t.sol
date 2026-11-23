// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {ErrandLido} from "../src/ErrandLido.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

contract ErrandLidoTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    uint256 constant TRANSFER = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint256 constant FINALIZED = 0x197874c72af6a06fb0aa4fab45fd39c7cb61ac0992159872dc3295207da7e9eb;
    uint256 constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    address wallet = makeAddr("wallet");
    address stranger = makeAddr("stranger");
    MockSystem sys;
    ErrandLido errand;

    function setUp() public {
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        sys = MockSystem(payable(SYSTEM));
        errand = new ErrandLido(wallet, 1, QUEUE, 142_161);
    }

    // ---- helpers ----

    function _transfer(address from, address to, uint256 id) internal pure returns (IReactive.LogRecord memory r) {
        r.chainId = 1;
        r.contractAddress = QUEUE;
        r.topic0 = TRANSFER;
        r.topic1 = uint256(uint160(from));
        r.topic2 = uint256(uint160(to));
        r.topic3 = id;
        r.opCode = 4;
        r.txHash = 0xabc;
    }

    function _finalized(uint256 fromId, uint256 toId) internal pure returns (IReactive.LogRecord memory r) {
        r.chainId = 1;
        r.contractAddress = QUEUE;
        r.topic0 = FINALIZED;
        r.topic1 = fromId;
        r.topic2 = toId;
        r.data = abi.encode(uint256(1 ether), uint256(1 ether), uint256(1_800_000_000));
        r.opCode = 3;
        r.txHash = 0xdef;
    }

    function _react(IReactive.LogRecord memory r) internal {
        vm.prank(SYSTEM);
        errand.react(r);
    }

    function _idsInCallback(uint256 i) internal view returns (uint256[] memory ids, address injected) {
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(i);
        bytes memory payload = cb.payload;
        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        assertEq(selector, bytes4(keccak256("claimLido(address,uint256[])")));
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 k; k < args.length; ++k) {
            args[k] = payload[k + 4];
        }
        (injected, ids) = abi.decode(args, (address, uint256[]));
    }

    // ---- tests ----

    function test_subscribesToTheWalletsRequestsAndToFinalization() public view {
        assertEq(sys.subscriptionCount(), 3);
        uint256 w = uint256(uint160(wallet));
        (address s0, uint256 c0, address a0, uint256 t00, uint256 t01, uint256 t02, uint256 t03) = sys.subscriptions(0);
        assertEq(s0, address(errand));
        assertEq(c0, 1);
        assertEq(a0, QUEUE);
        assertEq(t00, TRANSFER);
        assertEq(t01, IGNORE);
        assertEq(t02, w); // to = wallet
        assertEq(t03, IGNORE);
        (,,, uint256 t10, uint256 t11, uint256 t12,) = sys.subscriptions(1);
        assertEq(t10, TRANSFER);
        assertEq(t11, w); // from = wallet
        assertEq(t12, IGNORE);
        (,,, uint256 t20, uint256 t21,,) = sys.subscriptions(2);
        assertEq(t20, FINALIZED);
        assertEq(t21, IGNORE);
    }

    function test_newRequestIsTrackedAndClaimedWhenLidoFinalizesIt() public {
        _react(_transfer(address(0), wallet, 142_300)); // request minted to the wallet
        assertEq(errand.tracked().length, 1);
        assertEq(sys.callbackCount(), 0, "not finalized yet, nothing to do");

        _react(_finalized(142_162, 142_299)); // finalization that stops short of our id
        assertEq(sys.callbackCount(), 0);

        _react(_finalized(142_300, 142_350));
        assertEq(sys.callbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(0);
        assertEq(cb.chainId, 1);
        assertEq(cb.recipient, wallet);
        assertGe(cb.gasLimit, 400_000);
        (uint256[] memory ids, address injected) = _idsInCallback(0);
        assertEq(injected, address(0), "first argument is reserved for the network to inject the sender");
        assertEq(ids.length, 1);
        assertEq(ids[0], 142_300);
        assertEq(errand.lastFinalizedId(), 142_350);
        assertEq(errand.errandsSent(), 1);
    }

    function test_claimedRequestStopsBeingTracked() public {
        _react(_transfer(address(0), wallet, 142_300));
        _react(_finalized(142_300, 142_350));
        _react(_transfer(wallet, address(0), 142_300)); // claim burns the NFT
        assertEq(errand.tracked().length, 0);
        _react(_finalized(142_351, 142_400));
        assertEq(sys.callbackCount(), 1, "no second errand once claimed");
    }

    function test_failedClaimIsRetriedOnTheNextFinalization() public {
        _react(_transfer(address(0), wallet, 142_300));
        _react(_finalized(142_300, 142_350));
        // callback failed on Ethereum: no burn arrives, so the id stays tracked
        _react(_finalized(142_351, 142_400));
        assertEq(sys.callbackCount(), 2);
        (uint256[] memory ids,) = _idsInCallback(1);
        assertEq(ids[0], 142_300);
    }

    function test_requestTransferredInThatIsAlreadyFinalizedIsClaimedRightAway() public {
        _react(_transfer(stranger, wallet, 142_100)); // finalized before (lastFinalizedId = 142_161)
        assertEq(sys.callbackCount(), 1);
        (uint256[] memory ids,) = _idsInCallback(0);
        assertEq(ids[0], 142_100);
    }

    function test_requestTransferredAwayIsDropped() public {
        _react(_transfer(address(0), wallet, 142_300));
        _react(_transfer(wallet, stranger, 142_300));
        assertEq(errand.tracked().length, 0);
        _react(_finalized(142_300, 142_350));
        assertEq(sys.callbackCount(), 0);
    }

    function test_idsAreSentAscendingAndOnlyFinalizedOnes() public {
        _react(_transfer(address(0), wallet, 142_330));
        _react(_transfer(address(0), wallet, 142_310));
        _react(_transfer(address(0), wallet, 142_500)); // not finalized by the event below
        _react(_transfer(address(0), wallet, 142_320));
        _react(_finalized(142_300, 142_350));
        (uint256[] memory ids,) = _idsInCallback(0);
        assertEq(ids.length, 3);
        assertEq(ids[0], 142_310);
        assertEq(ids[1], 142_320);
        assertEq(ids[2], 142_330);
    }

    function test_batchIsCapped() public {
        for (uint256 i; i < 25; ++i) {
            _react(_transfer(address(0), wallet, 142_300 + i));
        }
        _react(_finalized(142_300, 142_400));
        (uint256[] memory ids,) = _idsInCallback(0);
        assertEq(ids.length, errand.MAX_BATCH());
    }

    function test_ignoresOtherChainsContractsAndWallets() public {
        IReactive.LogRecord memory r = _transfer(address(0), wallet, 142_300);
        r.chainId = 8453;
        _react(r);
        r = _transfer(address(0), wallet, 142_301);
        r.contractAddress = stranger;
        _react(r);
        _react(_transfer(address(0), stranger, 142_302)); // someone else's request
        assertEq(errand.tracked().length, 0);
    }

    function test_onlyTheSystemContractCanCallReact() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM));
        errand.react(_finalized(1, 2));
    }

    function test_ownerCanTrackExistingRequestsAndRetry() public {
        uint256[] memory existing = new uint256[](2);
        existing[0] = 142_150;
        existing[1] = 142_160;
        errand.trackExisting(existing);
        errand.claimNow();
        assertEq(sys.callbackCount(), 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrandLido.NotOwner.selector, stranger));
        errand.trackExisting(existing);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrandLido.NotOwner.selector, stranger));
        errand.claimNow();
    }

    function test_rejectsZeroAddresses() public {
        vm.expectRevert(ErrandLido.ZeroAddress.selector);
        new ErrandLido(address(0), 1, QUEUE, 0);
    }
}
