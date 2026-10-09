// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {MarketClock} from "./MarketClock.sol";

/// @title SessionFeeSchedule
/// @notice A fee schedule keyed to the New York trading clock.
///         Design 1 ("Opening Bell"): a surcharge in the first and last minutes of the regular session.
///         Design 2 ("opening auction"): at 09:30:00 ET the fee starts at `auctionStartFee` and halves every
///         `auctionHalfLife` seconds until it reaches the open surcharge, so the opening price jump is sold
///         to arbitrageurs by Dutch auction instead of at the base fee.
/// @dev Fees are in hundredths of a basis point (pips), the unit Uniswap v4 uses: 500 = 5 bps.
///      All parameters are immutable.
abstract contract SessionFeeSchedule is MarketClock {
    struct Schedule {
        uint24 baseFee; // every hour not covered below, including weekends and holidays
        uint24 openFee; // from 09:30 ET for `openWindow` seconds
        uint24 closeFee; // the last `closeWindow` seconds before the regular close
        uint32 openWindow;
        uint32 closeWindow;
        uint24 auctionStartFee; // 0 disables the opening auction
        uint32 auctionHalfLife; // seconds per halving of the auction fee
    }

    uint24 public immutable baseFee;
    uint24 public immutable openFee;
    uint24 public immutable closeFee;
    uint32 public immutable openWindow;
    uint32 public immutable closeWindow;
    uint24 public immutable auctionStartFee;
    uint32 public immutable auctionHalfLife;

    error BadSchedule();

    constructor(Schedule memory s, uint32[] memory holidays, uint32[] memory earlyCloses)
        MarketClock(holidays, earlyCloses)
    {
        if (
            s.baseFee > LPFeeLibrary.MAX_LP_FEE || s.openFee > LPFeeLibrary.MAX_LP_FEE
                || s.closeFee > LPFeeLibrary.MAX_LP_FEE || s.auctionStartFee > LPFeeLibrary.MAX_LP_FEE
                || s.openWindow > 3 * HOUR || s.closeWindow > 3 * HOUR
                || (s.auctionStartFee != 0 && s.auctionHalfLife == 0)
        ) revert BadSchedule();
        baseFee = s.baseFee;
        openFee = s.openFee;
        closeFee = s.closeFee;
        openWindow = s.openWindow;
        closeWindow = s.closeWindow;
        auctionStartFee = s.auctionStartFee;
        auctionHalfLife = s.auctionHalfLife;
    }

    /// @notice The scheduled LP fee at UTC timestamp `ts`, in pips.
    function scheduleFee(uint256 ts) public view returns (uint24 fee) {
        (DayKind kind, uint256 secs, uint256 close) = sessionAt(ts);
        if (kind == DayKind.Closed) return baseFee;
        if (secs >= OPEN_SECS && secs < OPEN_SECS + openWindow) {
            fee = openFee;
            if (auctionStartFee > fee) {
                uint256 halvings = (secs - OPEN_SECS) / auctionHalfLife;
                uint256 auction = halvings >= 24 ? 0 : uint256(auctionStartFee) >> halvings;
                if (auction > fee) fee = uint24(auction);
            }
            return fee;
        }
        if (secs < close && secs + closeWindow >= close) return closeFee;
        return baseFee;
    }
}
