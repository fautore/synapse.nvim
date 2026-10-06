#include <ft2build.h>
#include FT_FREETYPE_H

#include <stdint.h>
#include <string.h>

typedef struct SynapseGlyph {
    int32_t x, y;
    int32_t width, height;
    int32_t bearing_x, bearing_y;
    float advance;
} SynapseGlyph;

int32_t synapse_bake_font(
    const char *path,
    float pixel_height,
    uint8_t *atlas,
    int32_t atlas_width,
    int32_t atlas_height,
    int32_t first_codepoint,
    int32_t codepoint_count,
    SynapseGlyph *glyphs,
    float *ascent_out)
{
    FT_Library library = NULL;
    FT_Face face = NULL;
    if (FT_Init_FreeType(&library) != 0) return 0;
    if (FT_New_Face(library, path, 0, &face) != 0) {
        FT_Done_FreeType(library);
        return 0;
    }

    FT_Set_Pixel_Sizes(face, 0, (FT_UInt)(pixel_height + 0.5f));
    memset(atlas, 0, (size_t)atlas_width * (size_t)atlas_height);
    *ascent_out = (float)face->size->metrics.ascender / 64.0f;

    int x = 1, y = 1, row_height = 0;
    for (int i = 0; i < codepoint_count; ++i) {
        uint32_t codepoint = (uint32_t)(first_codepoint + i);
        if (FT_Load_Char(face, codepoint, FT_LOAD_RENDER) != 0) continue;

        FT_GlyphSlot slot = face->glyph;
        FT_Bitmap *bitmap = &slot->bitmap;
        int width = (int)bitmap->width;
        int height = (int)bitmap->rows;
        if (x + width + 1 >= atlas_width) {
            x = 1;
            y += row_height + 1;
            row_height = 0;
        }
        if (y + height + 1 >= atlas_height) {
            FT_Done_Face(face);
            FT_Done_FreeType(library);
            return 0;
        }

        for (int row = 0; row < height; ++row) {
            const uint8_t *source = bitmap->buffer + row * bitmap->pitch;
            memcpy(atlas + (y + row) * atlas_width + x, source, (size_t)width);
        }

        glyphs[i].x = x;
        glyphs[i].y = y;
        glyphs[i].width = width;
        glyphs[i].height = height;
        glyphs[i].bearing_x = slot->bitmap_left;
        glyphs[i].bearing_y = slot->bitmap_top;
        glyphs[i].advance = (float)slot->advance.x / 64.0f;
        x += width + 1;
        if (height > row_height) row_height = height;
    }

    FT_Done_Face(face);
    FT_Done_FreeType(library);
    return 1;
}
