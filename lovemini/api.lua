-- The functions LOVE 11.5 has in love.graphics and love.window (from its
-- wrap_Graphics.cpp, wrap_Graphics.lua and wrap_Window.cpp). report.lua stubs only
-- these when love-mini lacks one: a name LOVE does not have stays nil, as in LOVE,
-- so games that test for a function (love.graphics.toPixels or ...) see the truth.

return {
graphics = {
  "reset", "clear", "discard", "present", "newImage", "newArrayImage", "newVolumeImage",
  "newCubeImage", "newQuad", "newFont", "newImageFont", "newSpriteBatch", "newParticleSystem",
  "newCanvas", "newShader", "newMesh", "newText", "validateShader", "setCanvas", "getCanvas",
  "setColor", "getColor", "setBackgroundColor", "getBackgroundColor", "setNewFont", "setFont",
  "getFont", "setColorMask", "getColorMask", "setBlendMode", "getBlendMode", "setDefaultFilter",
  "getDefaultFilter", "setDefaultMipmapFilter", "getDefaultMipmapFilter", "setLineWidth",
  "setLineStyle", "setLineJoin", "getLineWidth", "getLineStyle", "getLineJoin", "setPointSize",
  "getPointSize", "setDepthMode", "getDepthMode", "setMeshCullMode", "getMeshCullMode",
  "setFrontFaceWinding", "getFrontFaceWinding", "setWireframe", "isWireframe", "setShader",
  "getShader", "getSupported", "getCanvasFormats", "getImageFormats", "getRendererInfo",
  "getSystemLimits", "getTextureTypes", "getStats", "captureScreenshot", "draw", "drawLayer",
  "drawInstanced", "print", "printf", "isCreated", "isActive", "isGammaCorrect", "getWidth",
  "getHeight", "getDimensions", "getPixelWidth", "getPixelHeight", "getPixelDimensions",
  "getDPIScale", "setScissor", "intersectScissor", "getScissor", "stencil", "setStencilTest",
  "getStencilTest", "points", "line", "rectangle", "circle", "ellipse", "arc", "polygon",
  "flushBatch", "getStackDepth", "push", "pop", "rotate", "scale", "translate", "shear", "origin",
  "applyTransform", "replaceTransform", "transformPoint", "inverseTransformPoint", "newVideo"
},
window = {
  "getDisplayCount", "getDisplayName", "setMode", "updateMode", "getMode", "getDisplayOrientation",
  "getFullscreenModes", "setFullscreen", "getFullscreen", "isOpen", "close", "getDesktopDimensions",
  "setPosition", "getPosition", "getSafeArea", "setIcon", "getIcon", "setVSync", "getVSync",
  "setDisplaySleepEnabled", "isDisplaySleepEnabled", "setTitle", "getTitle", "hasFocus",
  "hasMouseFocus", "isVisible", "getDPIScale", "getNativeDPIScale", "toPixels", "fromPixels",
  "minimize", "maximize", "restore", "isMaximized", "isMinimized", "showMessageBox",
  "requestAttention"
},
}
