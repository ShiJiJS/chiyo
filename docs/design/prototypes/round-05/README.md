# round05 已确认视觉基线

来自2026-10-16的HTML设计探索，保留原型而非生产软件。所有示例为虚构；不接入真实数据。后续D0仍需补齐审计缺口及实施契约状态，不能把复制资产算作完成D0。

从本目录运行 `python -m http.server 8795 --bind 127.0.0.1`，打开 `http://127.0.0.1:8795/index.html`。端口可自行替换；页面无需原video_viewer工作区。顶部导航切换模块，主题控件切换四主题。原单文件style-explorer重复嵌入字体，未复制；index为可维护的拆分版本，脚本/字体本地提供。

字体许可见fonts/OFL.txt；Alpine.js版本/许可证声明在vendor/alpine.min.js头部。audit-screens为原审计截图，不是Flutter实现证据。
