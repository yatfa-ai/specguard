# Design System — inherited from yatfa

> SpecGuard does **not** design its own UI. It inherits yatfa's design system wholesale — the same
> tokens, the same component library, the same layout conventions, and the same drift lint. This is
> a **hard decision, not a recommendation**: SpecGuard's dashboard should look like another page of
> yatfa, so the operator never has to redesign the visual layer.

## Why inherit, not design

1. **Consistency.** SpecGuard is a yatfa dogfooding case. A user who knows yatfa's UI must find
   SpecGuard instantly familiar — same panels, same buttons, same spacing, same dark theme.
2. **No rework.** Every visual decision yatfa already made — the `app-` token prefix that dodges
   DaisyUI v5 collisions, the 4-step type ramp, the full-width layout, the panel-border fix, the
   drift lint — is a decision SpecGuard does **not** reopen. Agents build on the foundation; they
   don't redesign it. This is the "don't make me redo it 25 times" rule, encoded.

## The inheritance mechanism — what to port, and how

At **Phase 1 scaffold**, port these artifacts **verbatim** from the yatfa Rails app into `specguard`,
then evolve SpecGuard-specific surfaces on top of them:

| Artifact | yatfa source | What it gives SpecGuard |
|---|---|---|
| CSS foundation | `app/assets/stylesheets/application.tailwind.css` | `--app-*` tokens, `@theme inline` → `app-*` utilities, type ramp, `form-grid`, `prose`, sidebar |
| Component base | `app/components/application_component.rb` | `merge_classes`, the initializer-block `render_in` capture |
| UI namespace + primitives | `app/components/ui.rb` + `app/components/ui/*` | Panel/Card/Button/Badge/Alert/Page/PageHeader/PageNav/Breadcrumb/Stat/Meter/Table/DefList/EmptyState/Heading/Dropdown |
| Form components | `app/components/forms/*` | `Forms::FieldComponent` + `Forms::FormBuilder` |
| Drift lint | `lib/yatfa/design_system_lint.rb` + `config/lint/design_system_drift_baseline.yml` + rake task | the 3 shrink-only rules |
| Stimulus conventions | `app/javascript/controllers/*` + `stimulus-rails` | controller naming + patterns |

**Rules of the port:**

- **Source of truth = the yatfa Rails repo.** Copy a **snapshot**, do not symlink — SpecGuard ships as
  a separate product/repo and must be deployable independently.
- **Pin at seed time.** When yatfa's design system later evolves, port the change as a deliberate,
  reviewable diff — never a silent drift.
- **Port only what's used.** Drop yatfa-specific CSS with no SpecGuard analog (`xterm`,
  `asciinema-player`, `trix-editor`, `.lifecycle-*`, the kanban priority safelist) — keep the
  token foundation + whatever the dashboard actually renders.
- **Rename the lint namespace** `Yatfa::DesignSystemLint` → `SpecGuard::DesignSystemLint`; the
  behavior is identical.

## Stack

| Layer | Choice |
|---|---|
| CSS | Tailwind **v4** (`@import "tailwindcss"`) — **no `tailwind.config.js`**; config lives in-CSS |
| Substrate | **DaisyUI v5** (`@plugin "daisyui" { themes: dark --default, winter; }`) — used as base; app colors come from `app-*` tokens, not DaisyUI's `primary`/`success` |
| Components | **ViewComponent** (`view_component` gem) — `UI::*` primitives |
| JS | **Stimulus** (`stimulus-rails`) + **Turbo** (full adoption) |
| Font | **Plus Jakarta Sans** (loaded via `<link>` in the layout, not `@import`) |
| Themes | `dark` (OLED, **default**) + `winter` (light), toggled by the `[data-theme]` attribute |

## Design tokens — the `--app-*` → `app-*` system

Every color/surface is a CSS custom property prefixed `--app-`, exposed as a Tailwind utility
prefixed `app-` via `@theme inline`. Two non-negotiable conventions (copied from yatfa YATFA-877/3081):

- **Uniform `app-` prefix on the utility name** — dodges DaisyUI v5's owned utilities (`primary`,
  `success`, …) and Tailwind's `border` width utility with one rule. Any `*-app-*` class is, by
  definition, a token reference.
- **`@theme inline` (not plain `@theme`)** — utilities reference `var(--app-*)` *directly*, so
  toggling `[data-theme]` recolors every utility at runtime. That is how the dark/light switch works
  without a rebuild. Do not "simplify" this to plain `@theme`.

### Core palette (dark — the default theme)

| Token | Value | Utilities |
|---|---|---|
| `--app-background` | `#020617` | `bg-app-background` |
| `--app-surface` | `#0F172A` | `bg-app-surface` |
| `--app-surface-raised` | `#1E293B` | `bg-app-surface-raised` |
| `--app-primary` | `#0F172A` | `bg/text/border-app-primary` |
| `--app-secondary` | `#1E293B` | `bg/text/border-app-secondary` |
| `--app-cta` / `--app-cta-hover` | `#22C55E` / `#16A34A` | `bg-app-cta hover:bg-app-cta-hover` |
| `--app-text` | `#F8FAFC` | `text-app-content` |
| `--app-text-secondary` | `#94A3B8` | `text-app-content-secondary` |
| `--app-text-muted` | `#64748B` | `text-app-muted` |
| `--app-border` / `-light` | `#1E293B` / `#334155` | `border-app-border`, `border-app-border-light` |
| `--app-panel-border` | `#334155` | `border-app-panel-border` |
| `--app-shadow` | `0 1px 3px 0 rgba(0,0,0,.45), …` | `shadow-app` |

### Semantic

| Token | Value | Utilities |
|---|---|---|
| success | `#22C55E` | `bg/text/border-app-success`, `bg-app-success-surface` |
| warning | `#F59E0B` | `bg/text-app-warning`, `bg-app-warning-surface` |
| error | `#EF4444` | `bg/text-app-error`, `bg-app-error-surface` |
| info | `#3B82F6` | `bg/text-app-info`, `bg-app-info-surface` |
| neutral-surface | `rgba(148,163,184,.15)` | `bg-app-neutral-surface` |

Light theme (`[data-theme="winter"]`) **overrides every `--app-*`** with lighter values — port the
winter block from yatfa wholesale; do not hand-tune.

> ⚠️ **The panel-border trap.** In dark, `--app-border` is byte-identical to `--app-surface-raised`
> (`#1E293B`), so a 1px card border is literally invisible. yatfa added `--app-panel-border`
> (`#334155`) + `shadow-app`, **panel-scoped**, to make panels read as raised without touching the
> global border. Use `border-app-panel-border` + `shadow-app` on panels. Do **not** "fix" the global
> `--app-border` — it would blast every surface in the app.

## Typography — the 4-step ramp

Exactly one sanctioned heading ramp. Use these utilities (or `UI::HeadingComponent` /
`UI::PageHeaderComponent`, which wrap them). Color is **not** baked in — keep the heading's own
token color.

| Utility | Expands to |
|---|---|
| `text-app-h1` | `text-3xl font-bold tracking-tight` |
| `text-app-h2` | `text-xl font-bold tracking-tight` |
| `text-app-h3` | `text-lg font-semibold` |
| `text-app-h4` | `text-sm font-semibold` |

Never write `text-xl/2xl/3xl/4xl` directly — the drift lint flags it (and there is no reason to:
the ramp covers every signed-in heading).

## Layout conventions

- **Full-width.** `<main>` has **no `max-width` cap**. Forms use `.form-grid` (responsive 2-col
  grid) + `.form-field-full` (col-span-2) — never bespoke per-form widths.
- **Chrome:** sidebar (`--sidebar-width: 256px`, collapsed 68px) + topbar (`--topbar-height: 56px`).
- **Card/panel pattern:** `UI::PanelComponent` (preferred) or `card bg-base-100 shadow-md`; panels
  carry `border-app-panel-border` + `shadow-app`.
- **Section labels:** `text-xs uppercase tracking-wider opacity-40`.
- **Page title:** `text-app-h2` or `UI::PageHeaderComponent` (title is `text-3xl :lg`, matching
  `text-app-h1`).
- **Numbers/stats:** `tabular-nums`.
- **Focus ring:** global `:focus-visible { outline: 2px solid var(--app-cta); outline-offset: 2px }`.
- **Reduced motion:** respected globally (`prefers-reduced-motion` zeroes transitions).

## Component library (`UI::*`)

All inherit `ApplicationComponent`, which provides:

- `merge_classes(base, extra)` — de-duplicated composition of variant classes + caller overrides.
- the initializer-block `render_in` capture — so `render UI::ButtonComponent.new(variant: :primary) { "Save" }`
  works (Ruby's braces bind to `.new`, not `render`; the base class re-injects the block at render
  time). **Do not remove this** when porting — view call sites depend on the brace form.

### Call pattern

```erb
<%= render UI::ButtonComponent.new(variant: :primary) { "Save" } %>
<%= render UI::ButtonComponent.new(variant: :ghost, href: repositories_path) { "Cancel" } %>

<%= render UI::PanelComponent.new(title: "Layer distribution") do %>
  …chart body…
<% end %>
```

### `UI::ButtonComponent` API

- **Variants:** `:primary :secondary :warning :ghost :danger` — all token-derived
  (`bg-app-cta`, `text-app-background`, …), zero hardcoded colors.
- **Sizes:** `:xs :sm :md :lg`.
- Renders a `<button>`, or an `<a>` when `href:` is given (covers link-styled-as-button navigation).
- For `button_to` (which emits its own `<button>` and can't nest one), use the class method:
  `UI::ButtonComponent.classes(variant: :primary, size: :sm, extra: "w-full")`.

### The rest — port from yatfa

`Panel` (header: title/icon/actions + body wrapper), `Card`, `Badge` (tones), `Alert`, `Page`,
`PageHeader`, `PageNav`, `Breadcrumb`, `Stat`, `Meter`, `Table`, `DefList`, `EmptyState`, `Heading`,
`Dropdown`. Plus `Forms::FormBuilder` + `Forms::FieldComponent`. **If a SpecGuard surface needs a
new primitive, add it to the library in yatfa's style — do not one-off it in a view.**

## Drift lint — the enforcement

Port `Yatfa::DesignSystemLint` → `SpecGuard::DesignSystemLint`, plus the baseline rake task
(`rake lint:design_system:update_baseline`). It is a pragmatic grep over signed-in view templates
with a **shrink-only** baseline: CI fails the moment a live offender count grows past the frozen
number. Three rules:

| Rule | Flags | Fix |
|---|---|---|
| `heading_sizes` | ad-hoc `text-xl`/`2xl`/`3xl`/`4xl` | use `text-app-h1..h4` / `UI::HeadingComponent` / `UI::PageHeaderComponent` |
| `raw_palette_colors` | raw Tailwind palette (`gray-900`, `red-500`, `white`…) | use the `app-*` token system (`text-app-content`, `bg-app-surface`, `text-app-error`…) |
| `raw_btn` | raw DaisyUI `btn`/`btn-*` | use `UI::ButtonComponent` |

- Regenerate with `rake lint:design_system:update_baseline` (shrink-safe by default; `FORCE=1` to
  accept growth — a visible baseline change reviewers must sign off on).
- **SpecGuard starts at baseline `0/0/0`** — it's greenfield, there is no legacy to grandfather.
  Any offender is a regression that fails CI from day one.

## Hard rules for SpecGuard UI work

1. **No new design language.** An uncovered surface → add a `UI::*` component (in yatfa's style),
   never a one-off in a view.
2. **No hardcoded colors or sizes in views.** `app-*` tokens + the type ramp only. The lint enforces.
3. **No raw `btn`.** Always `UI::ButtonComponent` (or `.classes` for `button_to`).
4. **No bespoke form widths.** `.form-grid` + `.form-field-full`.
5. **Both themes must work.** Every color comes from a `--app-*` token that has a winter override;
   never bake a dark-only hex into markup.
6. **Server-rendered.** Hotwire/Turbo + Stimulus, no SPA. Interactivity = a Stimulus controller
   following yatfa's naming (`<thing>_controller.js`, e.g. `copy_text_controller.js`,
   `collapse_controller.js`, `toast_controller.js`).
