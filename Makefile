ODIN ?= odin
GLSLC ?= glslc
CC ?= cc
AR ?= ar
OUT ?= target/synapse
FREETYPE_CFLAGS := $(shell pkg-config --cflags freetype2)

ODIN_SOURCES := $(wildcard app/*.odin)
SHADER_SOURCES := app/graph.vert app/graph.frag
SHADER_BINARIES := app/vert.spv app/frag.spv

.PHONY: all shaders check clean

all: $(OUT)

shaders: $(SHADER_BINARIES)

app/vert.spv: app/graph.vert
	$(GLSLC) $< -o $@

app/frag.spv: app/graph.frag
	$(GLSLC) $< -o $@

target/font_bridge.o: app/font_bridge.c
	mkdir -p $(@D)
	$(CC) $(FREETYPE_CFLAGS) -O2 -fPIC -c $< -o $@

target/libfont_bridge.a: target/font_bridge.o
	$(AR) rcs $@ $<

$(OUT): $(ODIN_SOURCES) $(SHADER_BINARIES) target/libfont_bridge.a
	mkdir -p $(dir $(OUT))
	$(ODIN) build app -out:$(OUT) -o:speed

check: shaders target/libfont_bridge.a
	$(ODIN) check app

clean:
	rm -rf target app/vert.spv app/frag.spv
