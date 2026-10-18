# Application icon

`application.ico` contains original geometric artwork at 16, 20, 24, 32, 40, 48, 64, 128 and 256 pixels. PNG payloads preserve 32-bit RGBA while keeping all nine images within 4,181 bytes. `icon.svg` is its editable geometric source.

Run `pwsh -File assets/generate-icon.ps1` with PowerShell 7 to regenerate the checked-in ICO without an image library. The generator uses four samples per axis for edges, writes the same geometry as the SVG, and uses the platform zlib implementation. Compressed output can differ with a different zlib version; the checked-in ICO is the build input.

Applications can supply their own ICO to `build_support/packaging.zig`; the runtime uses resource ID 101 for the application icon.
