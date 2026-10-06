# synapse.nvim

A Neovim extension that scans the repository containing the current buffer and opens its Markdown notes as an Obsidian-style knowledge graph in a native **Vulkan** window. The renderer and graph parser are written in [Odin](https://odin-lang.org/).

- `[[wiki links]]`, aliases, headings, and Markdown links to `.md` files
- force-directed layout and degree-based node sizing
- current-buffer node highlighted in amber
- live in-window graph reload for Markdown changes, including changes made outside Neovim
- hover a node to show its title and repository-relative path
- GPU rendering through Vulkan; GLFW is used only for the native window/input
- repository detection via `.obsidian`, `.git`, or `.jj`

> Neovim floating windows cannot host an OS Vulkan surface. `:Synapse` therefore opens a separate native window owned by the Odin process.

## Requirements

- Neovim 0.10+
- [Odin](https://odin-lang.org/docs/install/)
- Vulkan loader and a Vulkan-capable driver
- GLFW 3 development/runtime library
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
  root_markers = { ".obsidian", ".git", ".jj" },
  -- root = "/fixed/vault", -- string or function(start_path) -> root
  -- executable = vim.fn.stdpath("data") .. "/synapse/synapse",
})
```

Directories such as `.git`, `.jj`, `.obsidian`, `node_modules`, `.direnv`, and `target` are skipped while scanning.

## Development

```sh
make check
make
./target/synapse --root /path/to/vault --current relative/note.md
```
