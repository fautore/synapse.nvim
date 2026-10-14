<div align="center">

# synapse.nvim
##### Explore your Markdown notes as a native Vulkan knowledge graph.

[![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)](https://www.lua.org)
[![Neovim](https://img.shields.io/badge/Neovim%200.10+-green.svg?style=for-the-badge&logo=neovim)](https://neovim.io)
[![Odin](https://img.shields.io/badge/Odin-1E5184.svg?style=for-the-badge)](https://odin-lang.org)
[![Vulkan](https://img.shields.io/badge/Vulkan-red.svg?style=for-the-badge&logo=vulkan)](https://www.vulkan.org)

<img alt="Synapse logo" height="280" src="/docs/assets/synapse.svg" />
</div>

Synapse scans the project containing your current buffer and renders its Markdown notes and Obsidian canvases as a knowledge graph in a native **Vulkan** window. The renderer and graph parser are written in [Odin](https://odin-lang.org/).

## Features

- **Markdown and Canvas support** — indexes `.md`, `.markdown`, and Obsidian `.canvas` files, including canvas file cards and links in text nodes.
- **Link discovery** — resolves `[[wiki links]]`, aliases, headings, and standard Markdown links to notes or canvases, dead and ghost links are also supported.
- **Navigation** — explore an animated force-directed graph with zooming, panning, and responsive node dragging.
- **Highlights** — highlights the current note, hover over a node to highlight it and its neighbors.
- **Live reload** — reflects Markdown and canvas changes made inside or outside Neovim without reopening the graph.
- **Neovim-aware theme-ing** — inherits highlight colors from your active colorscheme and updates them on `:colorscheme` changes.
- **Terminal-aware fonts** — detects Kitty and Ghostty font settings, with Fontconfig as a fallback.
- **Efficient native rendering** — uses Vulkan for antialiased nodes and edges, then suspends physics and frame presentation once the graph settles to save on your precious CPU and GPU cycles.
- **Automatic project discovery** — finds roots through `.obsidian`, `.git`, or `.jj` while skipping common generated and metadata directories.

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
  "fautore/synapse.nvim",
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
    ghost = "LineNr",            -- unresolved links
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

# Contributing

PR welcome!
