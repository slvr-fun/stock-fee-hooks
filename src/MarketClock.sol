// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MarketClock
/// @notice New York trading-session clock for stock-token hooks, computed from `block.timestamp`.
/// @dev US daylight saving (second Sunday of March 02:00 local to first Sunday of November 02:00 local)
///      is derived on-chain, so the clock needs no keeper. Exchange holidays and early-close days are
///      fixed at construction and can never change, which keeps the hook free of admin keys. Weekdays
///      not listed as holidays are treated as trading days, so a deployment must ship the calendar for
///      every year it is expected to run.

/// @title CivilDate
/// @notice Proleptic Gregorian date math (Howard Hinnant's algorithms), valid for dates from 1970-03-01.
library CivilDate {
    /// @dev Howard Hinnant's days_from_civil, restricted to dates on or after 1970-03-01.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// @dev Inverse of daysFromCivil.
    function civilFromDays(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
}

abstract contract MarketClock {
    uint256 internal constant DAY = 86_400;
    uint256 internal constant HOUR = 3_600;
    /// @notice Regular session open (09:30 ET) and close (16:00 ET), seconds after local midnight.
    uint256 public constant OPEN_SECS = 9 * HOUR + 30 * 60;
    uint256 public constant CLOSE_SECS = 16 * HOUR;
    /// @notice Early-close days end the regular session at 13:00 ET.
    uint256 public constant EARLY_CLOSE_SECS = 13 * HOUR;

    enum DayKind {
        Closed, // weekend or exchange holiday
        Full,
        EarlyClose
    }

    /// @dev ET calendar day number (days since 1970-01-01 in New York time) => kind override.
    mapping(uint256 => DayKind) private _override;
    mapping(uint256 => bool) private _hasOverride;

    error BadCalendarDay(uint256 etDay);

    /// @param holidays ET day numbers on which the exchange is closed all day.
    /// @param earlyCloses ET day numbers on which the regular session ends at 13:00 ET.
    constructor(uint32[] memory holidays, uint32[] memory earlyCloses) {
        for (uint256 i; i < holidays.length; ++i) {
            _setOverride(holidays[i], DayKind.Closed);
        }
        for (uint256 i; i < earlyCloses.length; ++i) {
            _setOverride(earlyCloses[i], DayKind.EarlyClose);
        }
    }

    function _setOverride(uint256 etDay, DayKind kind) private {
        if (_hasOverride[etDay]) revert BadCalendarDay(etDay);
        _hasOverride[etDay] = true;
        _override[etDay] = kind;
    }

    /// @notice The session state at `ts`.
    /// @return kind Whether the ET calendar day is closed, a full session or an early close.
    /// @return secs Seconds since local midnight in New York.
    /// @return closeSecs The regular-session close for that day (0 when closed).
    function sessionAt(uint256 ts) public view returns (DayKind kind, uint256 secs, uint256 closeSecs) {
        uint256 local = ts - (isDaylightSaving(ts) ? 4 * HOUR : 5 * HOUR);
        uint256 etDay = local / DAY;
        secs = local % DAY;
        uint256 weekday = (etDay + 4) % 7; // 0 = Sunday, 6 = Saturday
        if (weekday == 0 || weekday == 6) return (DayKind.Closed, secs, 0);
        kind = _hasOverride[etDay] ? _override[etDay] : DayKind.Full;
        closeSecs = kind == DayKind.Full ? CLOSE_SECS : kind == DayKind.EarlyClose ? EARLY_CLOSE_SECS : 0;
    }

    /// @notice True when US Eastern daylight saving time is in effect at UTC timestamp `ts`.
    function isDaylightSaving(uint256 ts) public pure returns (bool) {
        (uint256 year,,) = CivilDate.civilFromDays(ts / DAY);
        // DST starts at 02:00 EST (07:00 UTC) on the second Sunday of March
        // and ends at 02:00 EDT (06:00 UTC) on the first Sunday of November.
        uint256 start = (_nthSunday(year, 3, 2)) * DAY + 7 * HOUR;
        uint256 end = (_nthSunday(year, 11, 1)) * DAY + 6 * HOUR;
        return ts >= start && ts < end;
    }

    /// @notice ET calendar day number for a civil date, for building holiday lists.
    function etDayNumber(uint256 year, uint256 month, uint256 day) public pure returns (uint256) {
        return CivilDate.daysFromCivil(year, month, day);
    }

    function _nthSunday(uint256 year, uint256 month, uint256 n) private pure returns (uint256) {
        uint256 first = CivilDate.daysFromCivil(year, month, 1);
        uint256 weekday = (first + 4) % 7;
        return first + (7 - weekday) % 7 + 7 * (n - 1);
    }
}
