package main

import "core:testing"

free_test_links :: proc(links: [dynamic]Link) {
	for link in links {
		delete(link.id)
		delete(link.title)
	}
	delete(links)
}

@(test)
test_markdown_link_preserves_label :: proc(t: ^testing.T) {
	links := extract_links("[Link](./link.md)")
	defer free_test_links(links)

	if !testing.expect_value(t, len(links), 1) {return}
	testing.expect_value(t, links[0].id, "link")
	testing.expect_value(t, links[0].title, "Link")
}

@(test)
test_obsidian_link_preserves_target :: proc(t: ^testing.T) {
	links := extract_links("[[Obsidian style links work too|obsidian-links.md]]")
	defer free_test_links(links)

	if !testing.expect_value(t, len(links), 1) {return}
	testing.expect_value(t, links[0].id, "obsidian style links work too")
	testing.expect_value(t, links[0].title, "Obsidian style links work too")
}

@(test)
test_obsidian_alias_and_heading_do_not_change_target :: proc(t: ^testing.T) {
	links := extract_links("[[Notes/My Note.md#Heading|Readable alias]]")
	defer free_test_links(links)

	if !testing.expect_value(t, len(links), 1) {return}
	testing.expect_value(t, links[0].id, "notes/my note")
	testing.expect_value(t, links[0].title, "My Note")
}
