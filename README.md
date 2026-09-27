# The Outer Worlds 2 – UEVR VR Profile

A full motion-controller VR conversion of The Outer Worlds 2 for UEVR, with visible hands, physical weapon handling, two-handed aiming, physical melee and a stable, comfortable camera.

## IMPORTANT!

- GAMEPASS ONLY
- My custom UEVR backend is required - see releases to download this
- Performance is not great, nothing I can do about that

## Features

### Hands and weapons

- **Visible VR hands, two ways.** A "Hands Mode" panel lets you pick either glove hands, cut down from the game's own arm mesh so they match the suit, or full IK arms that reach from your shoulders to the controllers with elbows solved in between. Switch between them live, no reset. Both appear automatically on every level load.
- **Hands follow your outfit.** Change suit or armor in the inventory and the hands or arms rebuild themselves with the new model and skin within half a second, and come back already holding your current weapon's grip pose.
- **Per-weapon grip poses.** The hands wrap around each weapon type correctly, with separate grip and trigger poses for pistol, revolver, SMG, machine pistol, rifle, assault rifle, shock rifle and baton. One pose set drives both glove hands and IK arms.
- **Weapon in hand.** The equipped weapon is attached to your right controller and aims where you point it, with a per-weapon position and rotation offset. Bullets go where the barrel points via a small native aim-fix plugin.
- **Two-handed aiming.** On rifles and other long guns, reach your left hand to the fore-grip and hold the left trigger to grab it. The weapon then pivots between both hands. The left hand takes a grip pose captured from the game's own animation for that weapon and holds it for the whole grab, with the left trigger ignored for finger animation while you're gripping. Works in both hand modes; in IK mode the whole left arm is solved onto the fore-grip and follows the gun as it pivots.
- **Physical melee.** With a melee weapon out, a fast swing left, right or down attacks, and the game's swing animation is sped up to keep pace with your arm.
- **Reload fix.** Reloads always refill the magazine, which the game otherwise skips in VR.
- **Clean weapon swaps.** The game's own arm mesh no longer flashes on screen when switching weapons, and weapon mods such as magazines render with their proper textures.

### Camera and movement

- **Steady camera.** Head bob, camera shake, melee camera animations and weapon-kick camera effects are all disabled. The first-person camera is taken off the animated arm socket the game bobs it with, so walking, sprinting and swinging no longer shake the view.
- **Correct eye height.** The VR camera sits at the character's real eye level rather than the top of the collision capsule.
- **Head-directed movement.** Push forward and you walk where you're looking. The right stick still turns you. Sprinting runs straight, with no drift.
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
3. Inject UEVR as usual. The profile loads automatically, and the hands appear a few seconds after the level loads.

## Tuning

Everything is adjustable from panels in the UEVR overlay, without editing files:

- **Attachment Configuration** – per-weapon position, rotation, two-handed and melee flags.
- **Hands Mode** – glove hands or IK arms.
- **Hand Config** – hand poses per weapon, used by both modes.
- **IK** – rig height offset, body hiding, and per-arm solver settings for IK mode.
- **Two-Handed** – fore-grip point, grab radius and left-hand pose per weapon.
- **Physical Melee** – swing sensitivity, cooldown and animation speed.
- **Camera Stabilize** – individual toggles for head bob, camera shake, camera animations, weapon kick, and the camera-rotation source.

## Under the hood

Built on the shared uevrlib Lua framework, running on the joeyhodge UEVR backend with the alternate frame warp render method. Game-specific logic lives in a handful of small scripts on top of the framework: weapon attachment and rendering fixes, two-handed aiming, physical melee, camera stabilisation, the hands bootstrap with outfit tracking, and the conversation/UI handling.

The shared library carries a few fixes specific to this game and backend: freshly spawned objects are not visible to UEVR's object tracker for several seconds, so controller creation, hand teardown and finger animation no longer gate on that tracker. Without these, hands would only appear after a script reset, quick outfit changes could leave duplicate hands, and level changes could throw per-frame animation errors.

The IK module needed the same treatment plus two more: this game cannot build engine names from plain strings, so every bone lookup in the solver goes through an explicit conversion, and the rig's height is anchored to the top of the collision capsule so crouching keeps the shoulders level with the camera. Two-handing in IK mode reuses the library's accessory hook, which lets a hand's IK target follow a point on another component instead of the controller. Glove hands and IK arms share one set of animation ids, which is why they are a mode switch rather than a pair of toggles.
