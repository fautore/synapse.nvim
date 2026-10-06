package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

Vec2 :: struct { x, y: f32 }

Note :: struct {
	path:  string,
	id:    string,
	title: string,
	pos:   Vec2,
	vel:   Vec2,
	links: [dynamic]string,
}

Edge :: struct { from, to: int }
Graph :: struct {
	notes: [dynamic]Note,
	edges: [dynamic]Edge,
}

is_ignored_directory :: proc(name: string) -> bool {
	return name == ".git" || name == ".jj" || name == ".obsidian" ||
	       name == "node_modules" || name == ".direnv" || name == "target"
}

is_markdown_file_name :: proc(name: string) -> bool {
	return (len(name) >= 3 && strings.equal_fold(name[len(name)-3:], ".md")) ||
	       (len(name) >= 9 && strings.equal_fold(name[len(name)-9:], ".markdown"))
}

normalize_id :: proc(raw: string) -> string {
	s := strings.trim_space(raw)
	if i := strings.index_byte(s, '|'); i >= 0 { s = s[:i] }
	if i := strings.index_byte(s, '#'); i >= 0 { s = s[:i] }
	s = strings.trim_space(s)
	for strings.has_prefix(s, "./") { s = s[2:] }
	lower := strings.to_lower(s)
	length := len(lower)
	if strings.has_suffix(lower, ".markdown") {
		length -= 9
	} else if strings.has_suffix(lower, ".md") {
		length -= 3
	}
	buf := make([]byte, length)
	for c, i in transmute([]byte)lower[:length] {
		buf[i] = c == '\\' ? '/' : c
	}
	delete(lower)
	return string(buf)
}

note_title :: proc(content, path: string) -> string {
	text := content
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "# ") {
			return strings.clone(strings.trim_space(trimmed[2:]))
		}
	}
	return strings.clone(filepath.stem(filepath.base(path)))
}

extract_links :: proc(content: string) -> [dynamic]string {
	result := make([dynamic]string)

	// Obsidian wiki links: [[note]], [[note#heading]], [[note|alias]].
	cursor := 0
	for cursor < len(content) {
		start_rel := strings.index(content[cursor:], "[[")
		if start_rel < 0 { break }
		start := cursor + start_rel + 2
		end_rel := strings.index(content[start:], "]]" )
		if end_rel < 0 { break }
		id := normalize_id(content[start:start+end_rel])
		if len(id) > 0 { append(&result, id) }
		cursor = start + end_rel + 2
	}

	// Ordinary Markdown links. External URLs and anchors are ignored.
	cursor = 0
	for cursor < len(content) {
		open_rel := strings.index(content[cursor:], "](")
		if open_rel < 0 { break }
		start := cursor + open_rel + 2
		end_rel := strings.index_byte(content[start:], ')')
		if end_rel < 0 { break }
		target := strings.trim_space(content[start:start+end_rel])
		if !strings.contains(target, "://") && !strings.has_prefix(target, "#") {
			if strings.has_suffix(strings.to_lower(target), ".md") || strings.contains(target, ".md#") {
				id := normalize_id(target)
				if len(id) > 0 { append(&result, id) }
			}
		}
		cursor = start + end_rel + 1
	}
	return result
}

hash_string :: proc(s: string) -> u64 {
	h: u64 = 1469598103934665603
	for c in s { h = (h ~ u64(c)) * 1099511628211 }
	return h
}

load_graph :: proc(root: string) -> (Graph, bool) {
	graph: Graph
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)

	for info in os.walker_walk(&walker) {
		if info.type == .Directory && is_ignored_directory(info.name) {
			os.walker_skip_dir(&walker)
			continue
		}
		if info.type != .Regular || !is_markdown_file_name(info.name) { continue }

		data, err := os.read_entire_file(info.fullpath, context.allocator)
		if err != nil {
			fmt.eprintfln("synapse: cannot read %s: %v", info.fullpath, err)
			continue
		}
		rel, rel_err := filepath.rel(root, info.fullpath)
		if rel_err != nil { rel = info.name }
		content := string(data)
		id := normalize_id(rel)
		h := hash_string(id)
		angle := f32(h % 10000) / 10000.0 * 2.0 * math.PI
		radius := 0.15 + f32((h >> 14) % 1000) / 1000.0 * 0.65
		note := Note{
			path = strings.clone(info.fullpath),
			id = strings.clone(id),
			title = note_title(content, info.fullpath),
			pos = {math.cos(angle) * radius, math.sin(angle) * radius},
			links = extract_links(content),
		}
		append(&graph.notes, note)
		delete(data)
	}

	if path, err := os.walker_error(&walker); err != nil {
		fmt.eprintfln("synapse: error walking %s: %v", path, err)
		return graph, false
	}

	by_id := make(map[string]int)
	by_name := make(map[string]int)
	ambiguous := make(map[string]bool)
	for note, i in graph.notes {
		by_id[note.id] = i
		name := filepath.base(note.id)
		if _, exists := by_name[name]; exists { ambiguous[name] = true } else { by_name[name] = i }
	}
	seen := make(map[u64]bool)
	for note, from in graph.notes {
		for target in note.links {
			to, found := by_id[target]
			if !found {
				name := filepath.base(target)
				if !ambiguous[name] { to, found = by_name[name] }
			}
			if !found || to == from { continue }
			a, b := from, to
			if a > b { a, b = b, a }
			key := (u64(u32(a)) << 32) | u64(u32(b))
			if !seen[key] { append(&graph.edges, Edge{a, b}); seen[key] = true }
		}
	}
	return graph, true
}

destroy_graph :: proc(graph: ^Graph) {
	for &note in graph.notes {
		delete(note.path)
		delete(note.id)
		delete(note.title)
		for link in note.links { delete(link) }
		delete(note.links)
	}
	delete(graph.notes)
	delete(graph.edges)
	graph^ = {}
}

layout_graph :: proc(graph: ^Graph) {
	n := len(graph.notes)
	if n < 2 { return }
	iterations := 220
	if n > 1000 { iterations = 90 }
	for step in 0..<iterations {
		t := 1.0 - f32(step) / f32(iterations)
		// Repulsion. For very large vaults, stride through a deterministic sample.
		stride := 1
		if n > 1200 { stride = n / 600 }
		for i in 0..<n {
			force := Vec2{}
			for j := (i + step) % stride; j < n; j += stride {
				if i == j { continue }
				dx := graph.notes[i].pos.x - graph.notes[j].pos.x
				dy := graph.notes[i].pos.y - graph.notes[j].pos.y
				d2 := dx*dx + dy*dy + 0.002
				s := 0.00035 / d2
				force.x += dx*s
				force.y += dy*s
			}
			graph.notes[i].vel.x += force.x
			graph.notes[i].vel.y += force.y
		}
		for edge in graph.edges {
			a, b := &graph.notes[edge.from], &graph.notes[edge.to]
			dx, dy := b.pos.x-a.pos.x, b.pos.y-a.pos.y
			d := math.sqrt(dx*dx + dy*dy + 0.0001)
			f := (d - 0.13) * 0.018
			x, y := dx/d*f, dy/d*f
			a.vel.x += x; a.vel.y += y
			b.vel.x -= x; b.vel.y -= y
		}
		for &note in graph.notes {
			note.vel.x += -note.pos.x * 0.002
			note.vel.y += -note.pos.y * 0.002
			note.vel.x *= 0.78; note.vel.y *= 0.78
			note.pos.x += note.vel.x * t
			note.pos.y += note.vel.y * t
		}
	}

	// Normalize to a stable view-independent coordinate range.
	max_extent: f32 = 0.01
	for note in graph.notes {
		max_extent = max(max_extent, max(abs(note.pos.x), abs(note.pos.y)))
	}
	for &note in graph.notes {
		note.pos.x /= max_extent * 1.12
		note.pos.y /= max_extent * 1.12
	}
}
