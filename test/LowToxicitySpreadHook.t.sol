// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LowToxicitySpreadHook} from "../src/LowToxicitySpreadHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SessionFeeSchedule} from "../src/SessionFeeSchedule.sol";
import {NyseCalendar} from "../src/NyseCalendar.sol";
import {PoolFixture, T} from "./StockFeeHooks.t.sol";

contract LowToxicitySpreadHookTest is PoolFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    LowToxicitySpreadHook hook;
    PoolKey key;
    PoolId id;

    uint24 constant BASE = 200; // 2 bps
    uint32 constant HALF_LIFE = 15;
    uint24 constant MAX = 6000; // 60 bps

    function params() internal pure returns (LowToxicitySpreadHook.SpreadParams memory) {
        return LowToxicitySpreadHook.SpreadParams({spreadShareBps: 10_000, halfLife: HALF_LIFE, maxFee: MAX});
    }

    // 2 bps base, 12 bps open, 10 bps close, no opening auction
    function spreadSchedule() internal pure returns (SessionFeeSchedule.Schedule memory s) {
        s = schedule();
        s.baseFee = BASE;
        s.auctionStartFee = 0;
        s.auctionHalfLife = 0;
    }

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function ctorArgs(LowToxicitySpreadHook.SpreadParams memory p) internal view returns (bytes memory) {
        return abi.encode(
            manager, spreadSchedule(), p, NyseCalendar.holidays2026to2027(), NyseCalendar.earlyCloses2026to2027()
        );
    }

    function deploy(LowToxicitySpreadHook.SpreadParams memory p, bytes32 salt)
        internal
        returns (LowToxicitySpreadHook)
    {
        return new LowToxicitySpreadHook{salt: salt}(
            manager, spreadSchedule(), p, NyseCalendar.holidays2026to2027(), NyseCalendar.earlyCloses2026to2027()
        );
    }

    function setUp() public {
        deployPoolInfra();
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(LowToxicitySpreadHook).creationCode, ctorArgs(params()));
        hook = deploy(params(), salt);
        assertEq(address(hook), addr);
        key = makeKey(address(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        id = key.toId();
        vm.warp(T.OCT7_0930_EDT - 2 hours); // pre-market: the schedule's base fee
        seed(key);
    }

    function tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    /// Exact-in swap of `amount`; returns the LP fee from the PoolManager's Swap event.
    function swapBig(bool zeroForOne, int256 amount) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    function test_quietPoolPaysBase() public {
        assertEq(swapFee(key, true), BASE);
        vm.warp(block.timestamp + 10 * HALF_LIFE);
        assertEq(swapFee(key, false), BASE);
    }

    function test_reversalPaysTheSpreadTheMoveOpened() public {
        int24 t0 = tick();
        swapBig(false, 1e21); // buy currency0: price up, the ask follows, the bid stays at t0
        int24 moved = tick() - t0;
        assertGt(moved, 10, "the swap moved the price");
        (int24 bid, int24 ask) = hook.currentQuote(id, tick());
        assertEq(bid, t0);
        assertEq(ask, tick());
        assertEq(hook.quoteFee(key, false), BASE, "continuing up pays base");
        assertEq(hook.quoteFee(key, true), BASE + uint24(moved) * 100, "reversing pays base + gap");
        assertEq(swapFee(key, true), BASE + uint24(moved) * 100, "charged by the PoolManager");
    }

    function test_spreadDecaysWithHalfLife() public {
        int24 t0 = tick();
        swapBig(false, 1e21);
        uint256 gap = uint256(int256(tick() - t0));
        vm.warp(block.timestamp + HALF_LIFE);
        assertEq(hook.quoteFee(key, true), BASE + uint24(gap / 2) * 100, "one half-life");
        vm.warp(block.timestamp + 30 * HALF_LIFE);
        assertEq(hook.quoteFee(key, true), BASE, "fully decayed");
    }

    function test_sandwichBackLegPaysTheSpread() public {
        // same block: front-run up, then sell back, the back leg pays the gap it opened
        int24 t0 = tick();
        swapBig(false, 5e20);
        uint24 gapFee = uint24(uint256(int256(tick() - t0))) * 100;
        assertEq(swapBig(true, 5e20), BASE + gapFee);
    }

    function test_spreadSitsOnTopOfTheOpenAndCloseSurcharge() public {
        vm.warp(T.OCT7_0930_EDT + 10 minutes);
        assertEq(swapFee(key, true), 1200, "quiet pool at the open pays the open fee");
        vm.warp(block.timestamp + 30 * HALF_LIFE);
        int24 t0 = tick();
        swapBig(false, 1e21);
        uint24 gapFee = uint24(uint256(int256(tick() - t0))) * 100;
        assertEq(hook.quoteFee(key, false), 1200, "continuing pays the open fee");
        assertEq(hook.quoteFee(key, true), 1200 + gapFee, "reversing pays open fee + gap");
        vm.warp(T.OCT7_0930_EDT + 6 hours + 15 minutes);
        assertEq(hook.quoteFee(key, true), 1000, "close surcharge once the spread has decayed");
    }

    function test_feeIsCapped() public {
        swapBig(false, 2e22);
        assertEq(hook.quoteFee(key, true), MAX);
    }

    function test_rejectsStaticFeePool() public {
        vm.expectRevert();
        manager.initialize(makeKey(address(hook), 500), TickMath.getSqrtPriceAtTick(0));
    }

    function test_badParamsRevert() public {
        LowToxicitySpreadHook.SpreadParams memory p = params();
        p.halfLife = 0;
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(LowToxicitySpreadHook).creationCode, ctorArgs(p));
        vm.expectRevert(LowToxicitySpreadHook.BadParams.selector);
        deploy(p, salt);
    }

    function test_onlyPoolManagerCanCall() public {
        vm.expectRevert();
        hook.beforeSwap(address(this), key, IPoolManager.SwapParams(true, -1, 0), "");
        vm.expectRevert();
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function testFuzz_feeWithinBounds(uint96 amount, bool up, uint16 wait) public {
        amount = uint96(bound(amount, 1e15, 5e21));
        swapBig(up, int256(uint256(amount)));
        vm.warp(block.timestamp + wait);
        for (uint256 i; i < 2; ++i) {
            uint24 f = hook.quoteFee(key, i == 0);
            assertGe(f, BASE);
            assertLe(f, MAX);
        }
    }
}
