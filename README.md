# Domin-Uno

A scorekeeper for Mexican Train Dominoes on iPhone and iPad.

## The name

My son and his family always announced they had a single tile remaining by proclaiming "Domin-Uno!"

## Playing a round

1. **Pick the starting double.** Tap the tile in the green row for the double that opened this round. It stays highlighted.
2. **Enter each player's points.** Tap the player's `(x)` field and type the pips left in their hand, or touch and hold `(x)` to count them with the camera. A player who went out leaves `(x)` at 0. The `=` column shows the new total as you type; `(n)` doesn't change yet.
3. **Finish the round: tap the highlighted tile in the blue row** (the one outlined in red). Every total moves into `(n)`, every `(x)` goes back to 0, that tile turns yellow, and the red highlight moves to the next tile in the blue row. Typing points never ends a round by itself; only this tap does.
4. **Made a mistake?** Touch and hold the last yellow tile in the blue row and choose **Undo Round**.

After round 13 the lowest total wins.

## Everything on the screen

- **Green row:** tap the double that opened this round (look for the double-12, then 11, and so on, down to the double-blank). Doubles picked in earlier rounds stay highlighted.
- **Blue row:** one tile per round, 13 in all. Tiles for finished rounds are yellow; the highlighted tile (outlined in red) is the round in play. Tap the highlighted tile to finish the round: each player's total becomes their score for the next round. Touch and hold the last yellow tile to undo it.
- **Players:** a new match starts with two rows; typing a name opens another row below it (up to 10 players). Number fields start at 0. For each player enter the score so far `(n)` and the points left in hand `(x)`; `+`/`−` sets whether `x` is added or taken away. Someone who joins after a round has been played starts at the average of everyone's totals plus 10%. Lowest total after round 13 wins.
- **Count pips with the camera:** touch and hold a player's `(x)` field and photograph their leftover tiles, face up, from above. Each pip found is marked with a dot; check the total, adjust it if needed, and tap Use to put it in `(x)`. The counting happens on the phone. See *Counting with the camera* below.
- **New · Open · Save:** Save asks for a name the first time, then the match is saved again after every round. A saved match keeps the names, the totals and how many rounds have been played. Open lists the saved matches; check one to resume it (swipe left to delete one).

Works in portrait and landscape (same layout, scaled up sideways). Tap anywhere outside a field to put the keyboard away. The match in play is also kept as you go, so it survives closing the app.

## Counting with the camera

Touch and hold a player's `(x)` field, take a photo of the tiles, and Domin-Uno counts the pips on the tiles.

- **It takes a moment.** Processing a photo is not instant; a progress indicator shows until the count is ready.
- **Check the dots.** A processed photo marks each pip it found with a dot that blinks between red and green. Look over every tile to be sure all of its pips have a dot; if some are missing, add them with the `+`/`−` stepper before tapping Use.
- **Keep the tiles apart.** The count is most reliable when no tiles touch each other.
- **Use a plain background.** A solid, uncluttered surface works best; wood grain and patterns are harder.
- **Colored tiles need a closer look.** Tiles with colored pips or colored faces may be miscounted, so check them by eye.
- **Light helps.** Use even light, and the flash if the tiles are in shadow.
- **Stay overhead.** Photograph from straight above with all the tiles in the frame.
- **Private.** The photo is analyzed on the phone, is not saved, and never leaves it.

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
xcodegen generate
open DominUno.xcodeproj
```
