# Nintendo Switch 2 Pro Controller 正面素材

文件：`ns2-pro-front.png`。

- 官方页面：[Nintendo Switch 2 専用周辺機器](https://www.nintendo.com/jp/hardware/switch2/accessories/index.html)。
- 官方原始 PNG：[controller_switcher_img01.png](https://www.nintendo.com/jp/hardware/switch2/accessories/assets/img/top/controller_switcher_img01.png)。页面当前使用相同图片的 `.webp` 版本，PNG 地址由任天堂同一资源服务器直接提供。
- 下载日期：2026-10-18。
- 尺寸：975 × 975 像素，RGBA，alpha 范围 0…255。
- 非透明内容边界：左 49、上 175、右 926、下 801（右／下为不包含的边界）。
- SHA-256：`7e0f3f3e7eb9d60da611d7d44b4b67eb6c65389be50703e42c5610024b7de4f8`。

图片按官方原文件保存，没有裁切、重绘、抠图、改色或 AI 处理。为保持覆盖位置一致，使用整个 975 × 975 画布等比显示；如果改用非透明内容区域裁切，必须同时换算覆盖坐标。

图片及产品标志版权归 Nintendo 所有，不属于本仓库 MIT 许可；公开下载地址不等于获得开放素材授权。来源说明不表示 Nintendo 与本项目存在关联或背书。

`front-hotspots.json` 的坐标由正面图人工读取，供界面覆盖使用，不是任天堂提供的机器标注。原点为左上角，x 向右、y 向下；归一化坐标使用原始像素位置除以 975。按键中心可按约 2–4 像素的视觉误差处理。摇杆值应在固定底座范围内绘制动态指示，不应挪动原始产品图片。

正面没有显示 GL／GR 的按键面，也无法准确分辨完整的 L／R／ZL／ZR 按键区域，因此没有为这些按键伪造正面中心坐标；这些状态可放在图片外侧独立标记。
