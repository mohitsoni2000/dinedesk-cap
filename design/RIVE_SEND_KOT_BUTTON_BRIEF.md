# Send KOT Button — Rive Asset Brief

## Artboard

| Property    | Value           |
|-------------|-----------------|
| Name        | SendKotButton   |
| Size        | 280 x 56 px     |
| Background  | Transparent     |

## State Machine

| Property | Value |
|----------|-------|
| Name     | Main  |

### Triggers (SMITrigger)

| Trigger   | Purpose                                    |
|-----------|--------------------------------------------|
| `fire`    | Transition from idle to loading             |
| `success` | Transition from loading to success          |
| `error`   | Transition from loading/idle to error       |
| `reset`   | Return to idle from any state               |

### States

| State     | Description                                                   |
|-----------|---------------------------------------------------------------|
| `idle`    | Default resting state — saffron gradient pill, "SEND KOT"     |
| `loading` | Spinner / pulse animation, button disabled                    |
| `success` | Green flash + checkmark, auto-resets after parent calls reset  |
| `error`   | Red shake + X icon, tappable to retry                         |

## Color Tokens

| Token     | Hex       | Usage                        |
|-----------|-----------|------------------------------|
| Saffron   | `#FFB964` | Idle fill, gradient start     |
| Kesar     | `#FF7849` | Idle fill, gradient end       |
| Cardamom  | `#84A763` | Success state fill            |
| Masala    | `#C1432E` | Error state fill              |

## Notes

- Keep the timeline under 60 frames for snappy feedback.
- All transitions should use cubic easing (ease-out).
- Export as `.riv` (Rive runtime 2.x format).
- The artboard must be named exactly `SendKotButton` for code binding.
- The state machine must be named exactly `Main` for code binding.
