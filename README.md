# Domin-Uno

A scorekeeper for Mexican Train Dominoes on iPhone and iPad.

## The name

My son and his family always announced they had a single tile remaining by proclaiming "Domin-Uno!"

- **Green row:** tap the double that opened this round (look for the double-12, then 11, and so on, down to the double-blank). Doubles picked in earlier rounds stay highlighted.
- **Blue row:** the 13 rounds. Finished rounds are highlighted; the round in play is outlined in red. Tap the red-outlined round to finish it: each player's total becomes their score for the next round. Touch and hold the last finished round to undo it.
- **Players:** a new match starts with two rows; typing a name opens another row below it (up to 10 players). Number fields start at 0. For each player enter the score so far `(n)` and the points left in hand `(x)`; `+`/`−` sets whether `x` is added or taken away. Someone who joins after a round has been played starts at the average of everyone's totals plus 10%. Lowest total after round 13 wins.
- **Count pips with the camera:** touch and hold a player's `(x)` field and photograph their leftover tiles, face up, from above. Each pip found is circled; check the total, adjust it if needed, and tap Use to put it in `(x)`. The counting happens on the phone.
- **New · Open · Save:** Save asks for a name the first time, then the match is saved again after every round. A saved match keeps the names, the totals and how many rounds have been played. Open lists the saved matches; check one to resume it (swipe left to delete one).

Works in portrait and landscape (same layout, scaled up sideways). Tap anywhere outside a field to put the keyboard away. The match in play is also kept as you go, so it survives closing the app.

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
xcodegen generate
open DominUno.xcodeproj
```
