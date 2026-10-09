// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "./BaseHook.sol";
import {SessionFeeSchedule} from "./SessionFeeSchedule.sol";

/// @title LowToxicitySpreadHook
/// @notice Reference implementation of Design 4 from "The Memecoin Bots Behind NVDA's Volume": a bid/ask spread
///         emulated with a dynamic fee, after the low-toxicity AMM proposed on ethresear.ch (2022). No oracle.
///
///         The pool keeps a remembered bid tick and ask tick. A swap that pushes the price up moves the ask with
///         it and leaves the bid where it was; a swap that pushes the price down does the reverse. A later swap
///         in the opposite direction pays the base fee plus the distance back to the side it is hitting, so a
///         trader who reverses a recent move pays the spread that move opened. Both sides then decay back toward
///         the pool price with a fixed half-life, so the spread is wide right after one-sided flow and tight
///         when the pool is quiet. Continuing in the same direction as the last move pays only the base fee.
///
///         The base fee under the spread comes from the same NYSE session schedule as the Opening Bell hook, so
///         the open and close surcharges (and the optional opening auction) apply with no oracle at all.
/// @dev - Fee for a swap = scheduleFee(now) + spreadShareBps/10_000 * (gap to the side it hits, in ticks) * 100
///        pips, capped at maxFee. One tick is ~1 bp, so a 7-tick gap at a 100% share adds 7 bps.
///      - A flat fee approximates the original design, which also flattens the opposite side's liquidity so a
///        large trade fills at an average of the spread. v4 positions can't be reshaped per swap, so this hook
///        charges the whole swap the gap measured at its starting price.
///      - beforeSwap writes the decayed quotes, afterSwap widens them to the new price. No owner, no keeper,
///        no hook data, protocol fee untouched. Every parameter is immutable.
///      Reference code: unaudited, written to illustrate the design.
contract LowToxicitySpreadHook is BaseHook, SessionFeeSchedule {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Quote {
        int24 bidTick;
        int24 askTick;
        uint40 updatedAt;
    }

    struct SpreadParams {
        uint16 spreadShareBps; // share of the remembered gap charged on top, 10_000 = 100%
        uint32 halfLife; // seconds for the gap to halve
        uint24 maxFee; // cap on the total fee, in pips
    }

    uint16 public immutable spreadShareBps;
    uint32 public immutable halfLife;
    uint24 public immutable maxFee;

    mapping(PoolId => Quote) public quoteOf;

    error MustUseDynamicFee();
    error BadParams();

    constructor(
        IPoolManager manager,
        Schedule memory schedule,
        SpreadParams memory p,
        uint32[] memory holidays,
        uint32[] memory earlyCloses
    ) BaseHook(manager) SessionFeeSchedule(schedule, holidays, earlyCloses) {
        if (p.halfLife == 0 || p.spreadShareBps > 10_000 || p.maxFee > LPFeeLibrary.MAX_LP_FEE) revert BadParams();
        spreadShareBps = p.spreadShareBps;
        halfLife = p.halfLife;
        maxFee = p.maxFee;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // ---------------------------------------------------------------- spread logic

    /// @notice The bid and ask ticks right now, decayed toward `tick` since the last update.
    function currentQuote(PoolId id, int24 tick) public view returns (int24 bid, int24 ask) {
        Quote memory q = quoteOf[id];
        uint256 dt = block.timestamp - q.updatedAt;
        // tick differences fit in 21 bits and decay() never grows them, so these casts cannot truncate
        bid = q.bidTick < tick ? tick - int24(int256(decay(uint256(int256(tick) - q.bidTick), dt))) : tick;
        ask = q.askTick > tick ? tick + int24(int256(decay(uint256(int256(q.askTick) - tick), dt))) : tick;
    }

    /// @notice `gap` after `dt` seconds of exponential decay: whole half-lives as shifts, linear in between.
    function decay(uint256 gap, uint256 dt) public view returns (uint256) {
        uint256 n = dt / halfLife;
        if (n >= 24) return 0;
        uint256 g = gap >> n;
        return g - g * (dt % halfLife) / (2 * uint256(halfLife));
    }

    /// @notice The LP fee, in pips, that a swap in direction `zeroForOne` would pay right now.
    function quoteFee(PoolKey calldata key, bool zeroForOne) public view returns (uint24) {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        (int24 bid, int24 ask) = currentQuote(id, tick);
        return feeFor(zeroForOne, tick, bid, ask);
    }

    function feeFor(bool zeroForOne, int24 tick, int24 bid, int24 ask) internal view returns (uint24) {
        // zeroForOne sells currency0, which lowers the price and hits the bid.
        uint256 gapTicks = zeroForOne ? uint256(int256(tick) - bid) : uint256(int256(ask) - tick);
        uint256 fee = scheduleFee(block.timestamp) + gapTicks * spreadShareBps / 100;
        return fee > maxFee ? maxFee : uint24(fee);
    }

    // ---------------------------------------------------------------- hook callbacks

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        quoteOf[key.toId()] = Quote(tick, tick, uint40(block.timestamp));
        return this.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        (int24 bid, int24 ask) = currentQuote(id, tick);
        // store the decayed quotes so afterSwap only has to widen them
        quoteOf[id] = Quote(bid, ask, uint40(block.timestamp));
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeFor(params.zeroForOne, tick, bid, ask) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        Quote storage q = quoteOf[id];
        // the side the price moved toward follows it; the other side stays where it was
        if (tick > q.askTick) q.askTick = tick;
        if (tick < q.bidTick) q.bidTick = tick;
        return (this.afterSwap.selector, 0);
    }
}
