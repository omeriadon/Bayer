#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float pixelDissolveBayer[16] = {
    0.0, 8.0, 2.0, 10.0,
    12.0, 4.0, 14.0, 6.0,
    3.0, 11.0, 1.0, 9.0,
    15.0, 7.0, 13.0, 5.0
};

/// Shows a view through a 4×4 Bayer threshold in square cells: 1 is fully shown, 0 is gone,
/// and everything between thins out cell by cell instead of fading or blurring.
[[ stitchable ]] half4 pixelDissolve(float2 position, half4 color, float amount, float cell) {
    int2 index = int2(floor(position / max(cell, 1.0))) & 3;
    float threshold = (pixelDissolveBayer[index.y * 4 + index.x] + 0.5) / 16.0;
    return amount > threshold ? color : half4(0.0);
}

/// A scroll edge fade for one item, per pixel. `originX` is the item's left edge in the scroll view,
/// `width` the scroll view's width, and `leading`/`trailing` how wide each fade is right now; they grow
/// from nothing as there's more content past that edge. Cells are anchored to the scroll view, not the
/// item, so the pattern holds still while items slide through it.
[[ stitchable ]] half4 pixelEdgeFade(float2 position, half4 color, float originX, float width, float leading, float trailing, float cell) {
    float x = originX + position.x;
    float amount = 1.0;
    if (leading > 0.5) {
        amount = min(amount, x / leading);
    }
    if (trailing > 0.5) {
        amount = min(amount, (width - x) / trailing);
    }
    if (amount >= 1.0) {
        return color;
    }
    int2 index = int2(floor(float2(x, position.y) / max(cell, 1.0))) & 3;
    float threshold = (pixelDissolveBayer[index.y * 4 + index.x] + 0.5) / 16.0;
    return amount > threshold ? color : half4(0.0);
}
