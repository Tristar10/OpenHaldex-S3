# Experimental features

These are autocross/track automations gated behind a master "Experimental
Features" toggle on the Setup page, off by default. They act on CAN signals
that have not yet been road-tested for accuracy on a live car, so they are
kept separate from (and off independent of) the normal mode controls. Both
are Gen 5 only - a no-op on Haldex generation 1/2/4.

Both features override whatever mode is otherwise selected (including the
CAN Mode Trigger) whenever their condition is active. Thermal protection
takes priority over the reverse switch if both are somehow true at once.

## Switch mode in reverse

Forces the selected target mode (default FWD) whenever the car's reverse
light switch is active, then reverts automatically once reverse is no
longer selected. Useful for avoiding Haldex-locked binding/clunking during
tight reverse maneuvers (e.g. backing into an autocross box).

Source: `BCM1_Rueckfahrlicht_Schalter` (reverse light switch), CAN ID 987
(`Gateway_72`), bit 25. From
[commaai/opendbc's `vw_mqb.dbc`](https://github.com/commaai/opendbc/blob/master/opendbc/dbc/vw_mqb.dbc).

## Haldex clutch thermal protection

Forces the selected target mode (default FWD) whenever Haldex clutch
temperature reaches or exceeds the configured threshold (default 120degC),
and reverts once it drops back below. Intended to reduce load on the
coupling during sustained hard track use, before temperature reaches a
damaging level.

The threshold has no verified source specific to this hardware - it is a
starting point, not a manufacturer-specified safe limit. Tune it once you
have observed real clutch-temp readings during normal and hard driving.

Source: the same UDS poll (`ReadDataByIdentifier`, DID `0x2BF1`, every ~2s)
used for the Haldex clutch temperature RaceChrono channel - see
[docs/RACECHRONO_WIFI.md](RACECHRONO_WIFI.md). Because this is a ~2s poll
rather than a live CAN broadcast, the mode switch can lag the actual
temperature by up to that interval.

## Verifying before relying on these

Before enabling either feature for real driving:
1. Confirm the relevant telemetry (gear/reverse status, Haldex clutch temp)
   reads correctly via RaceChrono or the WebUI across a real drive.
2. Enable the feature with the car safely stopped and confirm the mode
   actually switches when the condition is met (e.g. put the car in
   reverse and watch the effective mode change), and switches back when
   the condition clears.
3. Only then rely on it while actually driving.
