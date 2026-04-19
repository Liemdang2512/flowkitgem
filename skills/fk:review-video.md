
Review AI-generated scene videos for quality using Claude Vision.

Usage: `/fk:review-video <video_id> [--mode light|deep]`

Default mode: `light`. Orientation auto-detected from project `meta.json`.

## Prerequisites

- `ANTHROPIC_API_KEY` env var set
- `ffmpeg` + `ffprobe` installed
- Scenes must have completed videos (`${ori}_video_status = COMPLETED`)

## Step 1: Pre-check

```bash
# Verify server + extension connected
curl -s http://127.0.0.1:8100/health
# Must return: {"extension_connected": true}

# Verify video exists
curl -s http://127.0.0.1:8100/api/videos/<VID>
```

**ABORT** if extension not connected or video not found.

## Step 2: Check scenes have completed videos

```bash
curl -s "http://127.0.0.1:8100/api/scenes?video_id=<VID>"
```

For each scene, verify `${ori}_video_status = COMPLETED` (orientation auto-detected from meta.json).

**ABORT** if any scene is missing a completed video — tell user to run `/fk:gen-videos` first.

## Step 3: Run review via API

```bash
curl -X POST "http://127.0.0.1:8100/api/videos/<VID>/review?project_id=<PID>&mode=light&orientation=${ORI}"
```

**Parameters:**
- `mode`: `light` (default) or `deep`
- `orientation`: auto-detected from meta.json (`${ORI}`)

The API will extract frames from each scene video, send them to Claude Vision, and return per-scene quality scores.

**Poll until complete:**
```bash
curl -s http://127.0.0.1:8100/api/requests/<RID>
# Wait for status: "COMPLETED"
```

## Step 4: Interpret results

The response is an array of per-scene review objects:

```json
[
  {
    "scene_id": "abc-123",
    "display_order": 0,
    "total_score": 8.5,
    "dimensions": {
      "character_consistency": 9.0,
      "prompt_adherence": 8.5,
      "motion_quality": 8.0,
      "visual_fidelity": 8.5,
      "temporal_coherence": 8.0,
      "composition": 9.0
    },
    "errors": ["Slight motion blur at 4s mark"],
    "fix_guide": "Acceptable as-is. If re-generating, add 'sharp focus, crisp motion' to prompt.",
    "usable": true,
    "verdict": "good",
    "usable_segments": [
      {"start": "0s", "end": "4s", "score": 9.0},
      {"start": "5s", "end": "8s", "score": 8.5}
    ]
  }
]
```

### Scoring Dimensions

| Dimension | Weight | What it measures |
|-----------|--------|------------------|
| Character Consistency | 25% | Characters match refs across frames |
| Prompt Adherence | 20% | Video matches prompt description |
| Motion Quality | 20% | Smooth motion, no artifacts |
| Visual Fidelity | 15% | Resolution, clarity, no banding |
| Temporal Coherence | 10% | Consistent lighting/shadows across frames |
| Composition | 10% | Framing matches camera direction |

`total_score = sum(dimension_score * weight)`

### Verdict Scale

| Score | Verdict | Action |
|-------|---------|--------|
| 9.0–10.0 | Excellent | Ship as-is |
| 7.5–8.9 | Good | Usable, minor polish optional |
| 6.0–7.4 | Acceptable | Cut usable segments, regen weak parts |
| 4.0–5.9 | Poor | Regen scene image first, then video |
| 0–3.9 | Unusable | Rewrite prompt + regen from scratch |

Errors in the `errors` array are prefixed with severity: `[CRITICAL]`, `[HIGH]`, or `[MINOR]`. Any `[CRITICAL]` error forces the scene into the 0–3.9 range regardless of other dimensions. See **Known AI Video Errors** section below.

## Step 5: Act on results

### Poor / Unusable scenes
Regenerate the scene image first, then the video:
```bash
# Force-regenerate scene image (cascades video + upscale)
curl -X POST http://127.0.0.1:8100/api/requests \
  -H "Content-Type: application/json" \
  -d '{"type": "REGENERATE_IMAGE", "scene_id": "<SID>", "project_id": "<PID>", "video_id": "<VID>", "orientation": "${ORI}"}'
```
Then run `/fk:gen-videos <PID> <VID>` after image is complete.

### Acceptable with good segments
Note `usable_segments` time ranges for manual editing. Use `/fk:concat` and trim in post.

### Character drift (low `character_consistency`)

Diagnose in order — fix at root cause before regenerating:

1. **Bad ref image (most common root cause)** — view ref URL from `GET /api/projects/<PID>/characters`. If ref shows character at angle, in shadow, too far/small, or cluttered background → PATCH `image_prompt` + run `REGENERATE_CHARACTER_IMAGE` first. Then regen scene image and video.

2. **`character_names` incomplete** — check scene's `character_names` includes ALL visible entities. Missing entry = ref not sent as imageInput = AI invents appearance.

3. **Video prompt too complex** — long prompt or complex camera movement forces model to regenerate frames from scratch. Simplify: cut prompt to <120 words, replace complex movement with `locked-off static` or `slow dolly in`.

4. **Missing consistency lock in video_prompt** — PATCH `video_prompt` to add to SUBJECT block: `"Character maintains consistent appearance throughout. Same face, same outfit, no morphing."` and to NEGATIVE: `"character drift, morphing face, changing appearance, extra limbs"`.

5. **Re-anchor via EDIT_IMAGE** — after fixing ref and prompt, use EDIT_IMAGE to regenerate the scene image with the improved ref, then regen video:
  ```bash
  curl -X POST http://127.0.0.1:8100/api/requests \
    -H "Content-Type: application/json" \
    -d '{"type": "EDIT_IMAGE", "scene_id": "<SID>", "project_id": "<PID>", "video_id": "<VID>", "orientation": "${ORI}"}'
  ```

### After fixes
Run review again to verify improvements:
```bash
curl -X POST "http://127.0.0.1:8100/api/videos/<VID>/review?project_id=<PID>&mode=deep"
```

## Modes

- **light** (default): 4 frames/second → 32 frames per 8s video. Fast, good for initial scan to identify problem scenes.
- **deep**: 8 frames/second → 64 frames per 8s video. Thorough, catches subtle artifacts and motion issues. Use before final export.

## Output Summary

Print a table after review completes:

```
Scene | Order | Score | Verdict    | Errors | Usable Segments
------|-------|-------|------------|--------|----------------
s-1   | 0     | 8.5   | good       | 1      | 2s-4s(9.0), 6s-8s(8.5)
s-2   | 1     | 6.2   | acceptable | 2      | 3s-5s(7.0)
s-3   | 2     | 9.1   | excellent  | 0      | full
s-4   | 3     | 3.8   | unusable   | 5      | none
...
Total: 6.9/10 | 4 scenes reviewed | 0 skipped
```

Then print recommended actions:
- Excellent/Good → "Ready for `/fk:concat <VID>`"
- Acceptable → "Note usable segments, trim in post"
- Poor/Unusable → "Run `/fk:gen-images <PID> <VID>` to regenerate, then `/fk:gen-videos <PID> <VID>`"

## Known AI Video Errors

Battle-tested error catalog. Claude Vision flags these in the `errors` array with severity prefix.

### CRITICAL (Auto-fail, score 0–3)

| # | Error | Description | When it happens |
|---|-------|-------------|-----------------|
| 1 | Character Drift | Character morphs mid-video (extra limbs, breed changes) | Common after 3–4s |
| 2 | Breed Swap | Similar characters get mixed up | Common in multi-character scenes |
| 3 | Role Reversal | Wrong character performs the action | ~50% of action scenes |
| 4 | Brand Logo | AI generates real brand logos | Any scene with objects/signage |
| 5 | Character Count | Wrong number of characters rendered | Crowd or paired scenes |

Any CRITICAL error → scene scores 0–3.9 (Unusable). Rewrite prompt + regen from scratch.

### HIGH (Needs trim/regen, score 4–6)

| # | Error | Description | When it happens |
|---|-------|-------------|-----------------|
| 6 | Camera Drift | Sudden unwanted zoom or rotation | ~60% of scenes after 4s |
| 7 | Object Morph | Held items change shape mid-video | Action scenes with props |
| 8 | Reverse Motion | Character does then undoes the action | ~30% of motion scenes |
| 9 | Human Hands | Anthropomorphic characters get human hands | Animal/creature characters |
| 10 | Scale Break | Characters change size relative to environment | Dynamic movement scenes |

HIGH errors → note `usable_segments` before the error timestamp. Trim or regen.

### MINOR (Acceptable, score 7–8)

| # | Error | Description |
|---|-------|-------------|
| 11 | Prop Count | Small props change in number |
| 12 | Clothing Detail | Texture or pattern shifts |
| 13 | Background Blur | Garbled signage or background text |
| 14 | Accessory Loss | Small items (earrings, accessories) appear/disappear |

MINOR errors → acceptable for most use cases. Polish optional.

### Prevention Patterns

| Issue | Fix |
|-------|-----|
| Character drift | 1) Check ref image quality (full face, neutral bg, even lighting) — regen ref if bad. 2) Add to SUBJECT block: `"Character maintains consistent appearance throughout. Same face, same outfit, no morphing."` 3) Add to NEGATIVE: `"character drift, morphing face, changing appearance"` 4) Simplify camera movement: prefer `locked-off static` or `slow dolly in`. 5) Keep prompt under 120 words — long prompts increase drift probability. |
| Breed swap | Use high color contrast between similar characters. Add species-specific anatomy to NEGATIVE: `"wrong species, human features on animal"` |
| Character count | ONE dominant character per shot, others blurred in background. For multi-character dialogue, use over-the-shoulder shots — only 1 face visible at a time. |
| Reverse motion | Regen video (luck-based, different seed) |
| Brand logos | Add "no brand logos, no text" to prompt |
| Camera drift | Add "static camera" or "locked-off shot" to video_prompt |
| Human hands | Add "paws, claws, hooves" (or correct anatomy) to prompt |
| CGI/plastic look | Add `natural skin texture, photorealistic, 4K, no AI smoothing` to prompt (realistic material) |
| Wrong aspect ratio (16:9 vs 9:16) | Verify project orientation; add `OUTPUT FORMAT: Vertical 9:16` to prompt; add `16:9 landscape` to Negative |
| Dialogue in wrong language | Use `[DIALOGUE - VIETNAMESE ONLY]` block; add `English dialogue` to Negative; never translate dialogue |

## Cost Note

Each scene review = 1 Claude Vision API call with N frames.
- Light mode (32 frames/scene): ~$0.01–0.03 per scene
- Deep mode (64 frames/scene): ~2x light mode cost

Reviewing a full video (10 scenes, deep) ≈ 10 API calls. Review light first, then deep only on scenes flagged as poor/acceptable.
