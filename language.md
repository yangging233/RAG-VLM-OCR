# 中英文切换方案

## 目标

为当前前端界面增加 `简体中文 / English` 切换能力，满足以下要求：

- 默认语言优先使用用户上次选择，其次根据浏览器语言推断
- 语言切换后即时生效，无需刷新页面
- 语言设置持久化到 `localStorage`
- 不影响现有后端接口和数据结构
- 先覆盖 UI 文案、按钮、提示、Toast、空状态、标题
- 不翻译用户上传的文件名、知识库名称、后端返回的业务数据正文

## 当前项目现状

当前前端没有 i18n 基础设施，文案主要是直接写死在组件里。

典型位置：

- `frontend/App.tsx`
- `frontend/components/Sidebar.tsx`
- `frontend/components/Header.tsx`
- `frontend/components/Dashboard.tsx`
- `frontend/components/KnowledgeBase.tsx`
- `frontend/components/KnowledgeBaseDetail.tsx`
- `frontend/components/DocumentViewer.tsx`
- `frontend/components/UploadDialog.tsx`
- `frontend/components/Chat.tsx`
- `frontend/components/RetrievalTest.tsx`
- `frontend/components/Settings.tsx`

另外，`frontend/components/Settings.tsx` 里已经有一个“语言”下拉框，但目前只是静态 UI，没有真正驱动全局语言切换。

## 推荐方案

推荐先采用“项目内轻量 i18n 方案”，不要一上来接 `i18next`。

原因：

- 当前前端是单页 Vite + React 项目，结构简单
- 文案量中等，自己维护字典成本可控
- 先做轻量方案改动最小，后续如果语言数量增加，再迁移到成熟库也不晚
- 可以避免额外引入依赖、插件配置和运行时复杂度

## 推荐目录结构

建议新增以下文件：

```text
frontend/src/i18n/
  index.ts
  types.ts
  messages/
    zh-CN.ts
    en-US.ts
  I18nProvider.tsx
  useI18n.ts
  format.ts
```

职责建议：

- `types.ts`
  定义 `Locale = 'zh-CN' | 'en-US'`
- `messages/zh-CN.ts`
  中文文案字典
- `messages/en-US.ts`
  英文文案字典
- `index.ts`
  导出字典、默认语言、工具函数
- `I18nProvider.tsx`
  提供全局语言状态、切换函数、翻译函数
- `useI18n.ts`
  组件内获取 `t`, `locale`, `setLocale`
- `format.ts`
  放时间、数字、相对时间等本地化格式化工具

## 语言状态设计

建议的全局状态：

```ts
type Locale = 'zh-CN' | 'en-US'

interface I18nContextValue {
  locale: Locale
  setLocale: (locale: Locale) => void
  t: (key: string, params?: Record<string, string | number>) => string
}
```

初始化优先级：

1. `localStorage.getItem('app.locale')`
2. `navigator.language`
3. 默认 `zh-CN`

持久化键名建议：

```ts
app.locale
```

## 文案组织方式

建议采用“扁平 key + 功能域前缀”。

示例：

```ts
{
  "nav.dashboard": "仪表盘",
  "nav.knowledge": "知识库管理",
  "nav.chat": "对话",
  "header.running": "运行中",
  "dashboard.emptyChats": "暂无对话记录",
  "chat.newConversation": "开始新对话",
  "upload.selectFiles": "选择文件",
  "upload.uploading": "上传中...",
  "settings.language": "语言",
  "common.confirm": "确定",
  "common.cancel": "取消"
}
```

不建议把文案按深层嵌套对象组织得太复杂，否则查找和迁移成本会升高。

## 插值与动态文案

需要支持变量插值，因为当前界面有大量动态文案。

示例：

```ts
t('chat.messageCount', { count: messages.length })
t('knowledge.totalCount', { count: knowledgeBases.length })
t('document.pageRange', { start: chunk.page_start, end: chunk.page_end })
```

字典内容示例：

```ts
"chat.messageCount": "{count} 条消息"
"knowledge.totalCount": "{count} 个知识库"
"document.pageRange": "第 {start}-{end} 页"
```

英文：

```ts
"chat.messageCount": "{count} messages"
"knowledge.totalCount": "{count} knowledge bases"
"document.pageRange": "Pages {start}-{end}"
```

## 时间与数字格式化

当前项目中存在很多手写中文相对时间逻辑，例如：

- `刚刚`
- `xx分钟前`
- `xx小时前`
- `xx天前`

建议统一收敛到 `frontend/src/i18n/format.ts`，用 `Intl.RelativeTimeFormat` 或统一 helper 处理。

建议提供：

- `formatRelativeTime(date, locale)`
- `formatDate(date, locale)`
- `formatNumber(value, locale)`

这样可以避免每个组件自己拼中英文时间文案。

## 组件落地顺序

建议分 3 批做，不要一次性全改。

### 第一批：全局框架

- `frontend/main.tsx`
- `frontend/App.tsx`
- `frontend/components/Header.tsx`
- `frontend/components/Sidebar.tsx`
- `frontend/components/Settings.tsx`

目标：

- 建立 `I18nProvider`
- 打通全局语言状态
- 在 Settings 页实现真正可切换的语言下拉框
- 先让导航、页头、系统级文案可切换

### 第二批：核心业务页面

- `frontend/components/Dashboard.tsx`
- `frontend/components/KnowledgeBase.tsx`
- `frontend/components/KnowledgeBaseDetail.tsx`
- `frontend/components/UploadDialog.tsx`
- `frontend/components/DocumentViewer.tsx`

目标：

- 覆盖知识库管理、上传、文档查看主链路
- 处理 Toast、空状态、表单标签、按钮文本

### 第三批：交互复杂区域

- `frontend/components/Chat.tsx`
- `frontend/components/RetrievalTest.tsx`
- `frontend/components/ConfirmDialog.tsx`

目标：

- 覆盖对话、检索测试、确认弹窗
- 处理动态文本和参数插值

## Settings 页面改造建议

当前 `Settings.tsx` 里的“语言”项应改为真正的受控组件。

建议：

- value 绑定全局 `locale`
- onChange 时调用 `setLocale`
- 切换后立刻写入 `localStorage`

建议选项值：

```ts
[
  { value: 'zh-CN', label: '简体中文' },
  { value: 'en-US', label: 'English' }
]
```

不要把国旗 emoji 作为唯一识别方式，文本标签必须清晰。

## Toast 与错误信息处理

当前很多 Toast 文案直接写在组件中，例如：

- 获取知识库列表失败
- 上传成功
- 上传失败
- 对话失败

建议统一用 `t(...)` 替换。

注意两类信息分开处理：

1. 前端固定文案
   直接翻译
2. 后端返回错误消息
   保留原样，或做“固定前缀 + 后端原文”

例如：

```ts
toast.error(t('upload.failed'), {
  description: backendMessage || t('common.unknownError')
})
```

## 数据字段翻译边界

建议翻译：

- 页面标题
- 菜单
- 按钮
- 表单标签
- 占位符
- 提示语
- Toast
- 空状态
- Tabs
- 状态文案

不建议翻译：

- 用户输入的知识库名称
- 上传文件名
- Markdown 正文
- 文档内容
- 后端返回的原始 chunk 文本
- 模型名、API 名称、协议字段名

## 代码风格建议

建议在组件里这样使用：

```ts
const { t, locale, setLocale } = useI18n()
```

不要在组件中直接 import 某个语言包，也不要在组件里手写：

```ts
locale === 'zh-CN' ? '知识库管理' : 'Knowledge Base'
```

这种写法后期会失控。

## 字典拆分建议

如果后续文案继续增长，可以进一步拆分：

```text
messages/
  zh-CN/
    common.ts
    nav.ts
    dashboard.ts
    knowledge.ts
    upload.ts
    chat.ts
    settings.ts
  en-US/
    common.ts
    nav.ts
    dashboard.ts
    knowledge.ts
    upload.ts
    chat.ts
    settings.ts
```

第一版不一定要拆这么细，但 key 命名最好从第一天就按模块规划。

## 风险点

需要注意的点：

- 现有中文文案数量很多，第一次替换很容易漏
- `Toast`、`placeholder`、空状态最容易漏改
- 相对时间函数如果不统一，会出现部分中文部分英文
- 某些后端消息本身就是中文，切英文 UI 时可能仍出现中文错误描述
- `Settings.tsx` 当前很多配置是静态示例值，语言切换接进去时要避免把“示例数据”和“真实配置”混在一起

## 验收标准

建议按下面的标准验收：

- 初次进入页面时，能自动读取已保存语言
- 在 Settings 中切换语言后，侧边栏、页头、按钮、表单文案即时变化
- 刷新页面后语言保持不变
- Toast 文案随语言变化
- Dashboard、KnowledgeBase、UploadDialog、Chat 四个主页面无明显漏翻
- 相对时间和数字格式符合当前语言
- 没有因为语言切换导致组件重新挂载后丢失关键页面状态

## 推荐实施顺序

建议按下面顺序实际开发：

1. 新建 `i18n` 目录和 `I18nProvider`
2. 在 `main.tsx` 挂载 Provider
3. 改 `App.tsx`、`Sidebar.tsx`、`Header.tsx`
4. 让 `Settings.tsx` 真的控制全局语言
5. 改 `Dashboard.tsx`
6. 改 `KnowledgeBase.tsx`、`KnowledgeBaseDetail.tsx`
7. 改 `UploadDialog.tsx`
8. 改 `DocumentViewer.tsx`
9. 改 `Chat.tsx`
10. 改 `RetrievalTest.tsx` 与 `ConfirmDialog.tsx`
11. 补全漏掉的 Toast、占位符、状态文本
12. 统一相对时间格式化

## 最终建议

如果你要的是“尽快上线可用的中英文切换”，建议：

- 第一阶段只做 `zh-CN / en-US`
- 采用项目内轻量字典方案
- 优先覆盖主路径页面
- 不做后端国际化
- 不做 URL 级语言路由
- 不做复杂 ICU plural 规则

这样改动最稳，投入最可控，也最适合当前这个项目。
