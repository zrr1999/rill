# Rill App Icon

`AppIcon-1024-routed-voice-cursor.png` is the reviewed ICNS master. It was
created with OpenAI's built-in image generation tool, refined twice to improve
semantic clarity and small-size recognition, and resized to 1024 × 1024 pixels
with `sips`. The reviewed PNG was then stripped of metadata and quantized to
512 representative RGB colors without dithering. This keeps the
tracked source below the repository's 500 KiB limit while preserving a 0.0026
normalized RMSE against the resized generated source.

ImgBot subsequently compressed both PNG files losslessly. Decoding the original
and optimized files to 8-bit RGBA produces identical pixels for each image.

Reviewed 1024 px source SHA-256 after lossless compression:
`bff6a4c0ffb39a31ca09eb43953eb58113161c81308d5012578f89c205f3f876`

Original generated 1254 px source SHA-256:
`ca15d8bbd7347b73d48ddcb5c94435e28e3c8fd4e6b6f5033f55ec379485de73`

Final optimization command:

```bash
magick AppIcon-1024-routed-voice-cursor.png \
  -strip -colorspace sRGB -dither None -colors 512 \
  -define png:compression-level=9 \
  PNG24:AppIcon-1024-routed-voice-cursor.optimized.png
```

The earlier `AppIcon-1024.png` exploration remains unbundled for visual
comparison. Release assembly consumes only the routed voice cursor master.

## Design rationale

The mark shows a voice pulse and a second workflow lane merging at one routing
node before resolving into a text insertion cursor. It avoids visual territory
already used by voice and clipboard competitors: vertical equalizers,
microphones, stacked cards, return arrows, and abstract AI loops.

The reviewed source remains an opaque, unmasked square. The release renderer
turns it into traditional ICNS renditions with a transparent rounded body and
subtle shadow so Sonoma and Sequoia do not receive sharp opaque corners. The
16 px and 32 px renditions use deliberate optical crops to preserve both input
lanes, the route node, and the insertion cursor. macOS 26 may further adapt
legacy icons to its current icon system; real checks on macOS 14, 15, and 26
remain release QA gates. See [Apple's current app-icon guidance][apple-hig] and
the [macOS 26 icon-system session][apple-wwdc25].

## Previous exploration provenance

`AppIcon-1024.png` is an earlier built-in-image-generation exploration with a
dark indigo background, stacked clipboard cards, and a vertical waveform. Its
SHA-256 is
`8611aea5769098ec420d05399f14e75835ec320cceee96c78d87762a1bc526f3`.
Its exact prompt metadata was not retained, so it is noncanonical and must not
be wired into release assembly.

## Base generation prompt

> Use case: logo-brand
>
> Asset type: native macOS application icon, 1024 x 1024 square master for
> Rill
>
> Primary request: create one original “Routed Voice Cursor” mark for a
> local-first voice input and clipboard workflow app. A single thick voice
> pulse enters from the left, passes through one clear routing node near the
> center, and resolves on the right into a tall, unmistakable text insertion
> cursor. The transition should communicate “spoken input becomes routed typed
> text.” Use a subtle V-shaped negative space only as a secondary discovery,
> never as a literal letter.
>
> Scene/backdrop: full-bleed opaque square background, unmasked; the operating
> system will apply the final rounded-corner mask
>
> Style/medium: polished Apple-platform app icon artwork, vector-like filled
> shapes, minimal and highly legible, clearly defined edges, restrained shallow
> dimensionality, soft internal depth only
>
> Composition/framing: exactly one centered mark occupying about 68 percent of
> the canvas; optically balanced; generous but not excessive safe margin; at
> most three bold foreground shapes; strong silhouette that remains
> recognizable at 16 px
>
> Color palette: deep ink teal #102A2A background, warm ivory #F4EEDC main
> pulse, coral #FF6B5F only for the routing node and insertion cursor
>
> Lighting/mood: calm, precise, private, professional; very subtle embossing
> and controlled soft shadow
>
> Constraints: original design only; full square canvas with no pre-rounded
> outer mask; no transparency; no text; no letters; no wordmark; no microphone;
> no vertical equalizer bars; no stacked waveform bars; no clipboard or paper
> cards; no speech bubble; no AI sparkle; no Möbius loop; no arrow shaped like
> P; no keyboard keycap; no border frame; no mockup; no watermark; no extra
> icons; do not present a grid or multiple variants

## First refinement prompt

> Keep the exact deep ink teal, warm ivory, and coral palette and the clean
> dimensional material style, but redesign only the foreground glyph so its
> meaning is clearer at 16 px. Remove the ivory loop or branch that curls
> downward beside the cursor. Replace the foreground with two smooth thick
> ivory input ribbons on the left: one gentle voice pulse and one shorter lower
> routing lane. Both must merge once at a much smaller coral routing node near
> the center. From that node, one short straight ivory output lane runs right
> and ends cleanly at a coral vertical text insertion cursor.
>
> Keep the foreground centered and compact, occupying about 64 percent of the
> canvas width. Preserve the full-bleed opaque square background. Do not add a
> loop, dangling branch, arrowhead, medical heartbeat zigzag, audio jack,
> equalizer, microphone, clipboard, letter, text, border, mask, mockup, or
> watermark.

## Small-size refinement prompt

> Keep the exact two-lane routed voice cursor concept, geometry, centered
> composition, and deep ink teal, warm ivory, and coral palette. Make only
> small-size optical refinements. Enlarge the complete foreground mark to
> occupy about 76 percent of the canvas width. Increase the ivory lane
> thickness by roughly 70 percent while retaining one smooth upper voice pulse
> and one straight lower workflow lane. Enlarge the coral route node to about
> 10 percent of the canvas width. Make the coral insertion cursor taller and
> thicker, with a clean rounded cap. Reduce bevel and shadow detail so the mark
> remains crisp at 16 px and 32 px. Keep the full-bleed opaque square
> background. Do not add text, letters, microphone, equalizer, clipboard,
> arrowhead, loop, sparkle, border, mask, mockup, or watermark.

[apple-hig]: https://developer.apple.com/design/human-interface-guidelines/app-icons/
[apple-wwdc25]: https://developer.apple.com/videos/play/wwdc2025/220/
