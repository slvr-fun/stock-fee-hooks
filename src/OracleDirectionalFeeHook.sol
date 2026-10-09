// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "./BaseHook.sol";
import {SessionFeeSchedule} from "./SessionFeeSchedule.sol";

/// @title OracleDirectionalFeeHook
/// @notice Reference implementation of Design 3 from "The Memecoin Bots Behind NVDA's Volume". A keeper writes a reference
///         price (for example a Chainlink 24/5 US-equities report, or the perp mark while the stock market
///         is closed) into storage. A swap that moves the pool price TOWARD the reference is closing a gap,
///         which is what an arbitrageur does, and pays `alpha` of that gap as its fee. A swap that moves the
///         pool AWAY from the reference pays the session schedule fee, the same as any static pool.
/// @dev - Swaps never carry hook data: the reference lives in storage, which keeps the hook eligible for
///        Uniswap's routing review (no custom hook data, no upgradeable proxy, protocol fee untouched).
///      - When the reference is missing or older than `maxAge`, the hook falls back to the session schedule.
///        When the keeper flags a halt, every swap pays `haltFee`.
///      - The keeper may set one event window per pool (for example an earnings night) with a fee floor.
///      - The owner can rotate the keeper and nothing else. Fee parameters are immutable.
///      - The reference must be pushed in the pool's own orientation: sqrt(currency1 per currency0) in Q64.96.
///      Reference code: unaudited, written to illustrate the design.
contract OracleDirectionalFeeHook is BaseHook, SessionFeeSchedule, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Market-status codes follow Chainlink's 24/5 equities schema (0 unknown, 1 pre-market, 2 regular,
    ///         3 post-market, 4 overnight, 5 closed). The keeper uses 255 to flag a trading halt, which the
    ///         Chainlink status does not report.
    uint8 public constant STATUS_HALTED = 255;
    uint256 internal constant PIPS = 1_000_000;

    struct Reference {
        uint160 sqrtPriceX96;
        uint40 updatedAt;
        uint8 status;
    }

    struct EventWindow {
        uint40 start;
        uint40 end;
        uint24 feeFloor;
    }

    struct OracleParams {
        uint16 alphaBps; // share of the gap charged to gap-closing swaps, 7500 = 0.75
        uint24 maxFee; // cap on any directional or event fee
        uint24 haltFee; // fee while the keeper flags a halt
        uint32 maxAge; // seconds after which the reference is ignored
    }

    uint16 public immutable alphaBps;
    uint24 public immutable maxFee;
    uint24 public immutable haltFee;
    uint32 public immutable maxAge;

    address public keeper;
    mapping(PoolId => Reference) public referenceOf;
    mapping(PoolId => EventWindow) public eventWindowOf;

    event KeeperSet(address indexed keeper);
    event ReferencePushed(PoolId indexed id, uint160 sqrtPriceX96, uint8 status);
    event EventWindowSet(PoolId indexed id, uint40 start, uint40 end, uint24 feeFloor);

    error MustUseDynamicFee();
    error NotKeeper();
    error BadParams();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        IPoolManager manager,
        Schedule memory schedule,
        OracleParams memory p,
        uint32[] memory holidays,
        uint32[] memory earlyCloses,
        address owner_,
        address keeper_
    ) BaseHook(manager) SessionFeeSchedule(schedule, holidays, earlyCloses) Ownable(owner_) {
        if (
            p.alphaBps > 10_000 || p.maxFee > LPFeeLibrary.MAX_LP_FEE || p.haltFee > LPFeeLibrary.MAX_LP_FEE
                || p.maxAge == 0
        ) {
            revert BadParams();
        }
        alphaBps = p.alphaBps;
        maxFee = p.maxFee;
        haltFee = p.haltFee;
        maxAge = p.maxAge;
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    // ---------------------------------------------------------------- keeper and owner

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Write the reference price for a pool. `sqrtPriceX96` is sqrt(currency1/currency0) in Q64.96.
    function pushReference(PoolId id, uint160 sqrtPriceX96, uint8 status) external onlyKeeper {
        if (sqrtPriceX96 == 0) revert BadParams();
        referenceOf[id] = Reference(sqrtPriceX96, uint40(block.timestamp), status);
        emit ReferencePushed(id, sqrtPriceX96, status);
    }

    /// @notice Set (or clear, with end = 0) an event window with a minimum fee, for example an earnings night.
    function setEventWindow(PoolId id, uint40 start, uint40 end, uint24 feeFloor) external onlyKeeper {
        if (feeFloor > maxFee || (end != 0 && end <= start)) revert BadParams();
        eventWindowOf[id] = EventWindow(start, end, feeFloor);
        emit EventWindowSet(id, start, end, feeFloor);
    }

    // ---------------------------------------------------------------- fee logic

    /// @notice The LP fee, in pips, that a swap in direction `zeroForOne` would pay right now.
    function quoteFee(PoolKey calldata key, bool zeroForOne) public view returns (uint24 fee) {
        PoolId id = key.toId();
        fee = scheduleFee(block.timestamp);
        Reference memory r = referenceOf[id];
        bool fresh = r.updatedAt != 0 && block.timestamp - r.updatedAt <= maxAge;
        if (fresh && r.status == STATUS_HALTED) {
            fee = haltFee;
        } else if (fresh) {
            (uint160 poolSqrtP,,,) = poolManager.getSlot0(id);
            // zeroForOne sells currency0, which lowers the price (currency1 per currency0).
            bool toward = zeroForOne ? r.sqrtPriceX96 < poolSqrtP : r.sqrtPriceX96 > poolSqrtP;
            if (toward) {
                uint256 charge = gapPips(poolSqrtP, r.sqrtPriceX96) * alphaBps / 10_000;
                if (charge > maxFee) charge = maxFee;
                if (charge > fee) fee = uint24(charge);
            }
        }
        EventWindow memory w = eventWindowOf[id];
        if (w.end != 0 && block.timestamp >= w.start && block.timestamp < w.end && w.feeFloor > fee) fee = w.feeFloor;
    }

    /// @notice |reference price / pool price - 1| in pips (1e-6), capped at 100%.
    function gapPips(uint160 poolSqrtP, uint160 refSqrtP) public pure returns (uint256) {
        uint256 r = FullMath.mulDiv(refSqrtP, PIPS, poolSqrtP); // sqrt ratio, 1e6 scale
        if (r > 2 * PIPS) return PIPS;
        uint256 ratio = r * r / PIPS; // price ratio, 1e6 scale
        uint256 gap = ratio > PIPS ? ratio - PIPS : PIPS - ratio;
        return gap > PIPS ? PIPS : gap;
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

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            quoteFee(key, params.zeroForOne) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }
}
