// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "./BaseHook.sol";
import {SessionFeeSchedule} from "./SessionFeeSchedule.sol";

/// @title OpeningBellFeeHook
/// @notice Reference implementation of Designs 1 and 2 from "The Memecoin Bots Behind NVDA's Volume": a stock-token pool whose
///         LP fee rises in the first and last half hour of the NYSE regular session, optionally starting the
///         day with a decaying opening auction. No oracle, no owner, no hook data, nothing upgradeable.
/// @dev The pool must be created with `LPFeeLibrary.DYNAMIC_FEE_FLAG`. The fee is applied per swap through
///      the `beforeSwap` override, so nothing is ever written to storage on the swap path.
///      Reference code: unaudited, written to illustrate the design.
contract OpeningBellFeeHook is BaseHook, SessionFeeSchedule {
    error MustUseDynamicFee();

    constructor(IPoolManager manager, Schedule memory schedule, uint32[] memory holidays, uint32[] memory earlyCloses)
        BaseHook(manager)
        SessionFeeSchedule(schedule, holidays, earlyCloses)
    {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

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

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            scheduleFee(block.timestamp) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }
}
