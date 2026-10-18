# 图标来源与编辑

`AppIcon.icon` 由 Apple Icon Composer 创建。图标采用纯蓝色背景、两半浅色手柄外壳和一体的中央连接，仅保留方向十字键和四颗动作按键，不使用 Nintendo 商标或产品标志。外壳和控件是两个独立的可编辑 SVG 层，画布为 1024 × 1024；手柄层关闭玻璃效果，保留系统图标边缘的渲染。

`01-controller-shell.svg` 的外轮廓改编自 [Lucide gamepad-2](https://github.com/lucide-icons/lucide/blob/main/icons/gamepad-2.svg)，改变了尺寸、填色和视觉用途。其余控件和连接图形为本项目绘制。

Lucide `gamepad-2` 使用 [ISC License](https://lucide.dev/license)，不在该项目列出的 Feather 派生图标中。

ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.
THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

Apple 制作说明：[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

`preview-default.png` 由 Icon Composer 随附的 `ictool` 导出，显示 macOS 默认外观、设计代际 26。可编辑工程已通过 Xcode 27 `actool` 编译，输出 `AppIcon.icns` 和 `Assets.car`，未使用适配器或访问手柄。
