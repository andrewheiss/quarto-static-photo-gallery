-- Stringify a value that may be a pandoc Inlines/MetaInlines object
local function str_val(v)
  if v == nil then return nil end
  if type(v) == "string" then return v end
  if type(v) == "table" then
    -- pandoc.Inlines or MetaInlines
    local s = pandoc.utils.stringify(v)
    return s ~= "" and s or nil
  end
  return tostring(v)
end

-- ipairs({...}) stops at nil holes; use select to walk all varargs safely
local function coalesce(...)
  local n = select('#', ...)
  for i = 1, n do
    local s = str_val(select(i, ...))
    if s ~= nil and s ~= "" then return s end
  end
  return nil
end

-- Traverse a nested MetaMap and return the raw leaf node.
-- MetaMap .t is unreliable across pandoc versions, so we never inspect it;
-- instead we always use pandoc.utils.stringify at the leaf via meta_str().
local function meta_get(node, ...)
  local n = select('#', ...)
  for i = 1, n do
    local key = select(i, ...)
    if type(node) ~= "table" then return nil end
    node = node[key]
    if node == nil then return nil end
  end
  return node
end

-- Traverse and stringify the leaf value.
local function meta_str(node, ...)
  local v = meta_get(node, ...)
  if v == nil then return nil end
  if type(v) == "string" then return v ~= "" and v or nil end
  if type(v) == "boolean" then return tostring(v) end
  if type(v) == "table" then
    local s = pandoc.utils.stringify(v)
    return s ~= "" and s or nil
  end
  return tostring(v)
end

local function bool_val(v, default)
  if v == nil then return default end
  if type(v) == "boolean" then return v end
  local s = tostring(v):lower()
  if s == "true" or s == "1" or s == "yes" then return true end
  if s == "false" or s == "0" or s == "no" then return false end
  return default
end

local function int_val(v, default)
  if v == nil then return default end
  local n = tonumber(v)
  return n and math.floor(n) or default
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function html_attr(s)
  if not s then return "" end
  s = tostring(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

local function html_text(s)
  if not s then return "" end
  s = tostring(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

-- Walk inline AST and emit safe HTML without using pandoc.write (which would
-- pull in the ambient HTML template and produce a full standalone document).
local function inlines_to_html(inlines)
  local parts = {}
  for _, el in ipairs(inlines) do
    local t = el.t
    if t == "Str" then
      table.insert(parts, html_text(el.text))
    elseif t == "Space" or t == "SoftBreak" then
      table.insert(parts, " ")
    elseif t == "LineBreak" then
      table.insert(parts, "<br>")
    elseif t == "Emph" then
      table.insert(parts, "<em>" .. inlines_to_html(el.content) .. "</em>")
    elseif t == "Strong" then
      table.insert(parts, "<strong>" .. inlines_to_html(el.content) .. "</strong>")
    elseif t == "Strikeout" then
      table.insert(parts, "<del>" .. inlines_to_html(el.content) .. "</del>")
    elseif t == "Link" then
      table.insert(parts, string.format(
        '<a href="%s">%s</a>',
        html_attr(el.target), inlines_to_html(el.content)))
    elseif t == "Code" then
      table.insert(parts, "<code>" .. html_text(el.text) .. "</code>")
    elseif t == "RawInline" and el.format == "html" then
      table.insert(parts, el.text)
    else
      table.insert(parts, html_text(pandoc.utils.stringify(el)))
    end
  end
  return table.concat(parts)
end

local function md_to_html(s)
  if not s or s == "" then return "" end
  local doc = pandoc.read(s, "commonmark")
  return inlines_to_html(pandoc.utils.blocks_to_inlines(doc.blocks))
end

local function md_to_plain(s)
  if not s or s == "" then return "" end
  local doc = pandoc.read(s, "commonmark")
  return pandoc.utils.stringify(doc)
end

local function build_exif_line(exif, show_date, show_exif, date_format, datetime_format)
  local parts = {}
  if show_date and exif.date and exif.date ~= "" then
    table.insert(parts, string.format(
      '<time datetime="%s" data-date-format="%s" data-datetime-format="%s">%s</time>',
      html_attr(exif.date), html_attr(date_format), html_attr(datetime_format), html_text(exif.date)
    ))
  end
  if show_exif then
    if exif.aperture and exif.aperture ~= "" then
      table.insert(parts, html_text(exif.aperture))
    end
    if exif.shutter and exif.shutter ~= "" then
      table.insert(parts, html_text(exif.shutter))
    end
    if exif.focal_length and exif.focal_length ~= "" then
      table.insert(parts, html_text(exif.focal_length))
    end
    if exif.iso and exif.iso ~= "" then
      table.insert(parts, "ISO " .. html_text(exif.iso))
    end
    if exif.camera and exif.camera ~= "" then
      table.insert(parts, html_text(exif.camera))
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " · ")
end

local gallery_counter = 0

local function photo_gallery(args, kwargs, meta)
  -- Only emit HTML output
  if not quarto.doc.is_format("html") then
    return pandoc.Blocks{}
  end

  -- Resolve settings: positional arg > kwargs > frontmatter > defaults
  -- Positional arg (args[1]) is the album directory: {{< photo-gallery img/ >}}
  local pos_album = args[1] and str_val(args[1]) or nil
  local fm = meta_get(meta, "extensions", "photo-gallery")

  local album_dir   = coalesce(pos_album, kwargs["album-files"], meta_str(fm, "album-files"), "img")
  local layout      = coalesce(kwargs["layout"],              meta_str(fm, "layout"),              "justified")
  local row_height  = int_val(coalesce(kwargs["thumbnail-height"],   meta_str(fm, "thumbnail-height")),   300)
  local max_width   = int_val(coalesce(kwargs["thumbnail-max-width"], meta_str(fm, "thumbnail-max-width")), 1200)
  local thumb_qual  = int_val(coalesce(kwargs["thumbnail-quality"],  meta_str(fm, "thumbnail-quality")),  90)
  local columns     = int_val(coalesce(kwargs["columns"],            meta_str(fm, "columns")),            3)
  local gap         = int_val(coalesce(kwargs["gap"],                meta_str(fm, "gap")),                4)
  local show_exif     = bool_val(coalesce(kwargs["show-exif"],     meta_str(fm, "show-exif")),     true)
  local show_date     = bool_val(coalesce(kwargs["show-date"],     meta_str(fm, "show-date")),     true)
  local show_download = bool_val(coalesce(kwargs["show-download"], meta_str(fm, "show-download")), true)
  local show_bullets  = bool_val(coalesce(kwargs["show-bullets"],  meta_str(fm, "show-bullets")),  false)
  local date_format     = coalesce(kwargs["date-format"],     meta_str(fm, "date-format"),     "YYYY-MM-DD")
  local datetime_format = coalesce(kwargs["datetime-format"], meta_str(fm, "datetime-format"), "YYYY-MM-DDTHH:mm")
  local transition    = coalesce(kwargs["transition"], meta_str(fm, "transition"), "zoom")
  local user_id       = coalesce(kwargs["id"])

  local ext_dir = pandoc.path.directory(PANDOC_SCRIPT_FILE)
  local python_script = pandoc.path.join({ext_dir, "scripts", "process_gallery.py"})

  -- album_dir stays as a relative path: io.popen inherits CWD (project root), so paths
  -- resolve correctly and Python outputs hrefs that match what the browser will request.
  quarto.doc.add_resource(album_dir)

  local cmd = "uv run --script "
    .. shell_quote(python_script)
    .. " " .. shell_quote(album_dir)
    .. " --thumb-height " .. row_height
    .. " --thumb-max-width " .. max_width
    .. " --thumb-quality " .. thumb_qual

  local handle = io.popen(cmd .. " 2>/dev/null")
  if not handle then
    return pandoc.Blocks{pandoc.RawBlock("html",
      "<p class='photo-gallery-error'>photo-gallery: could not run process_gallery.py</p>")}
  end
  local json_out = handle:read("*a")
  local _, _, code = handle:close()

  if not json_out or json_out == "" then
    return pandoc.Blocks{pandoc.RawBlock("html",
      "<p class='photo-gallery-error'>photo-gallery: script produced no output (exit " .. tostring(code) .. ")</p>")}
  end

  local manifest = pandoc.json.decode(json_out)
  if not manifest or manifest.error then
    local msg = (manifest and manifest.error) or "unknown error"
    return pandoc.Blocks{pandoc.RawBlock("html",
      "<p class='photo-gallery-error'>photo-gallery: " .. html_text(msg) .. "</p>")}
  end

  local images = manifest.images or {}
  if #images == 0 then
    return pandoc.Blocks{pandoc.RawBlock("html",
      "<p class='photo-gallery-empty'>photo-gallery: no images found in " .. html_text(album_dir) .. "</p>")}
  end

  quarto.doc.add_html_dependency({
    name = "photo-gallery",
    version = "0.1.0",
    scripts = {
      { path = pandoc.path.join({ext_dir, "assets", "photoswipe", "photoswipe.umd.min.js"}) },
      { path = pandoc.path.join({ext_dir, "assets", "photoswipe", "photoswipe-lightbox.umd.min.js"}) },
      { path = pandoc.path.join({ext_dir, "assets", "dayjs.min.js"}) },
      { path = pandoc.path.join({ext_dir, "assets", "photo-gallery.js"}) },
    },
    stylesheets = {
      { path = pandoc.path.join({ext_dir, "assets", "photoswipe", "photoswipe.css"}) },
      { path = pandoc.path.join({ext_dir, "assets", "photo-gallery.css"}) },
    },
  })

  gallery_counter = gallery_counter + 1
  local gallery_id = user_id and ("pg-" .. user_id) or ("pg-" .. gallery_counter)

  local container_style = string.format(
    "--pg-gap: %dpx; --pg-row-height: %dpx; --pg-columns: %d;",
    gap, row_height, columns
  )

  local parts = {}

  table.insert(parts, string.format(
    '<div class="photo-gallery" data-layout="%s" style="%s">',
    html_attr(layout), html_attr(container_style)
  ))
  table.insert(parts, string.format(
    '<div class="pswp-gallery" id="%s" data-download="%s" data-transition="%s" data-bullets="%s">',
    html_attr(gallery_id),
    show_download and "true" or "false",
    html_attr(transition),
    show_bullets and "true" or "false"
  ))

  for img_i, img in ipairs(images) do
    local exif = img.exif or {}
    local aspect = img.aspect_ratio or 1.0
    local title = img.title or ""
    local description = img.description or ""
    -- Compute plain/HTML once; both are used in multiple places below.
    local desc_plain = description ~= "" and md_to_plain(description) or ""
    local desc_html  = description ~= "" and md_to_html(description)  or ""

    -- flex-grow proportional to aspect ratio drives the justified layout
    local item_style = string.format("flex-grow: %.4f;", aspect)

    -- alt: explicit alt key wins; otherwise plain-text of description (markdown stripped)
    local alt_text = img.alt or ""
    if alt_text == "" and desc_plain ~= "" then
      alt_text = desc_plain
    end

    local cap_id = gallery_id .. "-cap-" .. img_i
    local caption_parts = {}
    if title ~= "" then
      table.insert(caption_parts,
        '<span class="pg-title">' .. html_text(title) .. "</span>")
    end
    local exif_line = build_exif_line(exif, show_date, show_exif, date_format, datetime_format)
    if exif_line then
      table.insert(caption_parts,
        '<span class="pg-meta">' .. exif_line .. "</span>")
    end
    if desc_plain ~= "" then
      -- Plain text in the thumbnail overlay avoids nested <a> inside <a class="pg-item">.
      -- The HTML version lives in data-pg-desc and is injected into the lightbox by JS.
      table.insert(caption_parts,
        '<span class="pg-description">' .. html_text(desc_plain) .. "</span>")
    end
    local caption_html = ""
    if #caption_parts > 0 then
      caption_html = '<div class="pg-caption" id="' .. html_attr(cap_id) .. '">'
        .. table.concat(caption_parts) .. "</div>"
    end

    local lightbox_caption = title
    if desc_plain ~= "" then
      lightbox_caption = lightbox_caption ~= "" and (lightbox_caption .. " — " .. desc_plain) or desc_plain
    end

    -- aria-describedby links the link to its caption so screen readers announce it on focus
    local describedby = #caption_parts > 0 and (' aria-describedby="' .. html_attr(cap_id) .. '"') or ""

    -- data-pg-desc carries the markdown-rendered HTML to the lightbox caption.
    -- It must live on the <a> rather than inside it to avoid nested <a> elements.
    local pg_desc_attr = desc_html ~= ""
      and (' data-pg-desc="' .. html_attr(desc_html) .. '"')
      or ""

    table.insert(parts, string.format(
      '<a href="%s" data-pswp-width="%d" data-pswp-height="%d" data-cropped="false" class="pg-item" style="%s" title="%s"%s%s>',
      html_attr(img.src),
      img.width or 0,
      img.height or 0,
      html_attr(item_style),
      html_attr(lightbox_caption),
      describedby,
      pg_desc_attr
    ))
    table.insert(parts, string.format(
      '<img src="%s" alt="%s" width="%d" height="%d" loading="lazy" />',
      html_attr(img.thumb),
      html_attr(alt_text),
      img.thumb_width or 0,
      img.thumb_height or 0
    ))
    table.insert(parts, caption_html)
    table.insert(parts, "</a>")
  end

  table.insert(parts, "</div>") -- .pswp-gallery
  table.insert(parts, "</div>") -- .photo-gallery

  return pandoc.Blocks{pandoc.RawBlock("html", table.concat(parts, "\n"))}
end

return {
  ["photo-gallery"] = photo_gallery,
}
