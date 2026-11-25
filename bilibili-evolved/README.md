# AwayFromShorts PC · 顶栏收敛（Bilibili Evolved 插件）

B站「动态」入口在顶栏上，手指比脑子快，点进去就出不来。这个插件把它从顶栏里拿掉 ——
连「顶栏布局设置 → 元素呈现」里的那一项也一起拿掉，所以就算手滑去点眼睛图标，也点不回来。

同样属于 AwayFromShorts 的思路：**不是靠意志力，是让入口不存在。**

## 安装

1. 浏览器里已经装了 [Bilibili Evolved](https://github.com/the1812/Bilibili-Evolved)。
2. 打开 B站任意页面 → 左侧「设置」→ 「插件」。
3. 点「浏览」，选中本目录的 `away-from-shorts-pc.js`；或者把它的 URL 粘到插件页的输入框里点「添加」。
4. 提示安装成功后刷新页面。

安装后默认是 `feed` 模式：顶栏和布局设置里都不会再有「动态」。

## 三种模式

| 模式 | 效果 |
| --- | --- |
| `feed`（默认） | 只删「动态」：自定义顶栏、顶栏布局设置、以及原版顶栏的动态入口都没了 |
| `strict` | 再删「排行」「直播」 |
| `none` | **整个顶栏都不显示**（自定义顶栏 + 它的布局设置弹窗一起消失） |

切换方式：在 B站页面按 F12 打开控制台，执行下面任意一条，然后**刷新页面**：

```js
localStorage.setItem('afs-topbar-mode', 'strict') // 动态 / 排行 / 直播
localStorage.setItem('afs-topbar-mode', 'none')   // 整个顶栏都不要
localStorage.setItem('afs-topbar-mode', 'feed')   // 改回只删动态
localStorage.removeItem('afs-topbar-mode')        // 恢复默认（等于 feed）
```

> 改完刷新才生效：插件在页面加载时读取一次模式，不会边跑边改。

## 为什么不会「点回来」

插件做了两层：

1. **数据层**：Bilibili Evolved 的自定义顶栏在挂载时用 `customNavbar.items` 这个数据通道收集元素。
   插件在里面把目标元素直接 `splice` 掉，于是顶栏不渲染它，「顶栏布局设置 → 元素呈现」的列表里也没有它。
2. **样式层**：万一元素已经被渲染出来（比如插件装得晚、或者别的插件又把它加回来），
   还有 `display: none !important` 兜底；原版顶栏的动态链接也一并藏掉。

## 卸载

设置 → 插件 → 找到「AwayFromShorts PC · 顶栏收敛」→ 移除 → 刷新页面。
不需要手动清理样式，插件注入的 `<style>` 随页面刷新消失。

## 自测

```powershell
node test-away-from-shorts-pc.js
```

模拟了 Bilibili Evolved 的插件沙箱（`exports` 注入 + `eval`）、`customNavbar.items` 数据流和
样式注入，覆盖默认/strict/none/非法值/异常输入五种情况。改完插件记得跑一遍。

## 注意

- 依赖 Bilibili Evolved 2.x 的「自定义顶栏」组件；没开这个组件时，插件只负责藏原版顶栏的动态入口。
- `none` 模式下搜索、消息、收藏这些入口也一起没了；只想眼不见心不烦用一个 `feed` 就够了。
- 插件只动 B站自己的顶栏，不改 hosts、不碰浏览器其它页面。
