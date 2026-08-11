# Standalone checks

One-off sanity checks an operator runs by hand to answer "is this
capability working on this host?". They are not part of a cycle and
nothing in the harness calls them.

| Script | Purpose |
|---|---|
| `Test-TesseractOcr.ps1` | OCR sanity check via Tesseract — open source, available on every host type |
| `Test-WinRtOcr.ps1` | OCR sanity check via the WinRT `Windows.Media.Ocr` engine (Windows only) |

```
pwsh test/check/Test-TesseractOcr.ps1 -ImagePath screenshot.png
pwsh test/check/Test-WinRtOcr.ps1
```

Both print the same shape of result, so running them on one image is how
you tell an engine problem from an image problem. `Test-WinRtOcr.ps1`
additionally demonstrates the modern-pwsh "closed access" behavior around
WinRT types — see [Workarounds](../../docs/workarounds.md).

The cycle's own OCR path does not go through either of these; it runs
through `Test.Tesseract.psm1` in [`../modules/`](../modules/), which
`Test-TesseractOcr.ps1` imports so the check and the cycle exercise the
same code.

The repo-wide encoding gate that used to sit next to these is now
[`tools/Test-AsciiNoBom.ps1`](../../tools/Test-AsciiNoBom.ps1) — it gates
commits and releases rather than a host capability.
