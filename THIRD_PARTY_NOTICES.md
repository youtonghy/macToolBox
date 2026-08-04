# Third Party Notices

This project includes backend/data-interface work derived from the following
MIT-licensed open source projects:

- macmon, Copyright (c) 2024 vladkens
  - Source reviewed: `/Volumes/BIGDISK/github/3p/macmon`
  - Migrated scope: IOReport Energy Model power-channel selection and power
    aggregation concepts for CPU, GPU, ANE, DRAM, and GPU SRAM.
- WhatCable, Copyright (c) 2026 Darryl Morley
  - Source reviewed: `/Volumes/BIGDISK/github/3p/whatcable`
  - Migrated scope: IOKit cable snapshot concepts, USB-PD identity/VDO parsing,
    per-port power-source options, USB3/CIO data transport metadata, DisplayPort
    transport metadata, and external adapter details.
  - The proprietary `Sources/WhatCablePlugins/` subtree was not migrated.
- MonitorControl, Copyright (c) 2017 MonitorControl contributors
  - Source reviewed: `/Volumes/BIGDISK/github/3p/MonitorControl`
  - Migrated scope: DDC/CI command transport concepts for Intel framebuffer I2C
    and Apple Silicon IOAVService paths, VCP luminance/contrast/audio/mute
    read/write packet construction, checksum validation, service matching,
    retry behavior, smooth brightness timing, slider value semantics, and media
    key routing behavior.
  - MonitorControl OSD, software dimming, updater, and preferences stack were
    not migrated.

- PaddleOCR / PaddlePaddle / PaddleX
  - Used by the local PP-OCRv6, PP-StructureV3 and PaddleOCR-VL worker paths.
  - Distributed under the Apache License, Version 2.0; see
    `Resources/OCRModels/PaddleOCR-NOTICE.txt` and the release worker lock file.

## MIT License

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
