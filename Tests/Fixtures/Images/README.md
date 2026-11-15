# JPEG fixtures

Synthetic images only: ffmpeg's built-in test patterns (`testsrc2` asked
for 99x67, which it makes 98x66; `testsrc` at 257x131; `mandelbrot` at
320x240), encoded with
libjpeg-turbo 3.2.1's `cjpeg` and `jpegtran`. Each `.png` is the same file
decoded by `djpeg -ppm` (default settings: integer IDCT, fancy upsampling),
which the check `render.jpeg` must match exactly.

| File | Made with |
|---|---|
| baseline-420 | `cjpeg -quality 85 -sample 2x2` (testsrc2) |
| baseline-422 | `cjpeg -quality 85 -sample 2x1` (testsrc2) |
| baseline-444 | `cjpeg -quality 90 -sample 1x1` (testsrc2) |
| baseline-440 | `cjpeg -quality 85 -sample 1x2` (testsrc2) |
| baseline-411 | `cjpeg -quality 85 -sample 4x1` (testsrc) |
| grey | `cjpeg -quality 80 -grayscale` (testsrc2) |
| rgb | `cjpeg -quality 88 -rgb` (testsrc2; no colour transform) |
| restart-optimized | `cjpeg -quality 80 -sample 2x2 -restart 3 -optimize` (testsrc) |
| coarse-16bit-tables | `cjpeg -quality 2 -sample 2x2` (16-bit quantisation tables) |
| progressive-420 | `cjpeg -quality 85 -sample 2x2 -progressive` (testsrc) |
| progressive-444-restart | `cjpeg -quality 92 -sample 1x1 -progressive -restart 2` (testsrc2) |
| progressive-mandel | `cjpeg -quality 75 -sample 2x2`, then `jpegtran -progressive` (mandelbrot) |
| arithmetic | `cjpeg -quality 85 -arithmetic`: must be refused with a clear error |

References were converted from PPM to PNG with `ffmpeg -pix_fmt rgb24`
(`gray` for grey).
