ODIN ?= odin
GLSLC ?= glslc
CC ?= cc
AR ?= ar
OUT ?= target/synapse
FREETYPE_CFLAGS := $(shell pkg-config --cflags freetype2)

ODIN_SOURCES := $(wildcard src/*.odin)
SHADER_SOURCES := src/shaders/graph.vert src/shaders/graph.frag
SHADER_BINARIES := target/shaders/vert.spv target/shaders/frag.spv

.PHONY: all shaders check clean

all: $(OUT)

shaders: $(SHADER_BINARIES)

target/shaders/vert.spv: src/shaders/graph.vert
	mkdir -p $(@D)
	$(GLSLC) $< -o $@

target/shaders/frag.spv: src/shaders/graph.frag
	mkdir -p $(@D)
	$(GLSLC) $< -o $@

target/font_bridge.o: src/font_bridge.c
	mkdir -p $(@D)
	$(CC) $(FREETYPE_CFLAGS) -O2 -fPIC -c $< -o $@

target/libfont_bridge.a: target/font_bridge.o
	$(AR) rcs $@ $<

$(OUT): $(ODIN_SOURCES) $(SHADER_BINARIES) target/libfont_bridge.a
	mkdir -p $(dir $(OUT))
	$(ODIN) build src -out:$(OUT) -o:speed

check: shaders target/libfont_bridge.a
	$(ODIN) check src

clean:
	rm -rf target
