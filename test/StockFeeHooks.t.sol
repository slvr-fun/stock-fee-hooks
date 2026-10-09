// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MarketClock} from "../src/MarketClock.sol";
import {SessionFeeSchedule} from "../src/SessionFeeSchedule.sol";
import {NyseCalendar} from "../src/NyseCalendar.sol";
import {OpeningBellFeeHook} from "../src/OpeningBellFeeHook.sol";
import {OracleDirectionalFeeHook} from "../src/OracleDirectionalFeeHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract ScheduleHarness is SessionFeeSchedule {
    constructor(Schedule memory s, uint32[] memory h, uint32[] memory e) SessionFeeSchedule(s, h, e) {}
}

/// Fixed UTC timestamps, computed independently of the contract under test.
library T {
    uint256 constant OCT7_0930_EDT = 1_791_379_800; // Wed 2026-10-07 13:30:00 UTC
    uint256 constant DST_START_2026 = 1_772_953_200; // 2026-03-08 07:00:00 UTC
    uint256 constant DST_END_2026 = 1_793_512_800; // 2026-11-01 06:00:00 UTC
    uint256 constant NOV2_0930_EST = 1_793_629_800; // Mon 2026-11-02 14:30:00 UTC
    uint256 constant OCT10_0930_SAT = 1_791_639_000; // Sat 2026-10-10 13:30:00 UTC
    uint256 constant THANKSGIVING_0930 = 1_795_703_400; // Thu 2026-11-26 14:30:00 UTC
    uint256 constant NOV27_1230_EST = 1_795_800_600; // early-close day, 12:30 ET
    uint256 constant NOV27_1300_EST = 1_795_802_400; // early-close day, 13:00 ET
    uint256 constant DST_START_2027 = 1_805_007_600; // 2027-03-14 07:00:00 UTC
}

abstract contract Fixture is Test {
    // 5 bps base, 12 bps open, 10 bps close, 30-minute windows, opening auction from 60 bps halving every 30 s.
    function schedule() internal pure returns (SessionFeeSchedule.Schedule memory) {
        return SessionFeeSchedule.Schedule({
            baseFee: 500,
            openFee: 1200,
            closeFee: 1000,
            openWindow: 30 minutes,
            closeWindow: 30 minutes,
            auctionStartFee: 6000,
            auctionHalfLife: 30
        });
    }
}

contract MarketClockTest is Fixture {
    ScheduleHarness h;

    function setUp() public {
        h = new ScheduleHarness(schedule(), NyseCalendar.holidays2026to2027(), NyseCalendar.earlyCloses2026to2027());
    }

    function test_daylightSavingBoundaries() public view {
        assertFalse(h.isDaylightSaving(T.DST_START_2026 - 1));
        assertTrue(h.isDaylightSaving(T.DST_START_2026));
        assertTrue(h.isDaylightSaving(T.DST_END_2026 - 1));
        assertFalse(h.isDaylightSaving(T.DST_END_2026));
        assertFalse(h.isDaylightSaving(T.DST_START_2027 - 1));
        assertTrue(h.isDaylightSaving(T.DST_START_2027));
    }

    function test_openIsNineThirtyInBothOffsets() public view {
        (MarketClock.DayKind k1, uint256 s1, uint256 c1) = h.sessionAt(T.OCT7_0930_EDT);
        assertEq(uint8(k1), uint8(MarketClock.DayKind.Full));
        assertEq(s1, 9 hours + 30 minutes);
        assertEq(c1, 16 hours);
        (MarketClock.DayKind k2, uint256 s2,) = h.sessionAt(T.NOV2_0930_EST);
        assertEq(uint8(k2), uint8(MarketClock.DayKind.Full));
        assertEq(s2, 9 hours + 30 minutes);
    }

    function test_weekendHolidayEarlyClose() public view {
        (MarketClock.DayKind k,,) = h.sessionAt(T.OCT10_0930_SAT);
        assertEq(uint8(k), uint8(MarketClock.DayKind.Closed));
        (k,,) = h.sessionAt(T.THANKSGIVING_0930);
        assertEq(uint8(k), uint8(MarketClock.DayKind.Closed));
        uint256 close;
        (k,, close) = h.sessionAt(T.NOV27_1230_EST);
        assertEq(uint8(k), uint8(MarketClock.DayKind.EarlyClose));
        assertEq(close, 13 hours);
    }

    function test_duplicateCalendarDayReverts() public {
        uint32[] memory hol = new uint32[](2);
        hol[0] = 20_783;
        hol[1] = 20_783;
        vm.expectRevert(abi.encodeWithSelector(MarketClock.BadCalendarDay.selector, uint256(20_783)));
        new ScheduleHarness(schedule(), hol, new uint32[](0));
    }

    function test_openingAuctionDecaysToOpenFee() public view {
        uint256 t = T.OCT7_0930_EDT;
        assertEq(h.scheduleFee(t - 1), 500, "pre-market");
        assertEq(h.scheduleFee(t), 6000, "09:30:00");
        assertEq(h.scheduleFee(t + 29), 6000);
        assertEq(h.scheduleFee(t + 30), 3000, "09:30:30");
        assertEq(h.scheduleFee(t + 60), 1500, "09:31:00");
        assertEq(h.scheduleFee(t + 90), 1200, "auction below floor -> open fee");
        assertEq(h.scheduleFee(t + 30 minutes - 1), 1200, "09:59:59");
        assertEq(h.scheduleFee(t + 30 minutes), 500, "10:00:00");
    }

    function test_closeWindow() public view {
        uint256 open = T.OCT7_0930_EDT;
        uint256 close = open + 6 hours + 30 minutes; // 16:00 ET
        assertEq(h.scheduleFee(close - 30 minutes - 1), 500, "15:29:59");
        assertEq(h.scheduleFee(close - 30 minutes), 1000, "15:30:00");
        assertEq(h.scheduleFee(close - 1), 1000, "15:59:59");
        assertEq(h.scheduleFee(close), 500, "16:00:00");
    }

    function test_closedDaysAndEarlyCloseUseTheirOwnClock() public view {
        assertEq(h.scheduleFee(T.OCT10_0930_SAT), 500, "Saturday open is just base");
        assertEq(h.scheduleFee(T.THANKSGIVING_0930), 500, "holiday open is just base");
        assertEq(h.scheduleFee(T.NOV27_1230_EST), 1000, "12:30 on an early-close day is the close window");
        assertEq(h.scheduleFee(T.NOV27_1300_EST), 500, "after the 13:00 close");
    }

    function testFuzz_feeAlwaysWithinSchedule(uint32 ts) public view {
        uint256 t = uint256(ts) + 1_767_225_600; // 2026 onwards
        uint24 f = h.scheduleFee(t);
        assertTrue(f == 500 || f == 1000 || f == 1200 || f == 1500 || f == 3000 || f == 6000);
    }

    function test_badScheduleReverts() public {
        SessionFeeSchedule.Schedule memory s = schedule();
        s.auctionHalfLife = 0;
        vm.expectRevert(SessionFeeSchedule.BadSchedule.selector);
        new ScheduleHarness(s, new uint32[](0), new uint32[](0));
        s = schedule();
        s.openFee = uint24(LPFeeLibrary.MAX_LP_FEE + 1);
        vm.expectRevert(SessionFeeSchedule.BadSchedule.selector);
        new ScheduleHarness(s, new uint32[](0), new uint32[](0));
    }
}

/// Shared pool plumbing: real PoolManager (prebuilt artifact), test routers, two mock tokens.
abstract contract PoolFixture is Fixture {
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    Currency c0;
    Currency c1;

    function deployPoolInfra() internal {
        // deployCode, not `new`: importing the concrete PoolManager pins the build to solc 0.8.26.
        // If this reverts with "no matching artifact", run: forge build lib/v4-core/src/PoolManager.sol
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockERC20 a = new MockERC20("USD", "USDG", 18);
        MockERC20 b = new MockERC20("Stock", "NVDA", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        c0 = Currency.wrap(address(t0));
        c1 = Currency.wrap(address(t1));
        for (uint256 i; i < 2; ++i) {
            MockERC20 t = i == 0 ? t0 : t1;
            t.mint(address(this), 1e30);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(lpRouter), type(uint256).max);
        }
    }

    function makeKey(address hook, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: 1, hooks: IHooks(hook)});
    }

    function seed(PoolKey memory key) internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: 0}),
            ""
        );
    }

    /// Swap a small exact-in amount and return the LP fee the PoolManager charged, read from its Swap event.
    function swapFee(PoolKey memory key, bool zeroForOne) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e18,
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
}

contract OpeningBellFeeHookTest is PoolFixture {
    OpeningBellFeeHook hook;
    PoolKey key;

    function setUp() public {
        deployPoolInfra();
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        uint32[] memory hol = NyseCalendar.holidays2026to2027();
        uint32[] memory early = NyseCalendar.earlyCloses2026to2027();
        bytes memory args = abi.encode(manager, schedule(), hol, early);
        (address addr, bytes32 salt) = HookMiner.find(address(this), flags, type(OpeningBellFeeHook).creationCode, args);
        hook = new OpeningBellFeeHook{salt: salt}(manager, schedule(), hol, early);
        assertEq(address(hook), addr);
        key = makeKey(address(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.warp(T.OCT7_0930_EDT - 1 hours);
        seed(key);
    }

    function test_rejectsStaticFeePool() public {
        vm.expectRevert();
        manager.initialize(makeKey(address(hook), 500), TickMath.getSqrtPriceAtTick(0));
    }

    function test_swapPaysTheClockFee() public {
        vm.warp(T.OCT7_0930_EDT - 60);
        assertEq(swapFee(key, true), 500, "pre-market base");
        vm.warp(T.OCT7_0930_EDT);
        assertEq(swapFee(key, false), 6000, "opening auction");
        vm.warp(T.OCT7_0930_EDT + 45);
        assertEq(swapFee(key, true), 3000, "one halving");
        vm.warp(T.OCT7_0930_EDT + 10 minutes);
        assertEq(swapFee(key, false), 1200, "open surcharge");
        vm.warp(T.OCT7_0930_EDT + 3 hours);
        assertEq(swapFee(key, true), 500, "midday base");
        vm.warp(T.OCT7_0930_EDT + 6 hours + 15 minutes);
        assertEq(swapFee(key, false), 1000, "close surcharge");
        vm.warp(T.OCT10_0930_SAT);
        assertEq(swapFee(key, true), 500, "weekend base");
    }

    function test_onlyPoolManagerCanCall() public {
        vm.expectRevert();
        hook.beforeSwap(address(this), key, IPoolManager.SwapParams(true, -1, 0), "");
    }
}

contract OracleDirectionalFeeHookTest is PoolFixture {
    using PoolIdLibrary for PoolKey;

    OracleDirectionalFeeHook hook;
    PoolKey key;
    address keeper = makeAddr("keeper");
    address owner = makeAddr("owner");

    function oracleParams() internal pure returns (OracleDirectionalFeeHook.OracleParams memory) {
        return OracleDirectionalFeeHook.OracleParams({alphaBps: 7500, maxFee: 10_000, haltFee: 10_000, maxAge: 60});
    }

    function setUp() public {
        deployPoolInfra();
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        uint32[] memory hol = NyseCalendar.holidays2026to2027();
        uint32[] memory early = NyseCalendar.earlyCloses2026to2027();
        bytes memory args = abi.encode(manager, schedule(), oracleParams(), hol, early, owner, keeper);
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(OracleDirectionalFeeHook).creationCode, args);
        hook = new OracleDirectionalFeeHook{salt: salt}(manager, schedule(), oracleParams(), hol, early, owner, keeper);
        assertEq(address(hook), addr);
        key = makeKey(address(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.warp(T.OCT7_0930_EDT + 3 hours); // 12:30 ET, schedule fee = base 500
        seed(key);
    }

    /// Push a reference `ticks` ticks (1 tick = 1 bp) above (positive) or below the pool's starting price.
    function pushRefOffset(int24 ticks, uint8 status) internal {
        vm.prank(keeper);
        hook.pushReference(key.toId(), TickMath.getSqrtPriceAtTick(ticks), status);
    }

    function test_gapClosingSwapPaysAlphaTimesGap() public {
        pushRefOffset(20, 2); // reference ~0.20% above pool
        uint256 gap = hook.gapPips(TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(20));
        assertApproxEqAbs(gap, 2002, 2);
        // zeroForOne = false sells currency1, which raises the price toward the reference.
        assertEq(swapFee(key, false), uint24(gap * 7500 / 10_000), "toward the reference");
    }

    function test_gapWideningSwapPaysBase() public {
        pushRefOffset(20, 2);
        assertEq(swapFee(key, true), 500, "away from the reference pays the schedule fee");
    }

    function test_smallGapNeverUndercutsSchedule() public {
        pushRefOffset(2, 2); // ~2 bps gap -> 0.75 x 2 bps < 5 bps base
        assertEq(swapFee(key, false), 500);
    }

    function test_staleReferenceFallsBackToSchedule() public {
        pushRefOffset(20, 2);
        vm.warp(block.timestamp + 61);
        assertEq(swapFee(key, false), 500);
    }

    function test_haltFlagChargesHaltFee() public {
        pushRefOffset(20, hook.STATUS_HALTED());
        assertEq(swapFee(key, true), 10_000);
    }

    function test_directionalFeeIsCapped() public {
        pushRefOffset(400, 2); // ~4% gap -> 3% charge, capped at 1%
        assertEq(swapFee(key, false), 10_000);
    }

    function test_eventWindowFloor() public {
        vm.prank(keeper);
        hook.setEventWindow(key.toId(), uint40(block.timestamp), uint40(block.timestamp + 1 hours), 3000);
        assertEq(swapFee(key, true), 3000, "earnings-night floor");
        vm.warp(block.timestamp + 1 hours);
        assertEq(swapFee(key, true), 500, "window over");
    }

    function test_scheduleStillAppliesAtTheOpen() public {
        vm.warp(T.OCT7_0930_EDT + 24 hours + 10 minutes); // Thu 09:40 ET, no fresh reference
        assertEq(swapFee(key, true), 1200);
    }

    function test_accessControl() public {
        vm.expectRevert(OracleDirectionalFeeHook.NotKeeper.selector);
        hook.pushReference(key.toId(), TickMath.getSqrtPriceAtTick(0), 2);
        vm.expectRevert();
        hook.setKeeper(address(this));
        vm.prank(owner);
        hook.setKeeper(address(this));
        hook.pushReference(key.toId(), TickMath.getSqrtPriceAtTick(0), 2);
    }

    function testFuzz_gapPipsSymmetricEnough(int24 ticks) public view {
        ticks = int24(bound(int256(ticks), -5000, 5000));
        uint256 g = hook.gapPips(TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(ticks));
        uint256 expected = ticks >= 0
            ? (uint256(TickMath.getSqrtPriceAtTick(ticks)) ** 2 >> 96) * 1e6 / (1 << 96) - 1e6
            : 1e6 - (uint256(TickMath.getSqrtPriceAtTick(ticks)) ** 2 >> 96) * 1e6 / (1 << 96);
        assertApproxEqAbs(g, expected, 3);
    }
}
