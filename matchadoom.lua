-- Matcha Configuration
-- Set WAD_SOURCE to a local file in your workspace (e.g. "doom1.dat") or a direct HTTP(S) URL.
local WAD_SOURCE = "doom1.dat"
local WAD_FALLBACK_URL = "https://raw.githubusercontent.com/miseryandsuffering/matchadoom/main/freedoom1.wad"

local iskeydown = iskeypressed or iskeydown
local _bit = bit32 or bit
local band   = _bit.band
local bor    = _bit.bor
local bxor   = _bit.bxor
local bnot   = _bit.bnot
local lshift = _bit.lshift
local rshift = _bit.rshift
local unpack = table.unpack or unpack

local _crcT = {}
do
    for n = 0, 255 do
        local c = n
        for _ = 1, 8 do
            if band(c, 1) ~= 0 then
                c = bxor(0xEDB88320, rshift(c, 1))
            else
                c = rshift(c, 1)
            end
        end
        _crcT[n] = c
    end
end

local function _crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        local b = string.byte(s, i)
        c = bxor(_crcT[band(bxor(c, b), 0xFF)], rshift(c, 8))
    end
    return bxor(c, 0xFFFFFFFF)
end

local function _adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + string.byte(s, i)) % 65521
        b = (b + a) % 65521
    end
    return bor(lshift(b, 16), a)
end

local function _u32be(n)
    return string.char(band(rshift(n, 24), 0xFF), band(rshift(n, 16), 0xFF), band(rshift(n, 8), 0xFF), band(n, 0xFF))
end

local function _pngChunk(tag, data)
    local td = tag .. data
    return _u32be(#data) .. td .. _u32be(_crc32(td))
end

local function _makePNG(w, h, pixStr, pal)
    local sig = "\137PNG\r\n\26\n"
    local ihdr = _pngChunk("IHDR", _u32be(w) .. _u32be(h) .. "\8\2\0\0\0")
    local rows = {}
    local byte = string.byte
    for y = 0, h - 1 do
        local row = { "\0" }
        local base = y * w
        for x = 0, w - 1 do
            local idx = byte(pixStr, base + x + 1) or 0
            row[#row + 1] = pal[idx] or "\0\0\0"
        end
        rows[y + 1] = table.concat(row)
    end
    local raw = table.concat(rows)
    local BS = 65535
    local blks = {}
    local len = #raw
    for i = 1, len, BS do
        local seg = raw:sub(i, i + BS - 1)
        local ln = #seg
        local fin = (i + BS - 1 >= len) and 1 or 0
        local nl = band(bnot(ln), 0xFFFF)
        blks[#blks + 1] = string.char(fin, band(ln, 0xFF), band(rshift(ln, 8), 0xFF), band(nl, 0xFF), band(rshift(nl, 8), 0xFF)) .. seg
    end
    local a = _adler32(raw)
    local zlib = "\120\1" .. table.concat(blks) .. _u32be(a)
    return sig .. ihdr .. _pngChunk("IDAT", zlib) .. _pngChunk("IEND", "")
end

local Framebuffer = {}
Framebuffer.__index = Framebuffer

function Framebuffer.new(w, h, _)
    local img = Drawing.new("Image")
    img.Visible = true
    img.Transparency = 1
    img.Position = Vector2.new(0, 0)
    img.Size = Vector2.new(w, h)
    local pal = {}
    for i = 0, 255 do
        pal[i] = "\0\0\0"
    end
    return setmetatable({
        _w = w,
        _h = h,
        _img = img,
        _pal = pal,
        _pix = ""
    }, Framebuffer)
end

function Framebuffer:setpalette(raw)
    local n = math.min(256, math.floor(#raw / 3))
    for i = 0, n - 1 do
        self._pal[i] = raw:sub(i * 3 + 1, i * 3 + 3)
    end
    return n
end

function Framebuffer:write(str)
    self._pix = str
end

function Framebuffer:draw(x, y, w, h)
    self._img.Position = Vector2.new(x, y)
    self._img.Size = Vector2.new(w, h)
    self._img.Data = _makePNG(self._w, self._h, self._pix, self._pal)
end

local function _fetchHttp(url)
    if (type(httpget) == "function") then
        local ok, res = pcall(httpget, url)
        if ok and res and #res > 12 then return res end
    end
    if game and game.HttpGet then
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and res and #res > 12 then return res end
    end
    return nil
end

local SW, SH       = 320, 200
local HALF_FOV     = math.pi / 4
local PROJ         = (SW / 2) / math.tan(HALF_FOV)
local EYE_H        = 41
local MOVE_SPD     = 220
-- EHEEGUHGEUHEGUHGE
local TURN_SPD     = math.pi * 0.85
local NEAR         = 2.0
local NF_SUB       = 0x8000

local byte = string.byte

local function u16(s, o)
    local a, b = byte(s, o+1, o+2)
    return a + b*256
end
local function i16(s, o)
    local v = u16(s,o); return v < 32768 and v or v-65536
end
local function u32(s, o)
    local a,b,c,d = byte(s, o+1, o+4)
    return a + b*256 + c*65536 + d*16777216
end
local function lname(s, o)
    local r = s:sub(o+1, o+8)
    local z = r:find('\0', 1, true)
    return z and r:sub(1,z-1):upper() or r:upper()
end

local function loadWAD()
    local raw = nil

    -- 1. Check if WAD_SOURCE is a URL
    if type(WAD_SOURCE) == "string" and (WAD_SOURCE:sub(1, 7) == "http://" or WAD_SOURCE:sub(1, 8) == "https://") then
        print("[DOOM] Fetching WAD from URL: " .. WAD_SOURCE)
        raw = _fetchHttp(WAD_SOURCE)
        if raw and writefile then
            pcall(writefile, "doom1.dat", raw)
        end
    end

    -- 2. Check local workspace files (.dat, .txt required by Matcha filesystem)
    if not raw then
        local names = {
            WAD_SOURCE,
            "doom1.dat", "DOOM1.dat", "doom.dat", "DOOM.dat",
            "freedoom1.dat", "FREEDOOM1.dat", "freedoom2.dat", "FREEDOOM2.dat",
            "doom1.txt", "DOOM1.txt",
            "doom/doom1.dat", "doom/DOOM1.dat",
            "freedoom1.wad", "FREEDOOM1.WAD", "freedoom2.wad", "FREEDOOM2.WAD",
            "DOOM1.WAD", "doom1.wad", "DOOM.WAD", "doom.wad"
        }
        for _, n in ipairs(names) do
            if n and type(n) == "string" and n ~= "" then
                local ok, data = pcall(readfile, n)
                if ok and data and #data > 12 then
                    raw = data
                    print("[DOOM] Loaded local WAD: " .. n)
                    break
                end
            end
        end
    end

    -- 3. Automatic fallback download if file is missing
    if not raw and WAD_FALLBACK_URL then
        print("[DOOM] Local WAD not found. Auto-downloading DOOM1.WAD shareware...")
        raw = _fetchHttp(WAD_FALLBACK_URL)
        if raw and writefile then
            pcall(writefile, "doom1.dat", raw)
            print("[DOOM] Saved downloaded WAD to workspace/doom1.dat")
        end
    end

    if not raw then
        error("WAD not found! Put doom1.dat in Matcha's workspace folder (e.g. C:\\matcha\\workspace\\doom1.dat) or set WAD_SOURCE to a direct URL.")
    end
    local magic = raw:sub(1,4)
    if magic ~= "IWAD" and magic ~= "PWAD" then error("Not a valid WAD: "..magic) end

    local nlumps = u32(raw, 4)
    local dirofs = u32(raw, 8)
    local byName, list = {}, {}
    for i = 0, nlumps-1 do
        local base = dirofs + i*16
        local ofs  = u32(raw, base)
        local sz   = u32(raw, base+4)
        local nm   = lname(raw, base+8)
        local e    = { name=nm, ofs=ofs, sz=sz }
        list[#list+1] = e
        byName[nm] = e
    end
    local function getData(nm)
        local e = byName[nm:upper()]
        if not e or e.sz==0 then return nil end
        return raw:sub(e.ofs+1, e.ofs+e.sz)
    end
    local function getIdx(i)
        local e = list[i]
        if not e or e.sz==0 then return nil end
        return raw:sub(e.ofs+1, e.ofs+e.sz)
    end
    local function findIdx(nm)
        nm = nm:upper()
        for i,e in ipairs(list) do if e.name==nm then return i end end
    end
    return { getData=getData, getIdx=getIdx, findIdx=findIdx, list=list }
end

local function loadMap(wad, mapname)
    local mi = wad.findIdx(mapname)
    if not mi then error("Map not found: "..mapname) end

    local function ml(nm)
        for i = mi+1, mi+11 do
            if wad.list[i] and wad.list[i].name == nm:upper() then
                return wad.getIdx(i)
            end
        end
    end

    local vd = ml("VERTEXES")
    local verts = {}
    for i = 0, #vd/4-1 do
        verts[i] = { x=i16(vd,i*4), y=i16(vd,i*4+2) }
    end

    local secd = ml("SECTORS")
    local secs = {}
    for i = 0, #secd/26-1 do
        local b = i*26
        secs[i] = { fh=i16(secd,b), ch=i16(secd,b+2),
                    ff=lname(secd,b+4), cf=lname(secd,b+12),
                    light=u16(secd,b+20) }
    end

    local sdd = ml("SIDEDEFS")
    local sides = {}
    for i = 0, #sdd/30-1 do
        local b = i*30
        sides[i] = { xo=i16(sdd,b), yo=i16(sdd,b+2),
                     upper=lname(sdd,b+4), lower=lname(sdd,b+12),
                     mid=lname(sdd,b+20), sec=u16(sdd,b+28) }
    end

    local ld = ml("LINEDEFS")
    local lines = {}
    for i = 0, #ld/14-1 do
        local b = i*14
        lines[i] = { v1=u16(ld,b), v2=u16(ld,b+2),
                     flags=u16(ld,b+4), special=u16(ld,b+6),
                     s1=u16(ld,b+10), s2=u16(ld,b+12) }
    end

    local sgd = ml("SEGS")
    local segs = {}
    for i = 0, #sgd/12-1 do
        local b = i*12
        segs[i] = { v1=u16(sgd,b), v2=u16(sgd,b+2),
                    linedef=u16(sgd,b+6), side=u16(sgd,b+8),
                    offset=i16(sgd,b+10) }
    end

    local ssd = ml("SSECTORS")
    local ssecs = {}
    for i = 0, #ssd/4-1 do
        ssecs[i] = { n=u16(ssd,i*4), first=u16(ssd,i*4+2) }
    end

    local nd = ml("NODES")
    local nodes = {}
    local ncount = #nd/28
    for i = 0, ncount-1 do
        local b = i*28
        nodes[i] = {
            x=i16(nd,b), y=i16(nd,b+2), dx=i16(nd,b+4), dy=i16(nd,b+6),
            bb = {
                { i16(nd,b+8),i16(nd,b+10),i16(nd,b+12),i16(nd,b+14) },
                { i16(nd,b+16),i16(nd,b+18),i16(nd,b+20),i16(nd,b+22) },
            },
            c = { u16(nd,b+24), u16(nd,b+26) }
        }
    end

    local thd = ml("THINGS")
    local things = {}
    for i = 0, #thd/10-1 do
        local b = i*10
        things[i] = { x=i16(thd,b), y=i16(thd,b+2),
                      angle=u16(thd,b+4), type=u16(thd,b+6) }
    end

    local function onSide(px, py, n)
        local dx, dy = px - n.x, py - n.y
        return (n.dy * dx >= n.dx * dy) and 0 or 1
    end

    local function sectorAt(px, py)
        local idx = ncount - 1
        while idx >= 0 do
            local n = nodes[idx]
            local side = onSide(px, py, n)
            local child = n.c[side+1]
            if child >= NF_SUB then
-- Dude doom in misery like thats acc crazy
                local ss = ssecs[child - NF_SUB]
                if ss and ss.n > 0 then
                    local sg = segs[ss.first]
                    if sg then
                        local li = lines[sg.linedef]
                        if li then
                            local sdidx = sg.side == 0 and li.s1 or li.s2
                            local sd = sides[sdidx]
                            if sd then return secs[sd.sec] end
                        end
                    end
                end
                return nil
            end
            idx = child
        end
    end

    local solid = {}
    local lineList = {}
    for i = 0, 65535 do
        local li = lines[i]
        if not li then break end
        local oneSided = (li.s2 == 0xFFFF)
        local blocking = oneSided or (band(li.flags, 1) ~= 0)
        local sA, sB
        if not oneSided and li.s1 ~= 0xFFFF then
            local sdA, sdB = sides[li.s1], sides[li.s2]
            if sdA and sdB then
                sA, sB = sdA.sec, sdB.sec
                local secA, secB = secs[sA], secs[sB]
                if secA and secB then
                    local openTop = math.min(secA.ch, secB.ch)
                    local openBot = math.max(secA.fh, secB.fh)
                    if openTop - openBot < 56 then blocking = true end
                end
            end
        end
        local a, b = verts[li.v1], verts[li.v2]
        if blocking and a and b then
            solid[#solid+1] = { a.x, a.y, b.x, b.y, sA, sB }
        end
        if a and b then
            lineList[#lineList+1] = { a.x, a.y, b.x, b.y, oneSided, sA, sB }
        end
    end

    local function crosses(x1, y1, x2, y2)
        for i = 1, #solid do
            local w = solid[i]
            local x3, y3, x4, y4 = w[1], w[2], w[3], w[4]
            local d = (x2-x1)*(y4-y3) - (y2-y1)*(x4-x3)
            if d ~= 0 then
                local t = ((x3-x1)*(y4-y3) - (y3-y1)*(x4-x3)) / d
                local u = ((x3-x1)*(y2-y1) - (y3-y1)*(x2-x1)) / d
                if t > 0 and t < 1 and u > 0 and u < 1 then
                    local open = false
                    if w[5] then
                        local secA, secB = secs[w[5]], secs[w[6]]
                        if secA and secB then
                            local openTop = math.min(secA.ch, secB.ch)
                            local openBot = math.max(secA.fh, secB.fh)
                            if openTop - openBot >= 56 then open = true end
                        end
                    end
                    if not open then return true end
                end
            end
        end
        return false
    end

    local function los(x1, y1, x2, y2)
        return not crosses(x1, y1, x2, y2)
    end

    local function sight(x1, y1, z1, x2, y2, z2)
        local dzt = z2 - z1
        for i = 1, #lineList do
            local w = lineList[i]
            local x3, y3, x4, y4 = w[1], w[2], w[3], w[4]
            local d = (x2-x1)*(y4-y3) - (y2-y1)*(x4-x3)
            if d ~= 0 then
                local t = ((x3-x1)*(y4-y3) - (y3-y1)*(x4-x3)) / d
                local u = ((x3-x1)*(y2-y1) - (y3-y1)*(x2-x1)) / d
                if t > 0 and t < 1 and u > 0 and u < 1 then
                    if w[5] then return false end
                    local secA, secB = secs[w[6]], secs[w[7]]
                    if not secA or not secB then return false end
                    local openTop = math.min(secA.ch, secB.ch)
                    local openBot = math.max(secA.fh, secB.fh)
                    if openTop <= openBot then return false end
                    local z = z1 + dzt * t
                    if z < openBot or z > openTop then return false end
                end
            end
        end
        return true
    end

    return { verts=verts, secs=secs, sides=sides, lines=lines,
             segs=segs, ssecs=ssecs, nodes=nodes, things=things,
             ncount=ncount, sectorAt=sectorAt,
             solid=solid, crosses=crosses, los=los, sight=sight }
end

local function makeTextures(wad)
    local pnd = wad.getData("PNAMES")
    local pnames = {}
    if pnd then
        for i = 0, u32(pnd,0)-1 do pnames[i] = lname(pnd, 4+i*8) end
    end

    local tdefs = {}
    for _, tn in ipairs({"TEXTURE1","TEXTURE2"}) do
        local td = wad.getData(tn)
        if td then
            local n = u32(td,0)
            for i = 0, n-1 do
                local ofs = u32(td, 4+i*4)
                local nm  = lname(td, ofs)
                local w   = u16(td, ofs+12)
                local h   = u16(td, ofs+14)
                local np  = u16(td, ofs+20)
                local patches = {}
                for j = 0, np-1 do
                    local pb = ofs+22+j*10
                    patches[j+1] = { ox=i16(td,pb), oy=i16(td,pb+2), idx=u16(td,pb+4) }
                end
                tdefs[nm] = { w=w, h=h, patches=patches }
            end
        end
    end

    local colormapData = wad.getData("COLORMAP")

    local texCache, flatCache = {}, {}

    local function getFlat(nm)
        nm = nm:upper()
        if flatCache[nm] then return flatCache[nm] end
        local d = wad.getData(nm)
        if not d or #d < 4096 then
            d = string.rep(string.char(119), 4096)
        end
        flatCache[nm] = d
        return d
    end

    local function getTex(nm)
        if nm == "" or nm == "-" then return nil end
        nm = nm:upper()
        if texCache[nm] ~= nil then return texCache[nm] end

        local def = tdefs[nm]
        if not def then texCache[nm]=false; return nil end

        local buf = {}
        for c = 0, def.w-1 do
            buf[c] = {}
            for r = 0, def.h-1 do buf[c][r] = 0 end
        end

        local wrote = 0
        for _, p in ipairs(def.patches) do
            local pname = pnames[p.idx]
            if pname then
                local pd = wad.getData(pname)
                if pd and #pd > 8 then
                    local pw = u16(pd,0)
                    for cx = 0, pw-1 do
                        local tcol = p.ox + cx
                        if 8+(cx+1)*4 > #pd then break end
                        if tcol >= 0 and tcol < def.w then
                            local pos = u32(pd, 8+cx*4)
                            while pos + 1 <= #pd do
                                local top = byte(pd, pos+1)
                                if not top or top == 255 then break end
                                local len = byte(pd, pos+2) or 0
                                if pos+3+len > #pd then break end
                                for ri = 0, len-1 do
                                    local ty = p.oy + top + ri
                                    if ty >= 0 and ty < def.h then
                                        buf[tcol][ty] = byte(pd, pos+3+ri+1) or 0
                                        wrote = wrote + 1
                                    end
                                end
                                pos = pos + len + 4
                            end
                        end
                    end
                end
            end
        end

        if wrote == 0 then
            for c = 0, def.w-1 do
                for r = 0, def.h-1 do buf[c][r] = 96 end
            end
        end

        local tex = { w=def.w, h=def.h, cols={} }
        for c = 0, def.w-1 do
            local t = {}
            for r = 0, def.h-1 do t[r+1] = string.char(buf[c][r]) end
            tex.cols[c] = table.concat(t)
        end
        texCache[nm] = tex
        return tex
    end

    local function applyLight(pidx, light)
        if not colormapData then return pidx end
        local cmidx = math.max(0, math.min(31, rshift(256 - light, 3)))
        return byte(colormapData, cmidx*256 + pidx + 1) or pidx
    end

    return { getTex=getTex, getFlat=getFlat, applyLight=applyLight }
end

local THINGDB = {
    [3004]={ spr="POSS", hp=20,   hostile=true, walk="ABCD", die="HIJKL",
             spd=80,  dmg=6,  rng=420 },
    [3001]={ spr="TROO", hp=60,   hostile=true, walk="ABCD", die="IJKLM",
             spd=95,  dmg=9,  rng=380 },
    [3002]={ spr="SARG", hp=150,  hostile=true, walk="ABCD", die="IJKLMN",
             spd=130, dmg=12, rng=70  },
    [9]   ={ spr="SPOS", hp=30,   hostile=true, walk="ABCD", die="HIJKL",
             spd=85,  dmg=9,  rng=420 },
    [65]  ={ spr="CPOS", hp=70,   hostile=true, walk="ABCD", die="EFGH",
             spd=90,  dmg=8,  rng=450 },
    [3003]={ spr="BOSS", hp=1000, hostile=true, walk="ABCD", die="HIJKLMN",
             spd=100, dmg=20, rng=400 },
    [3005]={ spr="HEAD", hp=400,  hostile=true, walk="AB",   die="CDEFG",
             spd=90,  dmg=14, rng=400 },
    [2001]={ spr="SHOT", hostile=false, give={weapon=3, shells=8} },
    [2002]={ spr="MGUN", hostile=false, give={weapon=4, ammo=20}  },
    [2008]={ spr="SHEL", hostile=false, give={shells=4}  },
    [2049]={ spr="SBOX", hostile=false, give={shells=20} },
    [2005]={ spr="CSAW", hostile=false, give={weapon=1}  },
    [2007]={ spr="CLIP", hostile=false, give={ammo=10}   },
    [2048]={ spr="AMMO", hostile=false, give={ammo=50}   },
    [2011]={ spr="STIM", hostile=false, give={health=10} },
    [2012]={ spr="MEDI", hostile=false, give={health=25} },
    [2014]={ spr="BON1", hostile=false, give={health=1}  },
    [2018]={ spr="ARM1", hostile=false, give={armor=100, armorpct=0.333} },
    [2019]={ spr="ARM2", hostile=false, give={armor=200, armorpct=0.5}   },
    [2015]={ spr="BON2", hostile=false, give={armorbonus=1} },
}

local WEAPONS = {
    { name="Chainsaw", spr="SAWG", flash=nil,    dmg=14, pellets=1, spread=0.00,
      cd=0.18, ammo=nil,      range=90,   auto=true  },
    { name="Pistol",   spr="PISG", flash="PISF", dmg=16, pellets=1, spread=0.01,
      cd=0.36, ammo="ammo",   range=1400, auto=false },
    { name="Shotgun",  spr="SHTG", flash="SHTF", dmg=9,  pellets=7, spread=0.10,
      cd=0.85, ammo="shells", range=1100, auto=false },
    { name="Chaingun", spr="CHGG", flash="CHGF", dmg=12, pellets=1, spread=0.035,
      cd=0.11, ammo="ammo",   range=1400, auto=true  },
}

local function loadPatch(wad, nm)
    local d = wad.getData(nm); if not d or #d < 8 then return nil end
    local pw, ph = u16(d,0), u16(d,2)
    local lo, to = i16(d,4), i16(d,6)
    if pw < 1 or ph < 1 or pw > 640 or ph > 400 then return nil end
    local cols = {}
    for cx = 0, pw-1 do
        if 8+(cx+1)*4 > #d then break end
        local colofs = u32(d, 8+cx*4)
        local posts, pos = {}, colofs
        while pos+1 <= #d do
            local td = byte(d, pos+1); if td == 255 then break end
            local len = byte(d, pos+2) or 0
            if pos+3+len > #d then break end
            posts[#posts+1] = { top=td, data=d:sub(pos+4, pos+3+len) }
            pos = pos + 4 + len
        end
        cols[cx] = posts
    end
    return { w=pw, h=ph, lo=lo, to=to, cols=cols }
end

local function loadSprFrame(wad, spr, letter)
    return loadPatch(wad, spr..letter.."1") or loadPatch(wad, spr..letter.."0")
end

local function loadSprSet(wad, spr, letters)
    local out = {}
    for i = 1, #letters do
        local p = loadSprFrame(wad, spr, letters:sub(i,i))
        if p then out[#out+1] = p end
    end
    return out
end

local function getSpritePatch(wad, sprname)
    return loadSprFrame(wad, sprname, "A") or loadSprFrame(wad, sprname, "B")
end

local function makeRenderer(map, tex)
    local screen = {}
    for i = 0, SW*SH-1 do screen[i] = 0 end

    local topClip = {}
    local botClip = {}
    local lastCeil = {}
    local lastFloor = {}
    local depthBuf = {}
    local curDep = 1e9

    for i = 0, SW*SH-1 do depthBuf[i] = 1e9 end

    local function resetClip()
        for x = 0, SW-1 do
            topClip[x] = -1; botClip[x] = SH
            lastCeil[x] = nil; lastFloor[x] = nil
        end
        for i = 0, SW*SH-1 do depthBuf[i] = 1e9 end
    end

    local colAngle = {}
    for x = 0, SW-1 do
        colAngle[x] = math.atan((x - SW*0.5 + 0.5) / PROJ)
    end

    local function drawColFlat(x, y1, y2, pidx)
        local cy1 = math.max(topClip[x]+1, math.floor(y1+0.5))
        local cy2 = math.min(botClip[x]-1, math.floor(y2-0.5))
        if cy1 > cy2 then return end
        local base = x
        for y = cy1, cy2 do
            local o = y*SW + base
            screen[o] = pidx
            if curDep < depthBuf[o] then depthBuf[o] = curDep end
        end
    end

    local function drawColTex(x, y1, y2, texcol, texobj, yoffset, light, al)
        local cy1 = math.max(topClip[x]+1, math.floor(y1+0.5))
        local cy2 = math.min(botClip[x]-1, math.floor(y2-0.5))
        if cy1 > cy2 then return end
        local wallH = y2 - y1
        if wallH < 0.1 then return end
        local texH = texobj.h
        local col  = texobj.cols[texcol % texobj.w]
        local base = x
        for y = cy1, cy2 do
            local frac = (y - y1) / wallH
            local ty   = math.floor((yoffset + frac * texH) % texH)
            if ty < 0 then ty = ty + texH end
            local pidx = byte(col, ty+1) or 0
            local o = y*SW + base
            screen[o] = al and al(pidx, light) or pidx
            if curDep < depthBuf[o] then depthBuf[o] = curDep end
        end
        return true
    end

    local function renderSeg(seg, player, skyIdx)
        local mp = map
        local v1 = mp.verts[seg.v1];  local v2 = mp.verts[seg.v2]
        if not v1 or not v2 then return end

        local px, py, pa = player.x, player.y, player.angle
        local cpa, spa = math.cos(pa), math.sin(pa)

        local cx1 = (v1.x-px)*spa - (v1.y-py)*cpa
        local cz1 = (v1.x-px)*cpa + (v1.y-py)*spa
        local cx2 = (v2.x-px)*spa - (v2.y-py)*cpa
        local cz2 = (v2.x-px)*cpa + (v2.y-py)*spa

        if cz1 <= NEAR and cz2 <= NEAR then return end

        if cz1 <= NEAR then
            local t = (NEAR-cz1)/(cz2-cz1)
            cx1 = cx1 + t*(cx2-cx1); cz1 = NEAR
        elseif cz2 <= NEAR then
            local t = (NEAR-cz2)/(cz1-cz2)
            cx2 = cx2 + t*(cx1-cx2); cz2 = NEAR
        end

        local sx1 = math.floor(PROJ*cx1/cz1 + SW*0.5)
        local sx2 = math.floor(PROJ*cx2/cz2 + SW*0.5)
        if sx1 >= sx2 then return end
        if sx2 < 0 or sx1 >= SW then return end

        local li    = mp.lines[seg.linedef]; if not li then return end
        local sdf   = mp.sides[seg.side==0 and li.s1 or li.s2]; if not sdf then return end
        local sdb   = (li.s2 ~= 0xFFFF and seg.side==0) and mp.sides[li.s2] or
                      (li.s1 ~= 0xFFFF and seg.side==1) and mp.sides[li.s1] or nil

        local sf   = mp.secs[sdf.sec];  if not sf  then return end
        local sb   = sdb and mp.secs[sdb.sec] or nil

        local pz   = player.z
        local light = math.max(sf.light, 96)
        local al   = tex.applyLight

        local seglen = math.sqrt((v2.x-v1.x)^2 + (v2.y-v1.y)^2)

        local drawx1 = math.max(0, sx1)
        local drawx2 = math.min(SW-1, sx2)
        local span   = sx2 - sx1
        local iz1, iz2 = 1/cz1, 1/cz2

        local midTex = tex.getTex(sdf.mid)
        local upTex  = tex.getTex(sdf.upper)
        local loTex  = tex.getTex(sdf.lower)
        local half   = SH * 0.5

        local ceilPidx, floorPidx
        if sf.cf == "F_SKY1" or sf.cf == "F_SKY" then
            ceilPidx = skyIdx
        else
            local cfdata = tex.getFlat(sf.cf)
            local cp = cfdata and (byte(cfdata, 32*64+33) or byte(cfdata,1) or 119) or 119
            ceilPidx = al and al(cp, light) or cp
        end
        local ffdata = tex.getFlat(sf.ff)
        local fp = ffdata and (byte(ffdata, 32*64+33) or byte(ffdata,1) or 119) or 119
        floorPidx = al and al(fp, light) or fp

        for x = drawx1, drawx2 do
            local t  = (x - sx1) / span
            local iz = iz1 + t*(iz2-iz1)
            curDep = 1/iz

            local u = seg.offset + t*seglen

            local wallTop = half - (sf.ch - pz)*PROJ*iz
            local wallBot = half - (sf.fh - pz)*PROJ*iz

            local ctop = math.floor(wallTop)
            if topClip[x]+1 < ctop then
                local cdz = (sf.ch - pz) * PROJ
                for y = math.max(0, topClip[x]+1), math.min(SH-1, ctop-1) do
                    local o = y*SW+x
                    screen[o] = ceilPidx
                    local dv = half - y
                    if dv > 0.5 then
                        local dd = cdz / dv
                        if dd < depthBuf[o] then depthBuf[o] = dd end
                    end
                end
                lastCeil[x] = ceilPidx
                local nt = math.min(SH, ctop-1)
                if nt > topClip[x] then topClip[x] = nt end
            end
            local cbot = math.ceil(wallBot)
            if botClip[x]-1 > cbot then
                local fdz = (pz - sf.fh) * PROJ
                for y = math.max(0, cbot+1), math.min(SH-1, botClip[x]-1) do
                    local o = y*SW+x
                    screen[o] = floorPidx
                    local dv = y - half
                    if dv > 0.5 then
                        local dd = fdz / dv
                        if dd < depthBuf[o] then depthBuf[o] = dd end
                    end
                end
                lastFloor[x] = floorPidx
                local nb = math.max(-1, cbot+1)
                if nb < botClip[x] then botClip[x] = nb end
            end

            if sb then
                local bTop = half - (sb.ch - pz)*PROJ*iz
                local bBot = half - (sb.fh - pz)*PROJ*iz

                if sf.ch > sb.ch and upTex then
                    local tc = math.floor(sdf.xo + u) % upTex.w
                    drawColTex(x, wallTop, bTop, tc, upTex, sdf.yo, light, al)
                    if topClip[x] < math.floor(bTop) then topClip[x] = math.floor(bTop) end
                elseif sf.ch > sb.ch then
                    drawColFlat(x, wallTop, bTop, al and al(63, light) or 63)
                    if topClip[x] < math.floor(bTop) then topClip[x] = math.floor(bTop) end
                end

                if sf.fh < sb.fh and loTex then
                    local tc = math.floor(sdf.xo + u) % loTex.w
                    drawColTex(x, bBot, wallBot, tc, loTex, sdf.yo, light, al)
                    if botClip[x] > math.ceil(bBot) then botClip[x] = math.ceil(bBot) end
                elseif sf.fh < sb.fh then
                    drawColFlat(x, bBot, wallBot, al and al(63, light) or 63)
                    if botClip[x] > math.ceil(bBot) then botClip[x] = math.ceil(bBot) end
                end
                if sb.ch <= sb.fh then
                    topClip[x] = SH; botClip[x] = -1
                end
            else
                if midTex then
                    local tc   = math.floor(sdf.xo + u) % midTex.w
                    local texH = midTex.h
                    local col  = midTex.cols[tc]
                    local wallH = wallBot - wallTop
                    local cy1 = math.max(topClip[x]+1, math.floor(wallTop+0.5))
                    local cy2 = math.min(botClip[x]-1, math.floor(wallBot-0.5))
                    for y = cy1, cy2 do
                        local frac = (y - wallTop) / wallH
                        local ty   = math.floor((sdf.yo + frac*texH) % texH)
                        if ty < 0 then ty = ty + texH end
                        local pidx = byte(col, ty+1) or 0
                        local o = y*SW+x
                        screen[o] = al and al(pidx, light) or pidx
                        if curDep < depthBuf[o] then depthBuf[o] = curDep end
                    end
                else
                    drawColFlat(x, wallTop, wallBot, al and al(63, light) or 63)
                end
                topClip[x] = SH; botClip[x] = -1
            end
        end
    end

    local function renderSS(ssnum, player, skyIdx)
        local ss = map.ssecs[ssnum]; if not ss then return end
-- this is why god chose me right here
        for i = 0, ss.n-1 do
            renderSeg(map.segs[ss.first+i], player, skyIdx)
        end
    end

    local function renderBSP(idx, player, skyIdx)
        if idx >= NF_SUB then
            renderSS(idx - NF_SUB, player, skyIdx); return
        end
        local n = map.nodes[idx]; if not n then return end
        local dx, dy = player.x - n.x, player.y - n.y
        local side = (n.dy*dx >= n.dx*dy) and 0 or 1
        renderBSP(n.c[side+1],   player, skyIdx)
        renderBSP(n.c[2-side],   player, skyIdx)
    end

    local function renderSprites(thingStates, player)
        local cpa, spa = math.cos(player.angle), math.sin(player.angle)
        local px, py, pz = player.x, player.y, player.z
        local half = SH * 0.5
        local al = tex.applyLight

        local vis = {}
        for _, ts in pairs(thingStates) do
            if not ts.gone then
                local dx, dy = ts.x - px, ts.y - py
                local cz = dx*cpa + dy*spa
                if cz > NEAR then
                    vis[#vis+1] = { ts=ts, cx=dx*spa - dy*cpa, cz=cz }
                end
            end
        end
        table.sort(vis, function(a,b) return a.cz > b.cz end)

        for _, v in ipairs(vis) do
            local ts, cz, cx2 = v.ts, v.cz, v.cx
            local scale  = PROJ / cz
            local sx_c   = PROJ * cx2 / cz + SW * 0.5
            local light  = math.max(ts.light or 160, 80)
            local sy_org = half + (pz - (ts.floorH or 0)) * scale

            local p = ts.patch
            if p then
                local sx_l   = sx_c - p.lo * scale
                local sy_top = sy_org - p.to * scale
                local dx1 = math.max(0, math.floor(sx_l))
                local dx2 = math.min(SW-1, math.floor(sx_l + p.w*scale) - 1)
                for sx = dx1, dx2 do
                    local patchX = math.max(0, math.min(p.w-1,
                        math.floor((sx - sx_l) / scale)))
                    local col = p.cols[patchX]
                    if col then
                        for _, post in ipairs(col) do
                            local psy0 = sy_top + post.top * scale
                            local psy1 = psy0 + #post.data * scale
                            local cy1 = math.max(0, math.floor(psy0+0.5))
                            local cy2 = math.min(SH-1, math.floor(psy1-0.5))
                            for sy = cy1, cy2 do
                                local o = sy*SW+sx
                                if cz < depthBuf[o] + 8 then
                                    local row = math.floor((sy - psy0) / scale)
                                    local pidx = byte(post.data, row+1) or 0
                                    if pidx ~= 0 then
                                        screen[o] = al and al(pidx, light) or pidx
                                    end
                                end
                            end
                        end
                    end
                end
            elseif ts.state ~= "corpse" then
                local sprH = (ts.hostile and 56 or 16) * scale
                local sprW = math.max(4, 24 * scale)
                local bx1 = math.max(0, math.floor(sx_c - sprW*0.5))
                local bx2 = math.min(SW-1, math.floor(sx_c + sprW*0.5))
                local by1 = math.max(0, math.floor(sy_org - sprH))
                local by2 = math.min(SH-1, math.floor(sy_org) - 1)
                local col = ts.hostile and 176 or 119
                for sx = bx1, bx2 do
                    for sy = by1, by2 do
                        local o = sy*SW+sx
                        if cz < depthBuf[o] + 8 then screen[o] = col end
                    end
                end
            end
        end
    end

    local function blitPatch(p, ox, oy, light)
        if not p then return end
        local al = tex.applyLight
        for cx = 0, p.w-1 do
            local sx = ox + cx
            if sx >= 0 and sx < SW then
                local col = p.cols[cx]
                if col then
                    for _, post in ipairs(col) do
                        for ri = 0, #post.data-1 do
                            local sy = oy + post.top + ri
                            if sy >= 0 and sy < SH then
                                local pidx = byte(post.data, ri+1)
                                if pidx and pidx ~= 0 then
                                    screen[sy*SW+sx] = light and al and al(pidx, light) or pidx
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local function renderWeapon(patch, flashPatch, bobx, boby)
        bobx, boby = bobx or 0, boby or 0
        if patch then
            local sx_l = math.floor(SW / 2) - patch.lo + bobx
            local sy_t = 168   - patch.to + boby
            if sy_t + patch.h < 0 or sy_t >= SH then
                sy_t = SH - patch.h + boby
                sx_l = math.floor(SW / 2) - math.floor(patch.w / 2) + bobx
            end
            blitPatch(patch, sx_l, sy_t, 200)
            if flashPatch then
                local fx = sx_l + (patch.lo - flashPatch.lo)
                local fy = sy_t + (patch.to - flashPatch.to)
                blitPatch(flashPatch, fx, fy, nil)
            end
            return
        end
        local bright = flashPatch ~= nil
        local function px2(x, y, c)
            if x>=0 and x<SW and y>=0 and y<SH then screen[y*SW+x] = c end
        end
        local bx, by = math.floor(SW / 2) + bobx, SH - 6 + boby
        for i = -20, 8 do px2(bx+i, by-14, 119) end
        for i = -20, 8 do px2(bx+i, by-13, 107) end
        for dy2 = -12, -7 do for i = -12, 8 do px2(bx+i, by+dy2, 95) end end
        for dy2 = -7, -2 do for i = -8, -2 do px2(bx+i, by+dy2, 87) end end
        px2(bx-10, by-8, 107); px2(bx-10, by-7, 107); px2(bx-9, by-6, 107)
        if bright then
            for i=-4,4 do px2(bx+8+i, by-16, 255) end
            for i=-3,3 do px2(bx+8+i, by-17, 231) end
            for i=-2,2 do px2(bx+8+i, by-18, 200) end
        end
    end

    local function fillRemainder(skyIdx, floorIdx)
        local halfY = rshift(SH, 1)
        for x = 0, SW-1 do
            local t = topClip[x] + 1
            local b = botClip[x] - 1
            if t <= b then
                local cp = lastCeil[x] or skyIdx
                local fp = lastFloor[x] or floorIdx
                for y = t, b do
                    screen[y*SW + x] = (y < halfY) and cp or fp
                end
            end
        end
    end

    local function buildString()
        local parts, pi = {}, 0
        local SZ = SW * SH
        for base = 0, SZ-1, 512 do
            local chunk = {}
            local top = math.min(base+511, SZ-1)
            for i = base, top do chunk[i-base+1] = screen[i] end
            pi = pi + 1
            parts[pi] = string.char(unpack(chunk))
        end
        return table.concat(parts)
    end

    return {
        resetClip     = resetClip,
        renderBSP     = renderBSP,
        renderSprites = renderSprites,
        renderWeapon  = renderWeapon,
        fillRemainder = fillRemainder,
        buildString   = buildString,
        screen        = screen,
    }
end

local DIGITS = {
    [0]={"111","101","101","101","111"}, [1]={"010","110","010","010","111"},
    [2]={"111","001","111","100","111"}, [3]={"111","001","111","001","111"},
    [4]={"101","101","111","001","001"}, [5]={"111","100","111","001","111"},
    [6]={"111","100","111","101","111"}, [7]={"111","001","001","001","001"},
    [8]={"111","101","111","101","111"}, [9]={"111","101","111","001","111"},
}

local function drawNum(screen, n, ox, oy, col)
    local s = tostring(math.max(0, math.floor(n)))
    for i = 1, #s do
        local g = DIGITS[tonumber(s:sub(i,i))]
        if g then
            for r = 1, 5 do
                for c = 1, 3 do
                    if g[r]:sub(c,c) == "1" then
                        local x, y = ox + (i-1)*4 + (c-1), oy + (r-1)
                        if x>=0 and x<SW and y>=0 and y<SH then screen[y*SW+x] = col end
                    end
                end
            end
        end
    end
end

local function drawHUD(screen, player)
    local barY = SH - 10
    for y = barY-2, SH-1 do
        for x = 0, SW-1 do screen[y*SW+x] = 0 end
    end
    drawNum(screen, player.health, 8,   barY, 176)
    drawNum(screen, player.armor,  120, barY, 112)
    local wd = WEAPONS[player.weapon or 2]
    local shown = 0
    if wd then
        if wd.ammo == "ammo" then shown = player.ammo
        elseif wd.ammo == "shells" then shown = player.shells end
    end
    drawNum(screen, shown, 250, barY, 231)
    drawNum(screen, player.weapon or 2, 300, barY, 200)
    local barW = math.floor((math.max(0,player.health)/100) * 90)
    for x = 0, 89 do
        screen[(SH-3)*SW + 8 + x] = (x < barW) and 176 or 60
    end
end

local function makePlayer(map)
    local p = { x=0, y=0, z=EYE_H, angle=0,
                health=100, armor=0, armorPct=0.333, ammo=50, shells=0,
                weapons={false,true,false,false}, weapon=2,
                dead=false, deadT=0, bobPhase=0, bobAmt=0, moved=false }

    for i = 0, 1000 do
        local t = map.things[i]
        if t and t.type == 1 then
            p.x = t.x; p.y = t.y
            p.angle = math.rad(t.angle)
            break
        end
    end
    p.spawnX, p.spawnY, p.spawnA = p.x, p.y, p.angle

    function p:hurt(dmg)
        if self.dead then return end
        if self.armor > 0 and dmg > 0 then
            local soak = math.floor(dmg * (self.armorPct or 0.333))
            if soak < 1 then soak = 1 end
            if soak > self.armor then soak = self.armor end
            self.armor = self.armor - soak
            dmg = dmg - soak
            if self.armor <= 0 then self.armorPct = 0.333 end
        end
        self.health = self.health - dmg
        if self.health <= 0 then
            self.health = 0
            self.dead   = true
            self.deadT  = 0
            print("[DOOM] You died!")
        end
    end

    function p:respawn()
        self.x, self.y, self.angle = self.spawnX, self.spawnY, self.spawnA
        self.health, self.armor, self.ammo, self.shells = 100, 0, 50, 0
        self.armorPct = 0.333
        self.weapons = {false, true, false, false}
        self.weapon = 2
        self.dead, self.deadT = false, 0
        local sec = map.sectorAt(self.x, self.y)
        self.z = (sec and sec.fh or 0) + EYE_H
    end

    function p:update(dt)
        self.moved = false
        if self.dead then
            local sec = map.sectorAt(self.x, self.y)
            local fh  = sec and sec.fh or 0
            self.z = math.max(fh + 8, self.z - 60*dt)
            return
        end

        local ts = TURN_SPD * dt
        local ms = MOVE_SPD * dt
        if iskeydown(0x10) then ms = ms * 1.7 end

        if iskeydown(0x25) or iskeydown(0x41) then self.angle = self.angle + ts end
        if iskeydown(0x27) or iskeydown(0x44) then self.angle = self.angle - ts end

        local mdx, mdy = 0, 0
        local ca, sa = math.cos(self.angle), math.sin(self.angle)
        if iskeydown(0x26) or iskeydown(0x57) then mdx=mdx+ca*ms; mdy=mdy+sa*ms end
        if iskeydown(0x28) or iskeydown(0x53) then mdx=mdx-ca*ms; mdy=mdy-sa*ms end
        if iskeydown(0x51) then mdx=mdx-sa*ms; mdy=mdy+ca*ms end
        if iskeydown(0x45) then mdx=mdx+sa*ms; mdy=mdy-ca*ms end

        if mdx ~= 0 or mdy ~= 0 then
            local curSec = map.sectorAt(self.x, self.y)
            local curFh  = curSec and curSec.fh or (self.z - EYE_H)
            local R = 14
            local cross = map.crosses
            local sat = map.sectorAt
            local function canGo(nx, ny)
                if cross(self.x, self.y, nx, ny) then return false end
                local ox, oy = nx - self.x, ny - self.y
                local len = math.sqrt(ox*ox + oy*oy)
                if len > 0.001 then
                    if cross(self.x, self.y, nx + (ox/len)*R, ny + (oy/len)*R) then
                        return false
                    end
                end
                local s = sat(nx, ny)
                if not s then return false end
                if s.fh - curFh > 24 then return false end
                return true
            end
            local nx, ny = self.x + mdx, self.y + mdy
            if canGo(nx, ny) then
                self.x, self.y = nx, ny; self.moved = true
            elseif canGo(self.x + mdx, self.y) then
                self.x = self.x + mdx;   self.moved = true
            elseif canGo(self.x, self.y + mdy) then
                self.y = self.y + mdy;   self.moved = true
            end
        end

        if self.moved then
            self.bobPhase = self.bobPhase + dt * 9
            self.bobAmt   = math.min(1, self.bobAmt + dt * 4)
        else
            self.bobAmt   = math.max(0, self.bobAmt - dt * 4)
        end

        local sec = map.sectorAt(self.x, self.y)
        if sec then self.z = sec.fh + EYE_H end
    end

    return p
end

local function main()
    print("[DOOM] Loading WAD…")
    local wad = loadWAD()
    print("[DOOM] WAD loaded, lumps: " .. #wad.list)

    print("[DOOM] Loading palette…")
    local palraw = wad.getData("PLAYPAL")

    print("[DOOM] Creating " .. SW .. "x" .. SH .. " indexed framebuffer…")
    local fb = Framebuffer.new(SW, SH, "indexed")
    if palraw then
        local n = fb:setpalette(palraw:sub(1, 768))
        print("[DOOM] Palette loaded: " .. tostring(n) .. " colours")
    end

    print("[DOOM] Loading map E1M1…")
    local map = loadMap(wad, "E1M1")
    print("[DOOM] Map loaded – nodes: " .. map.ncount
          .. "  solid walls: " .. #map.solid)

    print("[DOOM] Loading textures…")
    local texSys = makeTextures(wad)
    texSys.applyLight = function(pidx, light)
        local cmraw = wad.getData("COLORMAP")
        if not cmraw then return pidx end
        local cidx = math.max(0, math.min(31, rshift(256 - light, 3)))
        return byte(cmraw, cidx*256 + pidx + 1) or pidx
    end
    local cmraw = wad.getData("COLORMAP")
    if cmraw then
        texSys.applyLight = function(pidx, light)
            local cidx = math.max(0, math.min(31, rshift(256 - light, 3)))
            return byte(cmraw, cidx*256 + pidx + 1) or pidx
        end
    end

    print("[DOOM] Creating renderer…")
    local renderer = makeRenderer(map, texSys)

    print("[DOOM] Spawning player…")
    local player = makePlayer(map)
    print(string.format("[DOOM] Player start: (%.0f, %.0f) angle %.1f°",
          player.x, player.y, math.deg(player.angle)))

    print("[DOOM] Loading things…")
    local thingStates = {}
    local nmon, nitem = 0, 0
    for i = 0, 2000 do
        local t = map.things[i]
        if not t then break end
        local info = THINGDB[t.type]
        if info then
            local sec = map.sectorAt(t.x, t.y)
            local walkF = info.walk and loadSprSet(wad, info.spr, info.walk) or {}
            local dieF  = info.die  and loadSprSet(wad, info.spr, info.die)  or {}
            if #walkF == 0 then
                local p = getSpritePatch(wad, info.spr)
                if p then walkF = { p } end
            end
            local ts = {
                x=t.x, y=t.y, spawnX=t.x, spawnY=t.y,
                spr     = info.spr,
                hostile = info.hostile,
                give    = info.give,
                hp      = info.hp or 0, maxhp = info.hp or 0,
                spd     = info.spd or 0, dmg = info.dmg or 0, rng = info.rng or 64,
                walkF   = walkF, dieF = dieF,
                patch   = walkF[1],
                state   = "alive", gone = false,
                animT   = 0, animI = 1, atkCD = 0, aiT = 0,
                floorH  = sec and sec.fh or 0,
                light   = sec and sec.light or 160,
            }
            thingStates[#thingStates+1] = ts
            if info.hostile then nmon = nmon + 1 else nitem = nitem + 1 end
        end
    end
    print("[DOOM] Monsters: " .. nmon .. "  Items: " .. nitem)

    local wepSets = {}
    for wi, wd in ipairs(WEAPONS) do
        local frames = loadSprSet(wad, wd.spr, "ABCD")
        local flash  = wd.flash and loadSprSet(wad, wd.flash, "AB") or {}
        wepSets[wi] = { frames=frames, flash=flash }
        print("[DOOM] " .. wd.name .. ": " .. #frames .. " frames, "
              .. #flash .. " flash")
    end

    local function hasLOS(x1, y1, z1, x2, y2, z2)
        return map.sight(x1, y1, z1, x2, y2, z2)
    end

    local function resetLevel()
        player:respawn()
        for _, ts in pairs(thingStates) do
            ts.x, ts.y = ts.spawnX, ts.spawnY
            ts.hp, ts.state, ts.gone = ts.maxhp, "alive", false
            ts.animI, ts.animT, ts.atkCD = 1, 0, 0
            ts.awake, ts.see = false, false
            ts.patch = ts.walkF[1]
        end
        print("[DOOM] Level restarted")
    end

    local DOOR_SPECIALS = {
        [1]=true, [26]=true, [27]=true, [28]=true, [31]=true,
        [32]=true, [33]=true, [34]=true, [117]=true, [118]=true,
    }
    local activeDoors = {}

    local function segHit(x1,y1,x2,y2, x3,y3,x4,y4)
        local d = (x2-x1)*(y4-y3) - (y2-y1)*(x4-x3)
        if d == 0 then return false end
        local t = ((x3-x1)*(y4-y3) - (y3-y1)*(x4-x3)) / d
        local u = ((x3-x1)*(y2-y1) - (y3-y1)*(x2-x1)) / d
        return t > 0 and t < 1 and u > 0 and u < 1
    end

    local function doorTop(secIdx)
        local best
        for i = 0, 65535 do
            local li = map.lines[i]
            if not li then break end
            if li.s1 ~= 0xFFFF and li.s2 ~= 0xFFFF then
                local a, b = map.sides[li.s1], map.sides[li.s2]
                if a and b then
                    local other
                    if a.sec == secIdx then other = b.sec
                    elseif b.sec == secIdx then other = a.sec end
                    if other then
                        local os = map.secs[other]
                        if os and (not best or os.ch < best) then best = os.ch end
                    end
                end
            end
        end
        return best and (best - 4) or nil
    end

    local function tryUse()
        local reach = 80
        local ca, sa = math.cos(player.angle), math.sin(player.angle)
        local tx, ty = player.x + ca*reach, player.y + sa*reach
        for i = 0, 65535 do
            local li = map.lines[i]
            if not li then break end
            if DOOR_SPECIALS[li.special] then
                local v1, v2 = map.verts[li.v1], map.verts[li.v2]
                if v1 and v2 and segHit(player.x, player.y, tx, ty,
                                        v1.x, v1.y, v2.x, v2.y) then
                    local bs = (li.s2 ~= 0xFFFF) and map.sides[li.s2] or nil
                    local si = bs and bs.sec
                    local sec = si and map.secs[si]
                    if sec and not activeDoors[si] then
                        local top = doorTop(si)
                        if top and top > sec.fh then
                            activeDoors[si] = { top=top, state="open", t=0 }
                            print("[DOOM] Door opening")
                        end
                    end
                    return
                end
            end
        end
    end

    local function updateDoors(dt)
        for si, dr in pairs(activeDoors) do
            local sec = map.secs[si]
            if sec then
                if dr.state == "open" then
                    sec.ch = math.min(dr.top, sec.ch + 90*dt)
                    if sec.ch >= dr.top then dr.state = "wait"; dr.t = 0 end
                elseif dr.state == "wait" then
                    dr.t = dr.t + dt
                    if dr.t > 4 then dr.state = "close" end
                else
                    sec.ch = math.max(sec.fh, sec.ch - 90*dt)
                    if sec.ch <= sec.fh then activeDoors[si] = nil end
                end
            else
                activeDoors[si] = nil
            end
        end
    end

    local function closeAllDoors()
        for si, _ in pairs(activeDoors) do
            local sec = map.secs[si]
            if sec then sec.ch = sec.fh end
        end
        activeDoors = {}
    end

    local wepI, wepT, firing = 1, 0, false
    local flashT   = 0
    local shootCD  = 0
    local prevFire = false
    local prevUse, prevRestart, prevTab = false, false, false

    local lastT, frames, fps, fpsTimer = tick(), 0, 0, 0
    local DSW, DSH = 640, 400
    local DSX, DSY = 0, 0

    local skyBgIdx, floorBgIdx = 0, 0
    if palraw then
        local bestSky, bestFloor = 1e9, 1e9
        for i = 0, 255 do
            local r = byte(palraw, i*3+1) or 0
            local g = byte(palraw, i*3+2) or 0
            local b = byte(palraw, i*3+3) or 0
            local ds = (r-84)^2 + (g-130)^2 + (b-190)^2
            if ds < bestSky   then bestSky   = ds; skyBgIdx   = i end
            local df = (r-80)^2 + (g-80)^2 + (b-72)^2
            if df < bestFloor then bestFloor = df; floorBgIdx = i end
        end
    end

    print("[DOOM] Running!  WASD=move  A/D=turn  Q/E=strafe  Shift=run")
    print("[DOOM] Ctrl=shoot  Space=use/open door  Backspace=restart level")
    print("[DOOM] 1-4=select weapon  Tab=cycle weapon")

    local RS = (type(game) == "userdata" or type(game) == "table") and game.GetService and game:GetService("RunService")
    local function onRender(fn)
        if RS and RS.RenderStepped then
            RS.RenderStepped:Connect(fn)
        elseif callbacks and callbacks.paint then
            callbacks.paint(fn)
        end
    end

    onRender(function()
        local now = tick()
        local dt  = math.min(now - lastT, 0.05)
        lastT = now
        flashT = math.max(0, flashT - dt)

        frames = frames + 1
        fpsTimer = fpsTimer + dt
        if fpsTimer >= 2.0 then
            fps = math.floor(frames / fpsTimer); frames = 0; fpsTimer = 0
        end

        if player.dead then
            player.deadT = player.deadT + dt
            if player.deadT > 3.0 then resetLevel() end
        end

        updateDoors(dt)

        local useDown = iskeydown(0x20)
        if useDown and not prevUse and not player.dead then tryUse() end
        prevUse = useDown

        for k = 1, 4 do
            if iskeydown(0x30 + k) and player.weapons[k] and player.weapon ~= k then
                player.weapon = k
                firing, wepI, wepT = false, 1, 0
                print("[DOOM] " .. WEAPONS[k].name)
            end
        end

        local tabDown = iskeydown(0x09)
        if tabDown and not prevTab then
            for i = 1, 4 do
                local n = ((player.weapon - 1 + i) % 4) + 1
                if player.weapons[n] then
                    player.weapon = n
                    firing, wepI, wepT = false, 1, 0
                    print("[DOOM] " .. WEAPONS[n].name)
                    break
                end
            end
        end
        prevTab = tabDown

        local restartDown = iskeydown(0x08)
        if restartDown and not prevRestart then
            closeAllDoors()
            resetLevel()
        end
        prevRestart = restartDown

        shootCD = math.max(0, shootCD - dt)

        local wd = WEAPONS[player.weapon]
        local fireDown = iskeydown(0x11)
        local wantFire = fireDown and (wd.auto or not prevFire)

        if wantFire and shootCD <= 0 and not player.dead then
            local have = true
            if wd.ammo == "ammo" then
                if player.ammo > 0 then player.ammo = player.ammo - 1 else have = false end
            elseif wd.ammo == "shells" then
                if player.shells > 0 then player.shells = player.shells - 1 else have = false end
            end

            if have then
                shootCD = wd.cd
                firing, wepI, wepT = true, 1, 0
                if wd.flash then flashT = 0.12 end

                for _ = 1, wd.pellets do
                    local ang = player.angle
                    if wd.spread > 0 then
                        ang = ang + (math.random() - 0.5) * wd.spread * 2
                    end
                    local cpa, spa = math.cos(ang), math.sin(ang)
                    local best, bestDist = nil, wd.range
                    for _, ts in pairs(thingStates) do
                        if ts.state == "alive" and ts.hostile then
                            local dx, dy = ts.x - player.x, ts.y - player.y
                            local cz = dx*cpa + dy*spa
                            local cx = dx*spa - dy*cpa
                            if cz > 0 and cz < bestDist and math.abs(cx) < 24 + cz*0.05 then
                                if hasLOS(player.x, player.y, player.z,
                                          ts.x, ts.y, (ts.floorH or 0) + 32) then
                                    best, bestDist = ts, cz
                                end
                            end
                        end
                    end
                    if best then
                        best.hp = best.hp - (wd.dmg + math.random(0, 6))
                        if best.hp <= 0 then
                            best.state, best.animI, best.animT = "dying", 1, 0
                            if #best.dieF > 0 then best.patch = best.dieF[1] end
                            print("[DOOM] Killed a monster")
                        end
                    end
                end
            end
        end
        prevFire = fireDown

        local curSet = wepSets[player.weapon]
        if firing and curSet and #curSet.frames > 0 then
            wepT = wepT + dt
            if wepT >= 0.07 then
                wepT = 0
                wepI = wepI + 1
                if wepI > #curSet.frames then wepI, firing = 1, false end
            end
        elseif firing then
            firing = false
        end

        for _, ts in pairs(thingStates) do
            if ts.state == "dying" then
                ts.animT = ts.animT + dt
                if ts.animT >= 0.12 then
                    ts.animT = 0
                    ts.animI = ts.animI + 1
                    if ts.animI >= #ts.dieF then
                        ts.animI = math.max(1, #ts.dieF)
                        ts.state = "corpse"
                    end
                    ts.patch = ts.dieF[ts.animI] or ts.patch
                end

            elseif ts.state == "alive" and ts.hostile and not player.dead then
                local dx, dy = player.x - ts.x, player.y - ts.y
                local dist = math.sqrt(dx*dx + dy*dy)
                ts.atkCD = math.max(0, ts.atkCD - dt)

                if dist < 1200 then
                    ts.aiT = ts.aiT + dt
                    if ts.aiT >= 0.25 then
                        ts.aiT = 0
                        ts.see = hasLOS(ts.x, ts.y, (ts.floorH or 0) + 40,
                                        player.x, player.y, player.z)
                        if ts.see then ts.awake = true end
                    end

                    if ts.awake then
                        if ts.see and dist <= ts.rng then
                            if ts.atkCD <= 0 and hasLOS(ts.x, ts.y, (ts.floorH or 0) + 40,
                                                        player.x, player.y, player.z) then
                                ts.atkCD = 1.4 + math.random() * 1.0
                                player:hurt(ts.dmg)
                                print(string.format("[DOOM] hit by %s dmg=%d dist=%.0f",
                                      tostring(ts.spr), ts.dmg, dist))
                            end
                        else
                            local step = ts.spd * dt
                            local nx = ts.x + (dx/dist)*step
                            local ny = ts.y + (dy/dist)*step
                            if not map.crosses(ts.x, ts.y, nx, ny) then
                                local s = map.sectorAt(nx, ny)
                                if s and math.abs(s.fh - ts.floorH) <= 24 then
                                    ts.x, ts.y, ts.floorH = nx, ny, s.fh
                                end
                            end
                            ts.animT = ts.animT + dt
                            if ts.animT >= 0.16 and #ts.walkF > 0 then
                                ts.animT = 0
                                ts.animI = (ts.animI % #ts.walkF) + 1
                                ts.patch = ts.walkF[ts.animI]
                            end
                        end
                    end
                end

            elseif ts.give and not ts.gone then
                local dx, dy = player.x - ts.x, player.y - ts.y
                if dx*dx + dy*dy < 32*32 and not player.dead then
                    local g, took = ts.give, false
                    if g.health and player.health < 100 then
                        player.health = math.min(100, player.health + g.health); took = true
                    end
                    if g.armor and player.armor < g.armor then
                        player.armor = g.armor
                        player.armorPct = g.armorpct or 0.333
                        took = true
                    end
                    if g.armorbonus and player.armor < 200 then
                        player.armor = math.min(200, player.armor + g.armorbonus)
                        took = true
                    end
                    if g.ammo and player.ammo < 200 then
                        player.ammo = math.min(200, player.ammo + g.ammo); took = true
                    end
                    if g.shells and player.shells < 100 then
                        player.shells = math.min(100, player.shells + g.shells); took = true
                    end
                    if g.weapon and not player.weapons[g.weapon] then
                        player.weapons[g.weapon] = true
                        player.weapon = g.weapon
                        firing, wepI, wepT = false, 1, 0
                        print("[DOOM] Picked up " .. WEAPONS[g.weapon].name)
                        took = true
                    end
                    if took then ts.gone = true end
                end
            end
        end

        player:update(dt)

        renderer.resetClip()
        local s = renderer.screen
        local half = SW * rshift(SH, 1)
        for i = 0,    half-1  do s[i] = skyBgIdx  end
        for i = half, SW*SH-1 do s[i] = floorBgIdx end

        renderer.renderBSP(map.ncount - 1, player, skyBgIdx)
        renderer.fillRemainder(skyBgIdx, floorBgIdx)
        renderer.renderSprites(thingStates, player)

        if not player.dead then
            local bobx = math.floor(math.cos(player.bobPhase) * 6 * player.bobAmt)
            local boby = math.floor(math.abs(math.sin(player.bobPhase)) * 5 * player.bobAmt)
            local ws = wepSets[player.weapon]
            renderer.renderWeapon(ws and (ws.frames[wepI] or ws.frames[1]) or nil,
                                  (flashT > 0) and ws and ws.flash[1] or nil,
                                  bobx, boby)
        end

        drawHUD(renderer.screen, player)

        fb:write(renderer.buildString())
        fb:draw(DSX, DSY, DSW, DSH)
    end)
end

local ok, err = pcall(main)
if not ok then
    print("[DOOM] FATAL: " .. tostring(err))
end
