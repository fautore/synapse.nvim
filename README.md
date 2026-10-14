# synapse.nvim

A Neovim extension that scans the repository containing the current buffer and opens its Markdown notes and Obsidian canvases as a knowledge graph in a native **Vulkan** window. The renderer and graph parser are written in [Odin](https://odin-lang.org/).

- `.md`, `.markdown`, and Obsidian `.canvas` files
- canvas file cards and links inside canvas text nodes
- `[[wiki links]]`, aliases, headings, and Markdown links to notes or canvases
- animated force-directed layout with center gravity and connection-weighted node sizing
- antialiased node and connector edges
- current-buffer node highlighted with the configured accent
- live in-window graph reload for Markdown and canvas changes, including changes made outside Neovim
- colors inherited from Neovim and updated live on `:colorscheme` changes
- terminal font detection for Kitty and Ghostty, with Fontconfig fallback
- smooth hover focus enlarges the node, highlights its neighbors/links, and labels it directly below the node
- mouse dragging pans the view or pins and moves nodes while neighbors respond physically
- event-driven idle mode stops physics and frame presentation after the graph settles
- GPU rendering through Vulkan; GLFW is used only for the native window/input
- repository detection via `.obsidian`, `.git`, or `.jj`

> Neovim floating windows cannot host an OS Vulkan surface. `:Synapse` therefore opens a separate native window owned by the Odin process.

## Requirements

- Neovim 0.10+
- [Odin](https://odin-lang.org/docs/install/)
- Vulkan loader and a Vulkan-capable driver
- GLFW 3 development/runtime library
- FreeType 2 development library, `pkg-config`, and a C compiler
- `glslc` from the Vulkan SDK (needed when building)

Odin's bundled `vendor:glfw` and `vendor:vulkan` bindings are used; no extra Odin packages are needed.

## Install

With `lazy.nvim`:

```lua
{
  "your-name/synapse.nvim",
  build = "make",
  opts = {},
  cmd = { "Synapse", "SynapseClose", "SynapseBuild" },
}
```

Or add the repository to `runtimepath` and run:

```sh
make
```

The plugin also builds lazily on the first `:Synapse` call if `target/synapse` is absent or older than the sources.

## Usage

Open a file in an Obsidian vault or Git/Jujutsu repository, then run:

```vim
:Synapse          " open the graph
:Synapse!         " close an existing graph and reopen it
:SynapseClose     " close the graph
:SynapseBuild     " rebuild shaders and the Odin application
```

Window controls:

| Input | Action |
|---|---|
| mouse wheel / `+` / `-` | zoom |
| left-drag the background or middle-drag | pan |
| left-drag a node | reposition it and pull connected nodes |
| arrows or `W A S D` | pan |
| `0` | reset view |
| hover | show the note title/path in the window title |
| `Esc` | close |

## Configuration

Configuration is optional:

```lua
require("synapse").setup({
  auto_build = true,
  odin = "odin",
  glslc = "glslc",
  hide_title_bar = false, -- hide native window decorations
  -- Usually detected from Kitty/Ghostty automatically:
  -- font = "0xProto Nerd Font", -- family name or a .ttf/.otf path
  -- font_size = 14,
  root_markers = { ".obsidian", ".git", ".jj" },
  highlight_groups = {
    background = "Normal",       -- background color
    foreground = "Normal",       -- hover label
    node = "Function",           -- connected notes
    edge = "Comment",            -- links
    muted = "NonText",           -- unlinked notes
    current = "DiagnosticWarn",  -- current-buffer note
  },
  -- root = "/fixed/vault", -- string or function(start_path) -> root
  -- executable = vim.fn.stdpath("data") .. "/synapse/synapse",
})
```

Directories such as `.git`, `.jj`, `.obsidian`, `node_modules`, `.direnv`, and `target` are skipped while scanning.

## Physics tuning

Runtime graph behavior is controlled by the constants grouped under
`// Physics tuning` near the top of `src/main.odin`:

| Constant | Effect |
|---|---|
| `PHYSICS_REPULSION` | node-to-node repulsive force |
| `PHYSICS_LINK_DISTANCE` | preferred connector length |
| `PHYSICS_LINK_STRENGTH` | connector spring strength |
| `PHYSICS_CENTER_GRAVITY` | pull toward the center |
| `PHYSICS_DAMPING` | retained inertia; closer to `1` coasts longer |
| `PHYSICS_MAX_SPEED` | velocity limit |
| `PHYSICS_SETTLE_ENERGY` | motion threshold below which settling starts |
| `PHYSICS_SETTLE_TIME_MS` | continuous quiet time in milliseconds before rendering sleeps |

Only measured kinetic energy and `PHYSICS_SETTLE_TIME_MS` stop the simulation;
there is no fixed runtime cutoff.

## Development

Project layout:

```text
src/                  Odin renderer and graph sources
src/font_bridge.c     FreeType bridge
src/shaders/          GLSL shader sources
target/shaders/       generated SPIR-V shaders
target/synapse        generated renderer executable
```

```sh
make check
make
./target/synapse --root /path/to/vault --current relative/note.md
```
