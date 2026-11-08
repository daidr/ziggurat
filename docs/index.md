---
layout: home

hero:
  name: Ziggurat
  text: 用 Zig 写桌面应用
  tagline: 自绘原生 UI 或系统 WebView 前端，一份 Zig 代码运行在 Windows、Linux 与 macOS。小内核、显式所有权，按需导入模块。
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: 简介
      link: /guide/introduction
    - theme: alt
      text: 原生 UI
      link: /ui/

features:
  - title: 小内核
    details: 核心只管理 App、窗口、生命周期与主线程调度。UI、WebView、IPC、系统设施、更新都是独立模块，不用就不链接。
  - title: 声明式原生 UI
    details: 构建函数从应用状态描述整棵视图树，控件直接绑定字段；弹性布局、主题、可访问性、动画与无窗口 Harness 测试一应俱全。
  - title: 系统 WebView
    details: Windows 用 WebView2，Linux 用 WebKitGTK，macOS 用 WKWebView。本地资源不经过 HTTP 服务器，页面与 Zig 通过类型化 IPC 往返。
  - title: 完整的桌面集成
    details: 菜单栏、上下文菜单、托盘、通知、全局快捷键、剪贴板、拖放、文件选择器、单实例、深链与文件关联。
  - title: 从开发到分发
    details: ziggurat 命令负责创建项目、热重建、跨平台构建、签名、安装程序、macOS 应用包与磁盘映像，以及 Ed25519 签名的自动更新。
  - title: 显式而可验证
    details: 没有全局分配器、隐藏线程池、阻塞 UI 等待或嵌套事件循环；空闲时不重绘、不轮询。每项能力都报告实际 capability。
---
