# Mouse Zoom & Follow for OBS Studio

Made by **Pablo Ruan**. [MIT](LICENSE) license. Downloads on the [Releases](https://github.com/pabloruancoder/mouse-zoom-follow/releases) page.

🇧🇷 [Versão em português](README.pt-BR.md)

A script for OBS Studio (Windows) that zooms the screen around the cursor and makes the view follow the mouse. It has smooth animations, mouse wheel, button and keyboard controls, a custom cursor, and every option is configurable.

## Installation

1. In OBS: **Tools > Scripts**.
2. Click **+** and select `mouse-zoom-follow.lua`.
3. In **Source or scene to zoom**, leave **Automatic**, which uses the visible Display Capture in the current scene. You can also pick a specific source or a whole scene.
4. Use **Shift + mouse wheel** or **Ctrl+Alt+Z** to zoom.

**Language:** the interface is available in English and Portuguese (Brazil). Choose it in **Idioma / Language**, at the top of the script settings. "Automatic" follows the OBS language. The settings update right away; hotkey names and the description update after reloading the script (↻).

To check which version is loaded, open **Script Log**: the line "Mouse Zoom & Follow X.Y.Z loaded" appears every time the script loads.

Zoom works in any scene where the source appears, including nested scenes and Studio Mode.

## Default controls

### Mouse
Configure in Tools > Scripts, "Mouse controls" group.

| Action | Default |
|---|---|
| Zoom in / out | Shift + mouse wheel |
| Toggle zoom | (none). Can be the middle button or a side button, with or without a key |
| Zoom while held | (none) |
| Toggle follow | (none) |

The wheel key can be Shift, Ctrl, Alt, a combination, or none. The combination must match exactly: with "Shift", Ctrl+Shift+wheel does not zoom.

### Keyboard
Change in **Settings > Hotkeys** (search for "Mouse Zoom").

| Action | Hotkey |
|---|---|
| Toggle zoom | Ctrl+Alt+Z |
| Zoom while held | Ctrl+Alt+X |
| Toggle mouse follow | Ctrl+Alt+F |
| Zoom in | Ctrl+Alt+↑ |
| Zoom out (exits zoom below the minimum) | Ctrl+Alt+↓ |
| Reset to default zoom level | Ctrl+Alt+0 |
| Center on mouse | Ctrl+Alt+C |

## Options

**Zoom:** default level, step, minimum and maximum, remember the last level, animation duration and curve, zoom origin (point under the cursor stays still, center on the cursor, or center) and scaling quality (bilinear, bicubic, Lanczos, point).

**Mouse follow:** follow automatically, speed, dead zone (central area where the mouse moves without moving the view), keep following outside the captured screen, zoom out after the mouse is idle.

**Mouse controls:** turn the wheel on/off, wheel key, zoom per wheel notch, invert direction, wheel animation duration, and buttons (middle, side 1, side 2) with a key for each action.

**Mouse cursor:**
- **Appearance:**
  - **Original:** the cursor the Display Capture already shows.
  - **Arrow:** custom arrow and outline colors.
  - **Custom image:** PNG, animated GIF, JPG, etc., with scale and tip position (hotspot).
  - **Colored dot.**
  - **Hidden.**
- With any appearance other than "Original", the script turns off the capture's "Capture Cursor" option and turns it back on when you switch back to "Original" or unload the script.
- Cursor size, and an option to hide the cursor after a few idle seconds.
- **Highlight:** a colored circle around the cursor, with configurable color and size.
- **Click effect:** a ring that expands on each click, with different colors for left and right click, configurable size and duration.
- **Keep size while zoomed:** by default the cursor is magnified with the image, like the real cursor. Check this option to keep it the same size on screen.

Sizes are in pixels of the captured screen.

**Monitor:**
- **Automatic:** uses the Display Capture's monitor; for a scene, uses the first Display Capture inside it.
- **A specific monitor.**
- **Manual:** X/Y/width/height area, for other source types.

## How it works

When a cursor option is on, the script adds the **Mouse Zoom (cursor)** filter to the source. It draws the cursor and effects before the zoom, so they are magnified with the image.

For zooming, the script adds two filters of its own to the source, **Mouse Zoom (crop)** and **Mouse Zoom (scale)**. The crop selects the magnified area and the scale brings the image back to its original size. The source transform in your scenes is never changed. The filters are disabled when not zoomed and removed when the script is unloaded or OBS closes. Do not edit these filters manually.

The mouse wheel and buttons are read through Windows Raw Input. The event still reaches the focused application: with Shift + wheel, a browser will also scroll sideways. If that bothers you, pick another key, such as Ctrl + Alt.

## Known limitations

- Windows only for now.
- The crop uses whole pixels, so very slow movements may advance 1 source pixel at a time.
- The custom cursor always has the same shape. It does not turn into a hand or text cursor like the Windows cursor.
- With the "Original" appearance, the highlight is drawn over the real cursor, which gets slightly tinted by the highlight color.
- If OBS is force-closed while a custom style is active, the capture's "Capture Cursor" option may stay off. To fix it, switch the appearance back to "Original" or turn the option back on in the capture's properties.
- When a whole scene is selected, Automatic mode assumes the Display Capture fills the scene. If it does not, use Manual mode.
