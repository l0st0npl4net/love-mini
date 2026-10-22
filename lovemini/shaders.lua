-- Shaders for love-mini: no GLSL runs here. A shader is recognised by its text and
-- stood in for by an effect mini2d can do (a changed copy of the texture), or left out:
--   solid    the sprite in one colour, its alpha kept (a hit flash): drawn tinted
--   gray     luminance
--   invert   the colour inverted
--   noblack  pure black pixels left out (a shader that discards them, as for masks)
-- A profile can name the effect of a shader (by where it was made, "file.lua:12", or
-- its hash), "none" to leave it out, or a table { effect = …, post = function(u, lg) }:
-- post runs after the draws made with the shader, with its uniforms in u (name ->
-- value) and love.graphics, to draw what the shader would have (a fade, a wipe).
-- Shaders nobody stands in for are drawn without, and listed in the report.

local S = {}

S.EFFECTS = { solid = 0, gray = 1, invert = 2, noblack = 3 }

-- the text without comments, spaces and case: what the recognisers look at
function S.normalize(code)
  code = code:gsub("/%*.-%*/", ""):gsub("//[^\n]*", "")
  return code:gsub("%s+", ""):lower()
end

-- FNV-1a of the normalised text, 8 hex digits: a name for the shader in profiles
function S.hash(norm)
  local h = 2166136261
  for i = 1, #norm do
    h = bit.bxor(h, norm:byte(i))
    h = (h * 16777619) % 4294967296
  end
  return string.format("%08x", h)
end

local function has(n, pattern) return n:find(pattern) ~= nil end

-- The effect for a shader's normalised text, or nil; for a solid colour of the
-- shader's own, also that colour {r, g, b, a}.
function S.recognize(n)
  if not has(n, "vec4effect%(") then return nil end
  -- if (Texel(...).rgb == vec3(0.0)) discard;
  if has(n, "discard") and (has(n, "%.rgb==vec3%(0%.?0?%)") or has(n, "%.rgb==vec3%(0%)")) then
    return "noblack"
  end
  -- a colour of its own: return vec4(0.1, 0.1, 0.1, Texel(t, uv).a * 0.5)
  local r, g, b, rest = n:match("returnvec4%(([%d%.]+),([%d%.]+),([%d%.]+),([^;]-%.a[^;]*)%);")
  if r and not (r == "1.0" and g == "1.0" and b == "1.0") then
    local k = tonumber(rest:match("%.a%*([%d%.]+)%)*$") or "1") or 1
    return "solid", { tonumber(r), tonumber(g), tonumber(b), k }
  end
  -- return vec4(1.0); vec4(1.0, 1.0, 1.0, t.a); vec4(vec3(1.0), t.a); vec4(color.rgb, t.a)
  if has(n, "returnvec4%(1%.?0?%);") or has(n, "returnvec4%(1%.?0?,1%.?0?,1%.?0?,[^;]-%.a%)*;")
    or has(n, "returnvec4%(vec3%(1%.?0?%),[^;]-%.a%)*;") or has(n, "returnvec4%([%w_]+%.rgb,[^;]-%.a%)*;") then
    return "solid"
  end
  -- grayscale by the usual luminance weights (and nothing else: a glow's bright pass
  -- weighs luminance too, against a threshold it is sent)
  local plain = not has(n, "extern") and not has(n, "uniform") and not has(n, "if%(")
  if plain and has(n, "dot%(") and (has(n, "0%.299") or has(n, "0%.2126") or has(n, "0%.3,0%.59")) then
    return "gray"
  end
  if plain and (has(n, "vec3%(1%.?0?%)%-[%w_]+%.rgb") or has(n, "1%.0?%-[%w_]+%.rgb")) then
    return "invert"
  end
  return nil
end

-- What the profile says of a shader made at `origin` with hash `h`: effect name (or
-- false for none) and post function.
function S.fromProfile(profile, origin, h)
  local t = profile and profile.shaders
  if not t then return nil end
  local v = t[origin] or t[h]
  if v == nil then return nil end
  if v == "none" or v == false then return false end
  if type(v) == "string" then return v end
  if type(v) == "table" then return v.effect or false, v.post end
  return nil
end

return S
