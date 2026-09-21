#=~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Project      : MAGEMinApp
#   License      : GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007
#   Developers   : Nicolas Riel, Boris Kaus
#   Contributors : Nerone, S., Dominguez, H., Moyen, J-F.
#   Organization : Institute of Geosciences, Johannes-Gutenberg University, Mainz
#   Contact      : nriel[at]uni-mainz.de
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ =#

"""
    SVGCanvas

    A canvas of `width` x `height` user units with a plot rectangle inset by the
    margins `ml`/`mr`/`mt`/`mb`, mapping the data window `xmin..xmax` x
    `ymin..ymax` onto it (y up). Own layout, independent of Plotly's automargin:
    the SVG is a separate rendering meant to be edited, not a pixel copy of the
    screen figure.
"""
struct SVGCanvas
    width  :: Float64
    height :: Float64
    ml     :: Float64
    mr     :: Float64
    mt     :: Float64
    mb     :: Float64
    xmin   :: Float64
    xmax   :: Float64
    ymin   :: Float64
    ymax   :: Float64
end

svg_plot_width(c::SVGCanvas)  = c.width  - c.ml - c.mr
svg_plot_height(c::SVGCanvas) = c.height - c.mt - c.mb
svg_x(c::SVGCanvas, x::Real)  = c.ml + (x - c.xmin) / (c.xmax - c.xmin) * svg_plot_width(c)
svg_y(c::SVGCanvas, y::Real)  = c.mt + (1 - (y - c.ymin) / (c.ymax - c.ymin)) * svg_plot_height(c)

"""
    svg_num(v)

    `v` with at most two decimals and no trailing zeros ("12", "0.5", never "-0").
"""
function svg_num(v::Real)
    s = @sprintf("%.2f", v)
    s = rstrip(rstrip(s, '0'), '.')
    return (s == "-0" || isempty(s)) ? "0" : s
end

"""
    svg_escape(s)

    `s` with the XML special characters escaped.
"""
function svg_escape(s::AbstractString)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    return s
end

"""
    svg_id(seen, base)

    `base` as a valid, unique XML id: characters outside `[A-Za-z0-9_-]` become
    `_`, a leading digit gets a `_` in front, and a repeat gets a numeric suffix.
    `seen` is the set of ids already handed out; the result is added to it.
"""
function svg_id(seen::Set{String}, base::AbstractString)
    id = replace(String(base), r"[^A-Za-z0-9_-]" => "_")
    (isempty(id) || !isletter(first(id)) && first(id) != '_') && (id = "_" * id)
    cand = id
    k    = 1
    while cand in seen
        k += 1
        cand = "$(id)_$(k)"
    end
    push!(seen, cand)
    return cand
end

"""
    svg_dasharray(dash, width)

    The SVG `stroke-dasharray` for a Plotly dash name (`nothing` for solid),
    scaled with the line `width` the way Plotly does so a heavier line keeps the
    same look.
"""
function svg_dasharray(dash, width::Real)
    w = max(width, 1.0)
    d = dash === nothing ? "solid" : string(dash)
    d == "dot"         && return "$(svg_num(w)) $(svg_num(2w))"
    d == "dash"        && return "$(svg_num(4w)) $(svg_num(2w))"
    d == "longdash"    && return "$(svg_num(7w)) $(svg_num(3w))"
    d == "dashdot"     && return "$(svg_num(4w)) $(svg_num(2w)) $(svg_num(w)) $(svg_num(2w))"
    d == "longdashdot" && return "$(svg_num(7w)) $(svg_num(3w)) $(svg_num(w)) $(svg_num(3w))"
    return nothing
end

"""
    svg_split_polylines(x, y)

    Split parallel vectors `x`, `y` at every `nothing`/`missing`/non-finite entry
    into separate polylines (vectors of `(x, y)` tuples); polylines with fewer
    than two points are dropped.
"""
function svg_split_polylines(x::AbstractVector, y::AbstractVector)
    lines = Vector{Vector{Tuple{Float64,Float64}}}()
    cur   = Tuple{Float64,Float64}[]
    for (a, b) in zip(x, y)
        if a isa Real && b isa Real && isfinite(a) && isfinite(b)
            push!(cur, (Float64(a), Float64(b)))
        else
            length(cur) > 1 && push!(lines, cur)
            cur = Tuple{Float64,Float64}[]
        end
    end
    length(cur) > 1 && push!(lines, cur)
    return lines
end

"""
    svg_clip_segment(p, q, xmin, xmax, ymin, ymax)

    Liang-Barsky clip of the segment `p -> q` against the rectangle; `nothing` if
    it lies entirely outside, otherwise the clipped end points.
"""
function svg_clip_segment(p::Tuple{Float64,Float64}, q::Tuple{Float64,Float64}, xmin, xmax, ymin, ymax)
    dx, dy = q[1] - p[1], q[2] - p[2]
    t0, t1 = 0.0, 1.0
    for (pk, qk) in ((-dx, p[1] - xmin), (dx, xmax - p[1]), (-dy, p[2] - ymin), (dy, ymax - p[2]))
        if pk == 0
            qk < 0 && return nothing
        else
            r = qk / pk
            if pk < 0
                r > t1 && return nothing
                t0 = max(t0, r)
            else
                r < t0 && return nothing
                t1 = min(t1, r)
            end
        end
    end
    return (p[1] + t0 * dx, p[2] + t0 * dy), (p[1] + t1 * dx, p[2] + t1 * dy)
end

"""
    svg_clip_polyline(line, xmin, xmax, ymin, ymax)

    `line` (a vector of `(x, y)` tuples) clipped to the data rectangle, as a vector
    of polylines: it is cut wherever it leaves the rectangle and resumes where it
    re-enters. This replaces a `<clipPath>`, so the file needs no clipping
    construct at all.
"""
function svg_clip_polyline(line::Vector{Tuple{Float64,Float64}}, xmin, xmax, ymin, ymax)
    out = Vector{Vector{Tuple{Float64,Float64}}}()
    cur = Tuple{Float64,Float64}[]
    for k in 1:length(line)-1
        seg = svg_clip_segment(line[k], line[k+1], xmin, xmax, ymin, ymax)
        if seg === nothing
            length(cur) > 1 && push!(out, cur)
            cur = Tuple{Float64,Float64}[]
            continue
        end
        a, b = seg
        if isempty(cur)
            push!(cur, a)
        elseif cur[end] != a
            length(cur) > 1 && push!(out, cur)
            cur = Tuple{Float64,Float64}[a]
        end
        push!(cur, b)
    end
    length(cur) > 1 && push!(out, cur)
    return out
end

"""
    svg_path_data(c, polylines)

    The `d` attribute for `polylines` (data coordinates), mapped through the
    canvas `c`: one `M ... L ...` subpath per polyline, straight segments only.
"""
function svg_path_data(c::SVGCanvas, polylines::Vector{Vector{Tuple{Float64,Float64}}})
    io = IOBuffer()
    for pl in polylines
        for (k, (x, y)) in enumerate(pl)
            print(io, k == 1 ? "M" : "L", svg_num(svg_x(c, x)), " ", svg_num(svg_y(c, y)), " ")
        end
    end
    return strip(String(take!(io)))
end

"""
    svg_open(io, c)

    Write the XML header and the opening `<svg>` tag (`viewBox` equal to the
    canvas size, `width`/`height` in the same units; `xlink` also declares the
    `xlink` namespace, needed by an embedded `<image>`). Nothing else is written
    before the first layer: no `<defs>`, styles or metadata.
"""
function svg_open(io::IO, c::SVGCanvas; xlink::Bool = false)
    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    ns = xlink ? "xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"" : "xmlns=\"http://www.w3.org/2000/svg\""
    println(io, "<svg ", ns, " version=\"1.1\" width=\"$(svg_num(c.width))\" height=\"$(svg_num(c.height))\" viewBox=\"0 0 $(svg_num(c.width)) $(svg_num(c.height))\">")
end

svg_close(io::IO) = println(io, "</svg>")

"""
    svg_group_open(io, id; stroke, width, dash, fill, rounded, font_size, font_family, anchor)

    Open a `<g id="...">` layer. The stroke/fill/font properties go on the group
    (not on every element), so an editor sees the shared style once and "select
    same stroke" works across its children. Only the properties given are
    written.
"""
function svg_group_open(io::IO, id::AbstractString; stroke = nothing, width = nothing, dash = nothing,
                         fill = nothing, rounded = false, font_size = nothing, font_family = nothing, anchor = nothing)
    attrs = String["id=\"$(svg_escape(id))\""]
    fill   === nothing || push!(attrs, "fill=\"$(fill)\"")
    stroke === nothing || push!(attrs, "stroke=\"$(stroke)\"")
    width  === nothing || push!(attrs, "stroke-width=\"$(svg_num(width))\"")
    dash   === nothing || push!(attrs, "stroke-dasharray=\"$(dash)\"")
    rounded && push!(attrs, "stroke-linecap=\"round\" stroke-linejoin=\"round\"")
    font_family === nothing || push!(attrs, "font-family=\"$(font_family)\"")
    font_size   === nothing || push!(attrs, "font-size=\"$(svg_num(font_size))\"")
    anchor      === nothing || push!(attrs, "text-anchor=\"$(anchor)\"")
    println(io, "<g ", join(attrs, " "), ">")
end

svg_group_close(io::IO) = println(io, "</g>")

"""
    svg_path(io, id, d; stroke, width, dash)

    One `<path>` with the given `d`. `stroke`/`width`/`dash` are written only
    when given, i.e. when this path differs from its group's style.
"""
function svg_path(io::IO, id::AbstractString, d::AbstractString; stroke = nothing, width = nothing, dash = nothing)
    attrs = String["id=\"$(svg_escape(id))\""]
    stroke === nothing || push!(attrs, "stroke=\"$(stroke)\"")
    width  === nothing || push!(attrs, "stroke-width=\"$(svg_num(width))\"")
    dash   === nothing || push!(attrs, "stroke-dasharray=\"$(dash)\"")
    push!(attrs, "d=\"$(d)\"")
    println(io, "<path ", join(attrs, " "), "/>")
end

"""
    svg_line(io, x1, y1, x2, y2)

    A `<line>` in canvas units, styled by its group.
"""
svg_line(io::IO, x1, y1, x2, y2) =
    println(io, "<line x1=\"$(svg_num(x1))\" y1=\"$(svg_num(y1))\" x2=\"$(svg_num(x2))\" y2=\"$(svg_num(y2))\"/>")

"""
    svg_rect(io, id, x, y, w, h)

    A `<rect>` in canvas units, styled by its group (`fill` "none" there for an
    outline).
"""
svg_rect(io::IO, id::AbstractString, x, y, w, h) =
    println(io, "<rect id=\"$(svg_escape(id))\" x=\"$(svg_num(x))\" y=\"$(svg_num(y))\" width=\"$(svg_num(w))\" height=\"$(svg_num(h))\"/>")

"""
    svg_polygon(io, points, fill)

    A small filled polygon in canvas units (used for arrow heads).
"""
function svg_polygon(io::IO, points, fill::AbstractString)
    pts = join(["$(svg_num(x)),$(svg_num(y))" for (x, y) in points], " ")
    println(io, "<polygon points=\"$(pts)\" fill=\"$(fill)\" stroke=\"none\"/>")
end

"""
    svg_text_runs(text)

    Plotly-style inline markup as text lines, each a vector of `(content, dy, scale)`
    runs: `<br>` starts a new line, `<sub>`/`<sup>` shift and shrink their content
    (`dy` in em, `scale` relative), and any other tag is dropped.
"""
function svg_text_runs(text::AbstractString)
    lines = Vector{Vector{Tuple{String,Float64,Float64}}}()
    for raw in split(text, r"<br\s*/?>", keepempty = true)
        runs  = Tuple{String,Float64,Float64}[]
        dy    = 0.0
        scale = 1.0
        last  = 1
        for m in eachmatch(r"<(/?)(sub|sup|[a-z]+)[^>]*>", raw)
            m.offset > last && push!(runs, (String(raw[last:m.offset-1]), dy, scale))
            closing, tag = m.captures[1] == "/", m.captures[2]
            if tag == "sub"
                dy, scale = closing ? (0.0, 1.0) : (0.25, 0.7)
            elseif tag == "sup"
                dy, scale = closing ? (0.0, 1.0) : (-0.4, 0.7)
            end
            last = m.offset + ncodeunits(m.match)
        end
        last <= lastindex(raw) && push!(runs, (String(raw[last:end]), dy, scale))
        push!(lines, runs)
    end
    return lines
end

"""
    svg_text(io, x, y, text; id, size, anchor, fill, weight, rotate, line_height)

    A real `<text>` element (never outlined) at canvas position `(x, y)`, vertically
    centred on `y` (by an explicit offset, not `dominant-baseline`, which
    Illustrator ignores). Multi-line and sub/superscript markup become `<tspan>`s. The
    only transform ever written is `rotate(-90)` about `(x, y)`, for the y-axis
    title. `size`, `anchor` and `fill` are omitted when they equal `nothing`, so
    the enclosing layer's values apply.
"""
function svg_text(io::IO, x, y, text::AbstractString; id = nothing, size = nothing, anchor = nothing, fill = nothing,
                   weight = nothing, rotate = false, line_height = 1.15)
    lines = svg_text_runs(text)
    n     = length(lines)
    fs    = size === nothing ? 10.0 : Float64(size)
    attrs = String[]
    id     === nothing || push!(attrs, "id=\"$(svg_escape(id))\"")
    push!(attrs, "x=\"$(svg_num(x))\"", "y=\"$(svg_num(y))\"")
    size   === nothing || push!(attrs, "font-size=\"$(svg_num(size))\"")
    anchor === nothing || push!(attrs, "text-anchor=\"$(anchor)\"")
    fill   === nothing || push!(attrs, "fill=\"$(fill)\"")
    weight === nothing || push!(attrs, "font-weight=\"$(weight)\"")
    rotate && push!(attrs, "transform=\"rotate(-90 $(svg_num(x)) $(svg_num(y)))\"")
    print(io, "<text ", join(attrs, " "), ">")
    for (i, runs) in enumerate(lines)
        line_dy = i == 1 ? -(n - 1) * line_height / 2 + 0.35 : line_height
        prev    = 0.0
        for (j, (content, dy, scale)) in enumerate(runs)
            a = String[]
            if j == 1
                push!(a, "x=\"$(svg_num(x))\"")
                push!(a, "dy=\"$(svg_num(line_dy + dy - prev))em\"")
            elseif dy != prev
                push!(a, "dy=\"$(svg_num(dy - prev))em\"")
            end
            prev = dy
            scale == 1.0 || push!(a, "font-size=\"$(svg_num(fs * scale))\"")
            print(io, "<tspan ", join(a, " "), ">", svg_escape(content), "</tspan>")
        end
    end
    println(io, "</text>")
end

"""
    svg_tick_label(v)

    A tick value as text without floating-point noise or a trailing ".0"
    (`10.4`, `550`, never `10.400000000000001` or `550.0`).
"""
function svg_tick_label(v::Real)
    r = round(Float64(v), digits = 3)
    return isinteger(r) ? string(Int(r)) : string(r)
end

"""
    svg_layout_layers(io, c, seen; xticks, yticks, xtitle, ytitle, title,
                       font = "Helvetica, Arial, sans-serif", ink = "#333333")

    The `Layout` layer of a figure: `Outline` (frame rectangle), `Ticks` (marks on
    all four sides at `xticks`/`yticks`, data values), `Tick_labels` (bottom and
    left), `Axis_titles` (the y title rotated -90) and `Title`. Shared by every
    exporter so all of them have the same frame and tick styling.
"""
function svg_layout_layers(io::IO, c::SVGCanvas, seen::Set{String}; xticks, yticks, xtitle::AbstractString,
                            ytitle::AbstractString, title::AbstractString,
                            font::AbstractString = "Helvetica, Arial, sans-serif", ink::AbstractString = "#333333")
    pw, ph = svg_plot_width(c), svg_plot_height(c)
    left, right, top, bottom = c.ml, c.ml + pw, c.mt, c.mt + ph
    tl = 4.0

    svg_group_open(io, svg_id(seen, "Layout"); font_family = font, font_size = 10, fill = ink)
    svg_group_open(io, svg_id(seen, "Outline"); stroke = ink, width = 1, fill = "none")
    svg_rect(io, svg_id(seen, "Outline_frame"), left, top, pw, ph)
    svg_group_close(io)

    svg_group_open(io, svg_id(seen, "Ticks"); stroke = ink, width = 0.75)
    for v in xticks
        x = svg_x(c, v)
        svg_line(io, x, bottom, x, bottom + tl)
        svg_line(io, x, top, x, top - tl)
    end
    for v in yticks
        y = svg_y(c, v)
        svg_line(io, left, y, left - tl, y)
        svg_line(io, right, y, right + tl, y)
    end
    svg_group_close(io)

    svg_group_open(io, svg_id(seen, "Tick_labels"); fill = ink)
    for (k, v) in enumerate(xticks)
        svg_text(io, svg_x(c, v), bottom + tl + 10, svg_tick_label(v); id = svg_id(seen, "Tick_x_$(k)"), anchor = "middle")
    end
    for (k, v) in enumerate(yticks)
        svg_text(io, left - tl - 4, svg_y(c, v), svg_tick_label(v); id = svg_id(seen, "Tick_y_$(k)"), anchor = "end")
    end
    svg_group_close(io)

    svg_group_open(io, svg_id(seen, "Axis_titles"); fill = ink, font_size = 12, anchor = "middle")
    svg_text(io, (left + right) / 2, bottom + 40, xtitle; id = svg_id(seen, "Axis_title_x"))
    svg_text(io, left - 46, (top + bottom) / 2, ytitle; id = svg_id(seen, "Axis_title_y"), rotate = true)
    svg_group_close(io)

    svg_group_open(io, svg_id(seen, "Title"); fill = ink, font_size = 14, anchor = "middle")
    svg_text(io, (left + right) / 2, top / 2, title; id = svg_id(seen, "Figure_title"), weight = "bold")
    svg_group_close(io)
    svg_group_close(io)
end

"""
    svg_heatmap_png(prob; low = (255,255,255), high = (200,30,30), target_px = 1100)

    Rasterise a probability grid `prob` (`[iy, ix]`, rows = y increasing upward,
    values in [0, 1]) to PNG bytes, colored linearly from `low` at 0 to `high` at 1
    (the on-screen colorscale). Each cell is a block of `f x f` pixels (nearest
    neighbour, `f` even, about `target_px` across), so the cells stay crisp blocks
    when an editor scales the image. Plotly centres a cell on its node, so the
    outer cells reach half a spacing beyond the plot edge, where the axis clips
    them; with an even `f` they simply keep `f/2` pixels and the image covers
    exactly the plot rectangle, with no clipping needed. Exact zeros are fully
    transparent. Returns `(png_bytes, width_px, height_px)`; the top image row is
    the largest y.
"""
function svg_heatmap_png(prob::AbstractMatrix{<:Real}; low = (255, 255, 255), high = (200, 30, 30), target_px::Int = 1100)
    ny, nx = size(prob)
    f      = 2 * cld(target_px, 2 * max(nx, ny))
    W, H   = (nx - 1) * f, (ny - 1) * f
    img    = Matrix{RGBA{N0f8}}(undef, H, W)
    lerp(a, b, p) = clamp(round(Int, a + (b - a) * p), 0, 255) / 255
    for r in 1:H, c in 1:W
        i = floor(Int, (c - 0.5) / f + 0.5) + 1
        j = floor(Int, (ny - 1) - (r - 0.5) / f + 0.5) + 1
        p = clamp(Float64(prob[j, i]), 0.0, 1.0)
        img[r, c] = p <= 0 ? RGBA{N0f8}(0, 0, 0, 0) :
                    RGBA{N0f8}(lerp(low[1], high[1], p), lerp(low[2], high[2], p), lerp(low[3], high[3], p), 1)
    end
    path = tempname() * ".png"
    try
        Images.save(path, img)
        return read(path), W, H
    finally
        rm(path; force = true)
    end
end

"""
    svg_image(io, id, c, png)

    An `<image>` covering exactly the canvas's plot rectangle, with `png` (bytes)
    embedded as a base64 data URI. Uses `xlink:href` (older Illustrator does not
    read plain `href`; the file must be opened with `svg_open(...; xlink = true)`),
    `preserveAspectRatio="none"` and `image-rendering="pixelated"` so the cell
    blocks stay sharp.
"""
function svg_image(io::IO, id::AbstractString, c::SVGCanvas, png::AbstractVector{UInt8})
    println(io, "<image id=\"$(svg_escape(id))\" x=\"$(svg_num(c.ml))\" y=\"$(svg_num(c.mt))\" width=\"$(svg_num(svg_plot_width(c)))\" height=\"$(svg_num(svg_plot_height(c)))\" preserveAspectRatio=\"none\" image-rendering=\"pixelated\" xlink:href=\"data:image/png;base64,$(base64encode(png))\"/>")
end

"""
    svg_gradient_bar(io, id, x, y, w, h, low, high)

    A `w` x `h` bar at `(x, y)` filled with a vertical `<linearGradient>` from
    `low` (bottom) to `high` (top), the colors as `"rgb(r,g,b)"` strings. The one
    `<defs>` the exporters write: Illustrator imports a linear gradient as a
    native, editable gradient, which beats dozens of stacked rectangles.
"""
function svg_gradient_bar(io::IO, id::AbstractString, x, y, w, h, low::AbstractString, high::AbstractString)
    gid = id * "_gradient"
    println(io, "<defs><linearGradient id=\"$(svg_escape(gid))\" x1=\"0\" y1=\"1\" x2=\"0\" y2=\"0\"><stop offset=\"0\" stop-color=\"$(low)\"/><stop offset=\"1\" stop-color=\"$(high)\"/></linearGradient></defs>")
    println(io, "<rect id=\"$(svg_escape(id))\" x=\"$(svg_num(x))\" y=\"$(svg_num(y))\" width=\"$(svg_num(w))\" height=\"$(svg_num(h))\" fill=\"url(#$(svg_escape(gid)))\"/>")
end
