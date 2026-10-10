#version 320 es
precision mediump float;
#include <impeller/color.glsl>
uniform vec4 u_color;
uniform vec2 u_resolution;
out vec4 frag_color;
void main() {
  frag_color = u_color;
}
