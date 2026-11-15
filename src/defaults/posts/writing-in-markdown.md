---
title: writing in markdown
date: 2026-11-15
tags: zerverg, markdown
---

Entries can be **Markdown** as well as HTML. Write them in the console's
*Write* view, or upload a `.md` file. The header between the `---`
lines holds the same fields as the `zerverg:*` meta tags of HTML posts:
`title`, `date`, `tags`, `kind` (post or page), `layout` and `slug`.

## what you can write

- *emphasis*, **strong**, ~~struck~~ and `code`
- [links](/docs) and images: `![alt](media:zerverg-logo.svg)`
- lists, > quotes, tables and fenced code blocks
- raw HTML, whenever Markdown is not enough

| syntax | becomes |
|:-------|:--------|
| `# title` | a heading |
| `---` | a rule |
| `::: name` | a styled block |

## blocks

Markdown only says *what* things are. How they look is up to the
stylesheet. A fenced block gives a piece of text a name:

::: tip
This is a `::: tip` block. The default theme also knows `note`,
`warning`, `columns`, `card` and `center`.
:::

::: columns
::: card
**Any name works.** Write `::: pricing` and style `.pricing` in your
stylesheet.
:::
::: card
**Blocks nest**, so a `columns` block can hold cards, quotes or images.
:::
:::

The stylesheet is yours to change: open *Styles* in the console and
edit it, or start from a copy.
