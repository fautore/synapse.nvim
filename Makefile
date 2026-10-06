ODIN ?= odin
GLSLC ?= glslc
OUT ?= target/synapse

.PHONY: all shaders check clean

all: $(OUT)

shaders: app/vert.spv app/frag.spv

app/vert.spv: app/graph.vert
	$(GLSLC) $< -o $@

app/frag.spv: app/graph.frag
	$(GLSLC) $< -o $@

$(OUT): app/main.odin app/graph.odin app/vert.spv app/frag.spv
	mkdir -p $(dir $(OUT))
	$(ODIN) build app -out:$(OUT) -o:speed

check: shaders
	$(ODIN) check app

clean:
	rm -rf target app/vert.spv app/frag.spv
