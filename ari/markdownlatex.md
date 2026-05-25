The document covers all 22 attempts with full reasoning and outcomes. Here's the plain explanation of why the final solution works end-to-end:

**Why markdown renders correctly:**
The `parseMarkdown` block parser runs first, isolating code, tables, lists, and text *before* any rendering engine sees the content — so the markdown parser never encounters pipe characters inside a code block or list markers inside a paragraph. Inside `.text` blocks, `splitParagraphs` then breaks on blank lines and feeds one paragraph per `NativeMarkdownText` view, sidestepping `AttributedString(markdown:)`'s known behaviour of treating single `\n` as a soft wrap and merging everything into one block.

**Why LaTeX renders correctly inside prose:**
`buildAttributedString` runs three strictly-ordered passes: extract LaTeX into alphanumeric UUID placeholders (so the markdown parser never sees `$`), run `AttributedString(markdown:)` on the clean text, then replace placeholders with `NSTextAttachment` image objects from SwiftMath. Because `NativeMarkdownText` uses `NSTextField` (AppKit) rather than SwiftUI `Text`, those attachment images actually appear — SwiftUI `Text` silently discards them on macOS.

**Why it doesn't crash:**
The `Coordinator` cache means `buildAttributedString` only runs when the text string actually changes, not on every SwiftUI layout pass. The global `_mathImageCache` ensures each unique formula creates exactly one `NSWindow` / `MTMathUILabel` lifetime. Calling `label.removeFromSuperview()` before releasing the window gives SwiftMath's Objective-C internals a clean ARC teardown path.

**Why streaming is smooth:**
`NSRegularExpression` is now a `static let` (compiled once per process, not per token). Plain `Text(string)` skips SwiftUI's markdown parser entirely during the stream. Full rendering only activates once the stream is complete, handled by `MarkdownRendererView`.

---

# Markdown + LaTeX Rendering: Complete Debug Reference

**Project:** Ari — macOS SwiftUI app with on-device LLM streaming
**Renderer stack:** SwiftMath (`MTMathUILabel`) + AppKit (`NSTextField`) + SwiftUI (`MarkdownRendererView`)
**Purpose:** Canonical record of every attempted fix, its reasoning, and its failure mode.
Use this document before making any further changes to prevent repeating known dead ends.

---

## Why the Final Solution Works

Understanding the successful architecture is essential context for evaluating any future change.

### The Two-Phase Rendering Split

The core insight is that **streaming and final rendering are fundamentally different problems** and must be handled by separate views.

| Phase | View | Concern |
|---|---|---|
| Tokens arriving | `LiveStreamingRendererView` | Speed. Render nothing expensively. |
| Stream complete | `MarkdownRendererView` | Fidelity. Render everything correctly. |

Attempting to do full markdown + LaTeX rendering on every incoming token was the root cause of most failures. The final solution separates these concerns entirely.

### Why `MarkdownRendererView` Renders Correctly

**1. `parseMarkdown` block parser**
The response is split into typed blocks (`.text`, `.code`, `.table`, `.list`) before any rendering happens. This prevents the markdown engine from ever seeing table pipes inside a code block, or list markers inside a paragraph — the most common cause of raw syntax leaking to screen.

**2. `splitParagraphs` paragraph isolation**
Apple's `AttributedString(markdown:)` treats a single `\n` as a soft wrap, merging all paragraphs into one block. By splitting `.text` blocks on blank lines first and feeding each paragraph to a separate `NativeMarkdownText`, this is bypassed entirely without needing to manipulate newlines in the raw string (which corrupts LaTeX).

**3. `NativeMarkdownText` uses `NSTextField`, not SwiftUI `Text`**
SwiftUI's `Text` view silently ignores `NSTextAttachment` objects on macOS — images are generated but never displayed. `NSTextField` (via `NSViewRepresentable`) renders attachments natively. This is the only reliable way to mix rendered math images inline with formatted text on macOS.

**4. The placeholder pipeline in `buildAttributedString`**
The sequence is strictly ordered to prevent interference:
- Extract all LaTeX into UUID placeholders *before* running the markdown parser — the markdown engine never sees `$` or `\[`
- Run `AttributedString(markdown:)` on clean, LaTeX-free text
- Replace UUID placeholders with `NSTextAttachment` images after markdown parsing

Doing these out of order causes the markdown parser to mangle placeholder IDs or LaTeX delimiters.

**5. `Coordinator` cache on `NativeMarkdownText`**
SwiftUI calls `updateNSView` very frequently, not only when content changes. Without caching, `buildAttributedString` (which creates `NSWindow` objects for SwiftMath rendering) runs on every SwiftUI layout pass. This caused the ARC corruption crash (`EXC_BAD_ACCESS` in `objc_release`). The `Coordinator` stores the last text and last attributed string — `updateNSView` returns immediately if text is unchanged.

**6. Global `_mathImageCache` in `renderMathImage`**
Each unique LaTeX string only ever creates one `NSWindow` / `MTMathUILabel` pair. Without this, the same formula re-rendered on every view update, rapidly creating and destroying `MTMathUILabel` Objective-C objects faster than ARC could safely track, causing the crash.

**7. `label.removeFromSuperview()` before releasing the window**
SwiftMath's `MTMathUILabel` holds internal Objective-C references. Releasing the `NSWindow` without first detaching the label means those references are torn down while SwiftMath may still be accessing them. Explicit detach before `orderOut` gives ARC a clean teardown path.

### Why `LiveStreamingRendererView` Is Fast

**1. `static let` regex constants**
`NSRegularExpression` compilation is expensive. Declaring the block and inline math patterns as `static let` properties means they are compiled once at process start and reused on every token update, rather than being recompiled on each call.

**2. Plain `Text(string)`, not `Text(LocalizedStringKey(string))`**
`LocalizedStringKey` triggers SwiftUI's markdown parser on every update. During streaming (potentially 30+ updates per second), this adds measurable overhead and causes the batching/stutter effect. Plain `Text` is a direct string display with zero parsing cost.

**3. Regex replacement, not character stripping**
Earlier versions of `cleanForLiveView` stripped individual delimiter characters (`$`, `\[`, etc.) but left the LaTeX content (e.g., `\frac{1}{2}`) visible. Replacing the entire matched span with `⌈math⌋` removes both delimiters and content in a single pass.

---

## Complete Attempt Log

### Attempt 1 — `LaTeXSwiftUI` Third-Party Package

**Modification:** Replace all rendering with the `LaTeX(text)` view from the `LaTeXSwiftUI` Swift package. Rely on it to handle combined Markdown + LaTeX natively.

**Reasoning:** Offload the entire parsing problem to a specialised library.

**Outcome — Dependency unavailable.** The package repository was inaccessible via Swift Package Manager. The build never succeeded. Abandoned before any rendering behaviour could be tested.

**Future rule:** Verify Swift package availability and last commit date before designing architecture around it.

---

### Attempt 2 — SwiftMath + `FlowLayout` + Space Tokenization

**Modification:** Split the AI response on `$` to isolate math from text. Split text segments further on spaces. Feed tokens into a custom SwiftUI `FlowLayout`, rendering `Text()` for words and a `MathView()` wrapper for formulas side-by-side.

**Reasoning:** If each token is small enough to be rendered independently, inline math and text can coexist in a wrapping layout without needing a single unified text engine.

**Outcome — Markdown syntax shattered.** Splitting on spaces destroyed markdown structure. `**Ohm's Law**` became `["**Ohm's", "Law**"]`; the markdown parser saw no complete bold token and displayed literal asterisks. Tables, headers, and lists were all broken by the same mechanism. Raw markdown symbols appeared on screen throughout.

**Future rule:** Never tokenize on whitespace when the input can contain markdown. The markdown engine requires complete syntactic constructs; partial tokens are always rendered as raw text.

---

### Attempt 3 — SwiftMath + `FlowLayout` + Regex Tokenizer

**Modification:** Replace the space-based split with a regex tokenizer (`tokenizeTextPreservingMarkdown`) that identified complete markdown constructs (`**bold**`, `[link](url)`) and kept them as single tokens before feeding into `FlowLayout`.

**Reasoning:** Fix the shattered-syntax problem from Attempt 2 by making the tokenizer markdown-aware.

**Outcome — Nested syntax failure, layout instability.** Placing LaTeX inside markdown (e.g. `**The formula is $V=IR$**`) created overlapping domains the tokenizer could not resolve. The layout engine produced text that shrank, jumped, and flickered during streaming. Tables remained broken because their pipe characters were stripped during tokenization.

**Future rule:** Markdown and LaTeX use overlapping character sets. Any tokenizer that processes both in a single pass will fail on nested constructs. They must be handled in separate, ordered passes.

---

### Attempt 4 — NSTextView + Placeholder Substitution + NSTextAttachment

**Modification:** Extract LaTeX into UUID placeholders, run the full markdown pipeline on the placeholder text, then find placeholders in the resulting `AttributedString` and replace them with `NSTextAttachment` images from SwiftMath.

**Reasoning:** Separating LaTeX extraction from markdown parsing should prevent the two engines from interfering with each other.

**Outcome — Placeholder corruption, paragraph collapsing.** The markdown engine interpreted characters adjacent to some placeholder IDs as markdown syntax (underscores in UUIDs triggered italic parsing), mutating the placeholder string so `range(of:)` could no longer locate it. Unlocatable placeholders caused the raw LaTeX or raw placeholder text to appear on screen. Additionally, rendering the full response as a single string to `NSTextView` caused the markdown engine to treat single `\n` as soft wraps, merging all paragraphs into one block.

**Future rule:** UUID placeholders must not contain characters meaningful to the markdown parser (underscores, asterisks). Use purely alphanumeric sentinel strings. Passing an entire multi-paragraph response as a single string to `AttributedString(markdown:)` always collapses paragraph spacing.

---

### Attempt 5 — Newline Pre-processing

**Modification:** Before passing text to the markdown parser, replace `\n` with `\n\n` (or append `"  \n"` hard-break sequences) to force the markdown engine to recognise paragraph breaks.

**Reasoning:** Directly address the paragraph-collapsing problem from Attempt 4 by satisfying the markdown engine's requirement for double newlines between paragraphs.

**Outcome — LaTeX corruption, broken structural blocks.** The global newline replacement inserted invalid line breaks inside multi-line block math expressions (e.g. `$$a=b\\\\ c=d$$`), corrupting the LaTeX syntax and causing SwiftMath to fail silently, falling back to raw text. The same replacement also broke indented list syntax, header prefixes, and code block boundaries, producing raw `###`, `*`, and `` ``` `` characters on screen.

**Future rule:** Never apply global newline transformations to the raw string when it contains LaTeX. Newline manipulation must happen *after* math extraction, or better, not at all — solve paragraph spacing by splitting into separate view instances rather than mutating the string.

---

### Attempt 6 — Block-Based VStack Parser (`.text` / `.math` Blocks)

**Modification:** Parse the AI response into typed segments — `.text(String)` and `.math(String, isBlock: Bool)` — and render each as its own SwiftUI view inside a `VStack`.

**Reasoning:** Avoid a unified text engine entirely. Each segment type gets the renderer appropriate for it.

**Outcome — Inline math forced to new lines, streaming jitter.** Inline math (single variables like `$V$` within a sentence) was split into a separate block-level view, forcing it onto its own line and fragmenting sentences. During streaming, the parser regenerated all blocks on every incoming token, causing constant layout recalculations and severe flickering.

**Future rule:** Block-level splitting cannot represent inline math without breaking sentence flow. Streaming requires a renderer that can update incrementally without rebuilding its full view tree on every token.

---

### Attempt 7 — Pure SwiftUI `Text(AttributedString)` with Image Attachments

**Modification:** Eliminate AppKit entirely. Render math to `NSImage` via SwiftMath, wrap in `NSTextAttachment`, and insert into a SwiftUI `AttributedString` for display with `Text(attrStr)`.

**Reasoning:** A pure SwiftUI solution without any `NSViewRepresentable` wrapper would be simpler and more maintainable.

**Outcome — Attachments silently ignored.** SwiftUI's `Text` view on macOS silently ignores `NSTextAttachment` objects inside `AttributedString`. Images were generated correctly by SwiftMath but were never drawn to screen. Swift's `AttributedString` API also produced type-checker errors when concatenating strings with attachment-bearing attributed strings, requiring fallback to raw LaTeX text to avoid crashes.

**Future rule:** On macOS, `NSTextAttachment` in an `AttributedString` only works when displayed through an AppKit view (`NSTextField`, `NSTextView`). SwiftUI's `Text` view does not render attachments. Do not attempt to embed math images via SwiftUI `Text` on macOS.

---

### Attempt 8 — Async Dispatch + Preserve Heading Fonts

**Modification:** Dispatch `NSTextField` text-setting asynchronously via `.task(id:)` to avoid layout recursion. Remove the global `attrStr.font = .system(size: 13)` assignment to preserve heading font sizes from the markdown parser.

**Reasoning:** The synchronous update path was suspected of causing layout feedback loops. Heading size was being flattened to body size by the font override.

**Outcome — Text reversion, heading corruption.** Async dispatch caused text to revert to unformatted strings when streaming completed, as the async task fired after the view had already transitioned. Heading sizes were still corrupted because the newline replacement patterns from earlier attempts damaged the heading prefix before the font size was even applied.

**Future rule:** `updateNSView` must be synchronous. Async dispatch inside `NSViewRepresentable` creates race conditions between SwiftUI's view lifecycle and the AppKit update. Use `Coordinator` caching to avoid redundant work instead of deferring the update.

---

### Attempt 9 — `parseMarkdown` Block Parser + Async `NativeMarkdownText`

**Modification:** Introduce the `parseMarkdown` function splitting output into `.text`, `.code`, `.table` blocks. Use `NativeMarkdownText` with an async `.task(id:)` for text rendering.

**Reasoning:** Block parsing should prevent cross-contamination between code, tables, and prose. Async task should remove rendering from the main thread hot path.

**Outcome — Paragraph collapsing, LaTeX still raw.** Large `.text` blocks still collapsed paragraphs because the full block was passed as a single string to `AttributedString(markdown:)`. LaTeX was still displayed raw because `renderMathImage` was calling `intrinsicContentSize` *before* adding the label to an `NSWindow`, returning zero size and causing every render attempt to bail out immediately.

**Future rule:** `MTMathUILabel.intrinsicContentSize` returns zero unless the label is part of a live window hierarchy. Always add the label to the window and call `layoutSubtreeIfNeeded` before measuring.

---

### Attempt 10 — Synchronous `NativeMarkdownText` + No Global Font Flattening

**Modification:** Remove the `.task(id:)` async wrapper, making text updates synchronous. Remove the global font override so heading sizes are preserved.

**Reasoning:** Fix the async reversion bug from Attempt 8 while keeping the heading size improvement.

**Outcome — Paragraphs still collapsed, LaTeX still raw.** Same root cause as Attempt 9: large text blocks fed whole to `AttributedString(markdown:)`, and `renderMathImage` still measured before window attachment.

---

### Attempt 11 — `splitParagraphs` Helper + VStack Paragraph Splitting

**Modification:** Add a `splitParagraphs(_:)` function that splits `.text` blocks on blank lines. Render each paragraph as its own `NativeMarkdownText` in a `VStack` inside `renderParsedBlocks`.

**Reasoning:** Solving paragraph collapsing without mutating newlines in the raw string — split first, then pass short single-paragraph strings to the markdown engine.

**Outcome — ViewBuilder compiler error.** The initial implementation put a `while` loop inside a `@ViewBuilder` closure, which Swift's result builder system prohibits. Compiler error: "Closure containing control flow statement cannot be used with result builder."

**Future rule:** `@ViewBuilder` closures cannot contain `while` loops, `for` loops with complex bodies, or other arbitrary control flow. Extract such logic into a separate function that returns a plain array or uses `ForEach`.

---

### Attempt 12 — Extract `splitParagraphs` Outside `@ViewBuilder`

**Modification:** Move the `while` loop into a standalone `private func splitParagraphs(_:) -> [String]` helper called from within `renderParsedBlocks`.

**Reasoning:** Fix the compiler error from Attempt 11 without changing the logic.

**Outcome — Paragraphs fixed; lists vanished.** Paragraph separation worked correctly. However, `splitParagraphs` doubled single newlines to `\n\n`, which broke the structural syntax of markdown list items that depended on specific newline patterns to be recognised as a group.

**Future rule:** `splitParagraphs` must only be applied to `.text` blocks that have already been separated from list content by `parseMarkdown`. Never apply paragraph splitting to raw text that may still contain list markers.

---

### Attempt 13 — `.list` Block Type + Manual List Rendering

**Modification:** Add a `.list(items: [String])` case to `ChatBlock`. Extend `parseMarkdown` to detect list lines (`- `, `* `, `1. `) and extract them as `.list` blocks before paragraph splitting is applied to `.text` blocks.

**Reasoning:** Remove list content from the text pipeline entirely so `splitParagraphs` never sees it.

**Outcome — Lists, paragraphs, and code blocks all working; LaTeX still raw.** All markdown structural elements now rendered correctly. LaTeX continued to display as raw `$...$` strings because `renderMathImage` still failed for every formula — the measurement-before-window bug from Attempt 9 had not yet been fixed.

---

### Attempt 14 — `dataWithPDF` Off-Screen Rendering

**Modification:** Replace `bitmapImageRepForCachingDisplay` with `dataWithPDF(inside:)` for capturing the `MTMathUILabel` render.

**Reasoning:** `dataWithPDF` was believed to work without a window-backed context.

**Outcome — Blank images.** `dataWithPDF` returned valid `Data` but `NSImage(data:)` produced blank images with no visual content. LaTeX remained raw. Additionally a compiler error: `Data` is non-optional so `guard let pdfData =` was invalid syntax.

---

### Attempt 15 — `lockFocus` + `display` Direct Draw

**Modification:** Use `NSImage.lockFocus()` and call `label.display(label.bounds)` to force drawing into a bitmap context without a window.

**Reasoning:** `lockFocus` establishes a graphics context that `display` should be able to draw into.

**Outcome — Blank images.** `display()` requires a window-backed graphics context. A standalone `NSView` not attached to any window skips its draw pass entirely when `display()` is called. All resulting images were blank.

**Future rule:** `MTMathUILabel` (and `NSView` subclasses in general) cannot render their content off-screen without being attached to a real `NSWindow`. `lockFocus`, `dataWithPDF`, and standalone `display()` all fail for this reason.

---

### Attempt 16 — Temporary `NSWindow` + Measure Before Attachment

**Modification:** Create an off-screen `NSWindow`, add `MTMathUILabel` as a subview, then call `bitmapImageRepForCachingDisplay`.

**Reasoning:** Providing a real window backing should allow the label to draw correctly.

**Outcome — Still blank images.** `intrinsicContentSize` was called *before* the label was added to the window (before `layoutSubtreeIfNeeded` ran), returning zero. The size guard bailed out immediately. Every formula hit the raw-text fallback. The window approach was correct in principle but the measurement order was wrong.

---

### Attempt 17 — Window-Backed + Measure After Hierarchy Attachment

**Modification:** Add label to window first, call `layoutSubtreeIfNeeded`, then measure `intrinsicContentSize` / `fittingSize`.

**Reasoning:** Correct the measurement order from Attempt 16.

**Outcome — Images generated; still not displayed.** `renderMathImage` now returned valid `NSImage` objects. However, formulas still did not appear in the UI. Root cause: SwiftUI's `Text` view on macOS silently discards `NSTextAttachment` objects — images were being generated correctly but the display layer refused to render them. (Same fundamental issue as Attempt 7.)

---

### Attempt 18 — `NSTextField` `NSViewRepresentable` for `NativeMarkdownText`

**Modification:** Replace SwiftUI `Text` with an `NSTextField`-based `NSViewRepresentable` (`NativeMarkdownText`), which natively supports `NSTextAttachment` rendering.

**Reasoning:** Fix the attachment-ignored problem from Attempt 17 by using an AppKit view that does render attachments.

**Outcome — Still raw LaTeX; text too small.** `renderMathImage` was still using the pre-fix version from Attempt 16 (measurement before window), so images were still blank and the raw-text fallback fired. Text appeared smaller than the rest of the UI because `NSTextField` has a smaller default font than SwiftUI `Text`.

---

### Attempt 19 — Fix `renderMathImage` Measurement Order + Fix Font Size

**Modification:** (a) Fix measurement order in `renderMathImage` (measure after window attachment). (b) Post-process `NSMutableAttributedString` to raise any font under 13pt to 13pt.

**Reasoning:** Combine the correct window-backed rendering (Attempt 17) with the correct AppKit display layer (Attempt 18) and normalise font sizing.

**Outcome — Compiler errors.** `NSMutableAttributedString(NSAttributedString(attrStr))` is not a valid initialiser on macOS. Type inference for `.font` and `.bold` inside the enumeration closure failed. A leftover `tf.font = ...` line in `makeNSView` caused a brace mismatch compilation error.

---

### Attempt 20 — Cascade Damage to `SpotlightView`

**Modification:** Various edits to `MarkdownRenderer.swift` during the Attempt 19 compiler-error fixing cycle.

**Reasoning:** Attempting to resolve type errors introduced in Attempt 19.

**Outcome — Broken scope across files.** `MarkdownRendererView` and `LiveStreamingRendererView` structs were accidentally deleted or had closing braces corrupted during editing. `SpotlightView.swift` could no longer find them in scope (compile errors at lines 112, 115, 125). The type-checker timeout at line 112 was caused by a large `VStack` expression whose type could not be resolved due to the missing struct definitions.

**Future rule:** When fixing compiler errors in a renderer file, verify that all top-level struct definitions (`MarkdownRendererView`, `LiveStreamingRendererView`, `NativeMarkdownText`, etc.) still exist and have balanced braces before building. A brace count mismatch at any level silently removes everything that follows it from scope.

---

### Attempt 21 — ARC Crash Fix: Global Image Cache + `Coordinator` Text Cache + Explicit Label Detach

**Modification:**
- Add `_mathImageCache: [String: (NSImage, CGFloat)]` global cache; `renderMathImage` returns cached result on repeat calls without creating a new `NSWindow`.
- Add `Coordinator` class to `NativeMarkdownText` storing `lastText` and `cachedAttrStr`; `updateNSView` returns immediately when text is unchanged.
- Call `label.removeFromSuperview()` and `window.orderOut(nil)` in explicit order before the function returns, giving ARC a clean teardown.

**Reasoning:** `updateNSView` was being called by SwiftUI on every layout pass (not just on content change), causing rapid repeated `NSWindow` creation and destruction. SwiftMath's internal Objective-C objects were being released while still in use, corrupting ARC reference counts and producing `EXC_BAD_ACCESS` in `objc_release`.

**Outcome — Crash resolved; markdown and LaTeX rendering fully correct.** All formula images rendered, all markdown structure preserved, no crash. Live streaming still showed raw LaTeX because `cleanForLiveView` only stripped delimiter characters, leaving LaTeX content visible.

---

### Attempt 22 — Streaming Stutter Fix: Static Regex + Plain `Text` in `LiveStreamingRendererView`

**Modification:**
- Move `NSRegularExpression` patterns to `static let` properties on `LiveStreamingRendererView` (compiled once per process).
- Replace `Text(LocalizedStringKey(cleanForLiveView(...)))` with `Text(cleanForLiveView(...))` (plain string, no markdown parsing).
- Replace delimiter character stripping in `cleanForLiveView` with full-span regex replacement (`⌈math⌋` substitution).
- Strip raw markdown syntax characters (`**`, `##`, etc.) for clean live preview appearance.

**Reasoning:** `NSRegularExpression` was being recompiled on every streaming token (up to 30/s), blocking the main thread briefly each time and causing the batched/stutter appearance. `LocalizedStringKey` triggered SwiftUI's markdown parser on every token — unnecessary overhead since full rendering happens in `MarkdownRendererView` after the stream ends.

**Outcome — Smooth continuous streaming with clean live preview.** Tokens appear immediately as they arrive. Full markdown + LaTeX rendering activates correctly when the stream completes. No regressions to existing rendering.

---

## Quick Reference: Root Causes and Fixes

| Root Cause | Symptom | Fix |
|---|---|---|
| `MTMathUILabel` measured before window attachment | All math renders as raw `$...$` | Add to `NSWindow`, call `layoutSubtreeIfNeeded`, then measure |
| SwiftUI `Text` ignores `NSTextAttachment` on macOS | Math images generated but invisible | Use `NSTextField` via `NSViewRepresentable` |
| `AttributedString(markdown:)` collapses single `\n` | All paragraphs merge into one block | Split on blank lines first, feed one paragraph per `NativeMarkdownText` |
| Global newline replacement mutates LaTeX content | Multi-line math corrupted, raw output | Never mutate newlines in raw string; split paragraphs structurally |
| Tokenising on spaces or characters | Markdown syntax shattered, raw `**` visible | Never split on whitespace when input contains markdown; use block-level parsing |
| `FlowLayout` block splitting for inline math | Inline formulas forced onto new lines | Inline math must live inside the same text run as surrounding prose |
| `updateNSView` runs on every SwiftUI layout pass | `EXC_BAD_ACCESS` crash in `objc_release` | `Coordinator` cache: skip rebuild when `text` is unchanged |
| No cache for `renderMathImage` | Repeated `NSWindow` churn → ARC corruption | Global `_mathImageCache`; each formula renders its window exactly once |
| Missing `label.removeFromSuperview()` before window release | ARC race on SwiftMath ObjC internals | Explicitly detach label, then call `window.orderOut(nil)` |
| `NSRegularExpression` compiled per token in live view | Streaming batches/stutters | `static let` regex properties; compiled once at process start |
| `Text(LocalizedStringKey(...))` during streaming | Markdown parsing on every token, stutter | Use `Text(string)` during streaming; reserve markdown parsing for final render |
| `cleanForLiveView` strips only delimiter characters | Raw LaTeX content still visible during stream | Regex-replace entire matched span with a placeholder string |
| Brace mismatch during editing | Downstream structs disappear from scope | Always verify struct closing braces and brace count after editing a renderer file |
| `@ViewBuilder` closure contains `while` / complex control flow | Compiler error | Extract loop logic into a plain helper function returning `[String]` or similar |