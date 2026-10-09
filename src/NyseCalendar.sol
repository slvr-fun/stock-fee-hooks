// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CivilDate} from "./MarketClock.sol";

/// @title NyseCalendar
/// @notice NYSE full-day holidays and 13:00 ET early closes for 2026 and 2027, as ET day numbers for the
///         MarketClock constructor. Verify against the exchange's published calendar before deploying; a
///         deployment must carry every year it is expected to run.
library NyseCalendar {
    function holidays2026to2027() internal pure returns (uint32[] memory h) {
        uint16[3][20] memory d = [
            // 2026
            [uint16(2026), 1, 1], // New Year's Day
            [uint16(2026), 1, 19], // Martin Luther King Jr. Day
            [uint16(2026), 2, 16], // Washington's Birthday
            [uint16(2026), 4, 3], // Good Friday
            [uint16(2026), 5, 25], // Memorial Day
            [uint16(2026), 6, 19], // Juneteenth
            [uint16(2026), 7, 3], // Independence Day (observed)
            [uint16(2026), 9, 7], // Labor Day
            [uint16(2026), 11, 26], // Thanksgiving
            [uint16(2026), 12, 25], // Christmas
            // 2027
            [uint16(2027), 1, 1],
            [uint16(2027), 1, 18],
            [uint16(2027), 2, 15],
            [uint16(2027), 3, 26], // Good Friday
            [uint16(2027), 5, 31],
            [uint16(2027), 6, 18], // Juneteenth (observed)
            [uint16(2027), 7, 5], // Independence Day (observed)
            [uint16(2027), 9, 6],
            [uint16(2027), 11, 25],
            [uint16(2027), 12, 24] // Christmas (observed)
        ];
        h = new uint32[](d.length);
        for (uint256 i; i < d.length; ++i) {
            h[i] = uint32(CivilDate.daysFromCivil(d[i][0], d[i][1], d[i][2]));
        }
    }

    function earlyCloses2026to2027() internal pure returns (uint32[] memory e) {
        e = new uint32[](3);
        e[0] = uint32(CivilDate.daysFromCivil(2026, 11, 27)); // day after Thanksgiving
        e[1] = uint32(CivilDate.daysFromCivil(2026, 12, 24)); // Christmas Eve
        e[2] = uint32(CivilDate.daysFromCivil(2027, 11, 26)); // day after Thanksgiving
    }
}
