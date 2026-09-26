# The Outer Worlds 2 – UEVR VR Profile

A full motion-controller VR conversion of The Outer Worlds 2 for [UEVR](https://uevr.io), with visible hands, physical weapon handling, two-handed aiming, physical melee and a stable, comfortable camera.

## Features

### Hands and weapons

- **Visible VR hands.** Your real hands are shown as first-person gloves that follow the controllers, cut down from the game's own arm mesh so they match the suit.
- **Per-weapon grip poses.** The hands wrap around each weapon type correctly, with separate grip and trigger poses for pistol, revolver, SMG, machine pistol, rifle, assault rifle, shock rifle and baton.
- **Weapon in hand.** The equipped weapon is attached to your right controller and aims where you point it, with a per-weapon position and rotation offset. Bullets go where the barrel points via a small native aim-fix plugin.
- **Two-handed aiming.** On rifles and other long guns, reach your left hand to the fore-grip and hold the left trigger to grab it. The weapon then pivots between both hands, and the left hand takes a captured grip pose.
- **Physical melee.** With a melee weapon out, a fast swing left, right or down attacks, and the game's swing animation is sped up to keep pace with your arm.
- **Reload fix.** Reloads always refill the magazine, which the game otherwise skips in VR.

### Camera and movement

- **Steady camera.** Head bob, camera shake, melee camera animations and weapon-kick camera effects are all disabled, and the camera height is corrected to eye level.
- **Head-directed movement.** Push forward and you walk where you're looking. The right stick still turns you.
- **Decoupled pitch.** Looking up and down does not tilt the game camera, so no motion-sickness pitch coupling.
- **Depth-correct weapon rendering.** Weapons, mods and hands are moved out of the game's flat foreground pass so they sit at the right depth in stereo, with no black or missing parts.

### Interface and comfort

- **UI that moves with context.** The HUD and menus sit at a comfortable distance normally and pull in close during conversations and terminal use, driven by the game's zoom.
- **Conversation and cutscene handling.** Camera offsets, UI placement and hands adjust automatically in dialogue and cutscenes.
- **Laser pointer menu interaction.** A pointer from the right hand for clicking menus and terminals.
- **Controller face-button swap.** X and B are swapped on the gamepad mapping for a more natural VR layout.

## Controls

| Action | Input |
|---|---|
| Move | Left stick, relative to where you look |
| Turn | Right stick |
| Aim / fire | Point the right controller, right trigger |
| Two-hand a long gun | Bring the left hand to the fore-grip and hold the left trigger |
| Melee attack | Swing the right controller left, right or down with a melee weapon equipped |
| Menus and terminals | Right-hand laser pointer |

## Installation

1. Install UEVR and confirm the game launches in VR with the stock injector.
2. Copy the contents of this folder into `%APPDATA%\UnrealVRMod\TheOuterWorlds2-WinGDK-Shipping\`.
3. Inject UEVR as usual. The profile loads automatically.

## Tuning

Everything is adjustable from panels in the UEVR overlay, without editing files:

- **Attachment Configuration** – per-weapon position, rotation, two-handed and melee flags.
- **Hand Config** – hand poses per weapon.
- **Two-Handed** – fore-grip point, grab radius and left-hand pose per weapon.
- **Physical Melee** – swing sensitivity, cooldown and animation speed.
- **Camera Stabilize** – individual toggles for each camera effect.

## Under the hood

Built on the shared uevrlib Lua framework, running on the joeyhodge UEVR backend with the alternate frame warp render method. Game-specific logic lives in a handful of small scripts on top of the framework: weapon attachment and rendering fixes, two-handed aiming, physical melee, camera stabilisation, and the conversation/UI handling.
