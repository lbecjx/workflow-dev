<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Stack Standards — React + TypeScript

Load this file when the project uses React with TypeScript. These standards complement the universal coding-standards.md.

**Detection:** `package.json` has `react` in dependencies + `.tsx` files exist.

---

## Component Architecture

### One Component Per File

Each `.tsx` file exports exactly ONE component. The filename matches the component name.

```typescript
// file: Badge.tsx
export const Badge: React.FC<BadgeProps> = ({ label, color }) => { ... }
```

### Typed Props Pattern

Every component uses `React.FC<Props>` with an explicit `interface`:

```typescript
import type React from 'react'

interface StatCardProps {
  label: string
  value: string
  colorClass: string
  borderClass?: string  // optional marked with ?
}

export const StatCard: React.FC<StatCardProps> = ({ label, value, colorClass, borderClass }) => {
  return (...)
}
```

Rules:
- `interface` for props (not `type` — interfaces are extendable, show intent)
- `React.FC<Props>` pattern (not bare function)
- `import type React from 'react'` (type-only import)
- Optional props marked with `?`
- Named exports only (no `export default`)

### No Type Escape Hatches

- No `any` — use `unknown` and narrow, or define the actual type
- No `as` type assertions — unless the alternative is worse and it's commented why
- No `!` non-null assertions — handle the null case explicitly
- No `// @ts-ignore` or `// @ts-expect-error` without explaining the specific issue

### Atomic Design Folder Structure

```
src/components/
├── atoms/          # Smallest UI units: Badge, Avatar, Button, Input, AppLogo
├── molecules/      # Combinations of atoms: StatCard, SidebarItem, TabBar
├── organisms/      # Complex sections: TopBar, Sidebar, QuickStats, ProductDetail
└── templates/      # Page-level layouts: AppLayout
```

Classification:
- **Atom**: one semantic element, no children components, only HTML + styling
- **Molecule**: composes 2+ atoms into a reusable unit
- **Organism**: composes molecules/atoms into a major UI section (header, sidebar, modal)
- **Template**: defines page layout, slots for organisms

### DRY by Extraction

If the same or very similar markup appears in more than one place, extract it into a reusable component.

```typescript
// ❌ Repeated pattern
<span className="text-[9px] uppercase text-[#8b949e]">{label1}</span>
// ... elsewhere ...
<span className="text-[9px] uppercase text-[#8b949e]">{label2}</span>

// ✅ Extracted to atom
// src/components/atoms/Label.tsx
export const Label: React.FC<LabelProps> = ({ text }) => (
  <span className="text-[9px] uppercase text-[#8b949e]">{text}</span>
)
```

### Zero Coupling

- Components receive data via props or a state store — never reach into siblings or parents
- No business logic in presentational components
- No direct imports between siblings at the same atomic level (atoms don't import other atoms — molecules compose them)
- Don't define components inside other components (recreated every render)

---

## Hooks

### Dependencies Must Be Complete

```typescript
// ✅ All values used inside are in deps
useEffect(() => {
  fetchData(productId)
}, [productId])

// ❌ Missing dependency
useEffect(() => {
  fetchData(productId)
}, [])  // productId missing — stale closure bug
```

### Rules of Hooks

- Never call hooks conditionally (`if (x) useEffect(...)`)
- Never call hooks in loops
- Never call hooks in nested functions
- Custom hooks must start with `use`

### Cleanup

```typescript
useEffect(() => {
  const controller = new AbortController()
  fetchData({ signal: controller.signal })
  return () => controller.abort()  // cleanup on unmount/re-run
}, [dep])
```

Always clean up: event listeners, timers, abort controllers, subscriptions.

---

## State Management

- Keep state as close to where it's used as possible
- Lift state only when siblings need to share it
- Prefer derived values over redundant state (`const total = items.length` not `const [total, setTotal] = ...`)
- For complex state with multiple related fields: `useReducer` over multiple `useState`

### Picking a shared-state mechanism

Don't default silently either way — whether the project already has a mechanism in place or not, the question is the same: is it the right fit for the specific piece of shared state about to be added?

- **Project already uses one** (Zustand, Redux, Context, Jotai, whatever): the default is to keep using it — don't fragment the codebase with a second mechanism over a passing preference. But if what's about to be built genuinely strains the existing choice (e.g. the project is on Context and the new state updates on every keystroke, or it's on Redux for what turns out to be two simple toggles), that's worth flagging rather than silently working around it.
- **No mechanism decided yet** (new project, or first piece of shared state): don't just reach for a default and start coding.

In either case where there's a real question — no existing choice, or the existing one looks like a poor fit for what's coming next — if subagents are available, launch one to research what actually fits (app size, expected growth, team size/conventions, what's already in `package.json`, and — when one already exists — the concrete cost/benefit of introducing or switching mechanism) and bring back a recommendation with reasoning; otherwise, ask the human directly. Present the recommendation before writing code. Don't raise this for every task, though — only when there's a genuine fit question, not as a recurring prompt to reconsider settled infrastructure.

Fallback heuristic, for when a quick default is genuinely needed (a throwaway prototype, or the human says "just pick one"):

1. **Zustand first.** Minimal boilerplate, no provider tree, selective subscriptions (a component only re-renders when the slice it reads changes) — it covers the vast majority of "several components need this state" cases with the least ceremony.
2. **Context** only for state that changes rarely (theme, locale, auth session) or for dependency injection, never for frequently-updated shared state — every Context update re-renders every consumer, which is exactly the class of bug Zustand's selectors avoid.
3. **Redux (or Redux Toolkit) only when the app's real complexity justifies it** — time-travel debugging, a large team needing strict enforced patterns, or genuinely complex normalized state with heavy cross-cutting middleware. For a typical app's shared state, Redux is disproportionate: it brings action creators, reducers, and dispatch ceremony to solve a problem Zustand solves with a single hook. Don't reach for it by default.

---

## Performance

### Memoization

- `useMemo` for expensive computations that don't need to re-run every render
- `useCallback` for functions passed as props to memoized children
- Don't memoize everything — only when profiling shows a problem or the computation is obviously expensive

### Keys in Lists

```typescript
// ✅ Stable, unique key
{items.map(item => <Card key={item.id} {...item} />)}

// ❌ Index as key (breaks on reorder/filter)
{items.map((item, i) => <Card key={i} {...item} />)}
```

### Avoid Unnecessary Renders

- Don't create new objects/arrays in render that are used as props (triggers re-render of children)
- Don't define components inside other components (recreated every render)

---

## Styling (Tailwind)

Same principle as the state-management choice above: don't default silently either way — evaluate whether the styling approach in play is the right fit for what's about to be built, whether or not one is already established.

- **Project already uses Tailwind**: use its utility classes exclusively (no CSS modules, no styled-components mixed in) — this is the default case, no evaluation needed.
- **Project already uses a different, established approach** (CSS modules, styled-components, vanilla-extract, etc.): the default is to keep using it — don't silently introduce Tailwind alongside it over a passing preference. But if what's coming next is exactly the kind of work Tailwind is built for (a large new UI surface, a design system with many small reusable pieces, heavy responsive/state-variant styling) and the existing approach is visibly straining, that's worth surfacing rather than working around.
- **No styling approach decided yet** (new project, or it hasn't been chosen): don't just default to skipping Tailwind, and don't just default to using it either.

In either case where there's a real question — nothing decided yet, or the existing approach looks like a poor fit for what's coming next — if subagents are available, launch one to evaluate the fit (team familiarity, project type, design-system needs, bundle/build constraints, and — when something already exists — the concrete cost of introducing or migrating); if Tailwind (or a change) looks like the better call, present the case to the human — concrete advantages, not just "Tailwind is popular" (utility-first velocity, no naming/specificity fights, small production CSS via purging, consistent design tokens) — and let them decide before scaffolding or changing any styling. Without subagents available, ask the human directly. Don't raise this for every task — only when there's a genuine fit question, not as a recurring prompt to reconsider settled infrastructure.
- **Never hardcode hex colors in components** — define all colors as `@theme` tokens (or the project's existing token mechanism) and reference by name (`bg-bg`, `text-accent`, `border-border`)
- If a new color is needed, add it to the theme tokens first, then use the token name
- Arbitrary values (`bg-[#hex]`) are only acceptable for one-off values that don't represent a design token (e.g., `w-[280px]`)
- Responsive: mobile-first with `sm:`, `md:`, `lg:` breakpoints
- Inline styles are forbidden — use utility classes

---

## Imports

```typescript
// Type-only imports first
import type React from 'react'
import type { SomeType } from '@/types/registry'

// React hooks
import { useState, useEffect } from 'react'

// Third-party
import { useStore } from 'zustand'

// Internal components (by atomic level)
import { Badge } from '@/components/atoms/Badge'
import { StatCard } from '@/components/molecules/StatCard'

// Internal utilities
import { formatDate } from '@/utils/format'
```

- Use a path alias (commonly `@/`) for internal imports when the project has one configured — never relative `../../../` chains once an alias exists
- Type-only imports: `import type { X } from '...'` (helps tree-shaking, makes intent clear)
- Group: type-only → react → external packages → internal absolute (by atomic level) → relative

---

## Source Map Protection (Production Builds)

If touching build config (Vite, webpack, etc.):
- `sourcemap: false` must be EXPLICIT in production build config
- If server config exists (nginx, etc.): `.map` files should be blocked
- No source code, `node_modules`, or build tooling in final Docker image

---

## Anti-patterns

| Anti-pattern | Why |
|---|---|
| `export default` for components | Named exports are greppable and refactorable |
| `any` type | Defeats TypeScript's purpose |
| `as` type assertions | Masks type errors |
| `!` non-null assertions | Hides potential null bugs |
| Inline styles | Use utility classes instead |
| Multiple components per file | Violates one-component rule |
| Props without interface | Violates full-TS rule |
| Bare function components | Must use `React.FC<Props>` pattern |
| Copy-paste markup | Extract to component (DRY) |
| Business logic in components | Move to stores or utils |
| `console.log` in committed code | Remove before commit |
| Index as key in lists | Breaks on reorder/filter |
| `// @ts-ignore` without explanation | Hides real type errors |
