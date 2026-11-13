# Third-party notices

## musl / Arm optimized-routines: `pow`

`src/runtime/pow.zig` is a port, and `src/runtime/pow_data.zig` a mechanical transcription,
of the following files from **musl libc as bundled with Zig 0.17.1**
(`lib/libc/musl/src/math/`), which in turn come from Arm's optimized-routines project:

| file | SHA-256 |
|---|---|
| `pow.c` | `b06f0a08d74fcff8cced7afa2c0e47e301e3e8a19c0de5becdec28cd7b014027` |
| `pow_data.c` | `2052ec913f9b4a2170a98a6fcbcd7694f5dec220036b00c36106a2b4b65a4c55` |
| `exp_data.c` | `c55dff64e369fe816cd8ce367064989bb119f85783599680d1a329031c660689` |

`tools/gen_pow_data.js` regenerates `pow_data.zig` from these files and refuses to run if
their hashes differ from the ones above (e.g. after a Zig upgrade), so a changed upstream
source can't slip in unnoticed.

Each source file is marked `Copyright (c) 2018, Arm Limited.` and
`SPDX-License-Identifier: MIT`; musl's `COPYRIGHT` file lists these math files as
"Copyright © 2017-2018 Arm Limited". The MIT license:

```
Copyright (c) 2018, Arm Limited.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
