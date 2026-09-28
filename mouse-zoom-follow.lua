--[[
  Mouse Zoom & Follow — script para OBS Studio (Windows)
  Feito por Pablo Ruan — https://github.com/pabloruancoder/mouse-zoom-follow
  Licença MIT

  Dá zoom em uma fonte ou cena em volta do cursor e faz a "câmera" seguir o
  mouse. Tudo é configurável em Ferramentas > Scripts; os atalhos de teclado
  ficam em Configurações > Teclas de atalho.

  Como funciona: o script adiciona à fonte dois filtros próprios
  ("Mouse Zoom (recorte)" e "Mouse Zoom (escala)"). O recorte seleciona a área
  ampliada e a escala devolve a imagem ao tamanho original, então a fonte
  continua ocupando o mesmo espaço em qualquer cena em que apareça. Fora do
  zoom os filtros ficam desativados, e são removidos ao descarregar o script.

  Rodinha e botões do mouse são lidos via Raw Input do Windows (sem hooks), por
  isso o evento continua chegando ao aplicativo em foco.

  Cursor personalizado: um terceiro filtro ("Mouse Zoom (cursor)"), aplicado
  antes do recorte, desenha a seta/imagem/ponto, o destaque e os efeitos de
  clique na posição do mouse. O cursor real da captura é ocultado enquanto um
  estilo personalizado estiver ativo.
]]

obs = obslua
local ffi = require("ffi")
local bit = require("bit")

local SCRIPT_VERSION = "1.3.1"
local IS_WINDOWS = (ffi.os == "Windows")

local CROP_FILTER_NAME = "Mouse Zoom (recorte)"
local SCALE_FILTER_NAME = "Mouse Zoom (escala)"
local CURSOR_FILTER_NAME = "Mouse Zoom (cursor)"
local CURSOR_FILTER_ID = "mouse_zoom_follow_cursor"
veja 
---------------------------------------------------------------------------
-- Win32
---------------------------------------------------------------------------

local user32 = nil
local kernel32 = nil

if IS_WINDOWS then
    ffi.cdef([[
        typedef struct { long x; long y; } MZ_POINT;
        typedef struct { long left; long top; long right; long bottom; } MZ_RECT;
        typedef struct {
            unsigned long cbSize;
            MZ_RECT rcMonitor;
            MZ_RECT rcWork;
            unsigned long dwFlags;
        } MZ_MONITORINFO;
        typedef int (__stdcall *MZ_MONITORENUMPROC)(void *hmon, void *hdc, MZ_RECT *rect, intptr_t data);

        typedef struct {
            unsigned long dwType;
            unsigned long dwSize;
            void *hDevice;
            uintptr_t wParam;
        } MZ_RAWINPUTHEADER;
        typedef struct {
            unsigned short usFlags;
            union {
                unsigned long ulButtons;
                struct { unsigned short usButtonFlags; short usButtonData; };
            };
            unsigned long ulRawButtons;
            long lLastX;
            long lLastY;
            unsigned long ulExtraInformation;
        } MZ_RAWMOUSE;
        typedef struct { MZ_RAWINPUTHEADER header; MZ_RAWMOUSE mouse; } MZ_RAWINPUT;
        typedef struct {
            unsigned short usUsagePage;
            unsigned short usUsage;
            unsigned long dwFlags;
            void *hwndTarget;
        } MZ_RAWINPUTDEVICE;
        typedef struct {
            void *hwnd;
            unsigned int message;
            uintptr_t wParam;
            intptr_t lParam;
            unsigned long time;
            MZ_POINT pt;
            unsigned long lPrivate;
        } MZ_MSG;

        int GetCursorPos(MZ_POINT *pt);
        int EnumDisplayMonitors(void *hdc, const MZ_RECT *clip, MZ_MONITORENUMPROC cb, intptr_t data);
        int GetMonitorInfoA(void *hmon, MZ_MONITORINFO *mi);
        short GetAsyncKeyState(int key);
        int RegisterRawInputDevices(const MZ_RAWINPUTDEVICE *devices, unsigned int count, unsigned int size);
        unsigned int GetRawInputData(void *raw, unsigned int command, void *data, unsigned int *size, unsigned int header_size);
        void *CreateWindowExA(unsigned long ex_style, const char *cls, const char *name, unsigned long style,
                              int x, int y, int w, int h, void *parent, void *menu, void *instance, void *param);
        void *FindWindowExA(void *parent, void *after, const char *cls, const char *name);
        unsigned long GetWindowThreadProcessId(void *hwnd, unsigned long *pid);
        unsigned long GetCurrentProcessId(void);
        unsigned long GetCurrentThreadId(void);
        int PeekMessageA(MZ_MSG *msg, void *hwnd, unsigned int min, unsigned int max, unsigned int remove);
        intptr_t DispatchMessageA(const MZ_MSG *msg);
    ]])
    user32 = ffi.load("user32")
    kernel32 = ffi.load("kernel32")
end

local cursor_pt = IS_WINDOWS and ffi.new("MZ_POINT") or nil

local function get_cursor_pos()
    if user32 == nil then return nil end
    if user32.GetCursorPos(cursor_pt) == 0 then return nil end
    return tonumber(cursor_pt.x), tonumber(cursor_pt.y)
end

local function key_down(vk)
    return bit.band(user32.GetAsyncKeyState(vk), 0x8000) ~= 0
end

local function enum_monitors()
    local list = {}
    if user32 == nil then return list end
    local cb = ffi.cast("MZ_MONITORENUMPROC", function(hmon, hdc, rect, data)
        local mi = ffi.new("MZ_MONITORINFO")
        mi.cbSize = ffi.sizeof("MZ_MONITORINFO")
        if user32.GetMonitorInfoA(hmon, mi) ~= 0 then
            local r = mi.rcMonitor
            list[#list + 1] = {
                x = tonumber(r.left), y = tonumber(r.top),
                w = tonumber(r.right - r.left), h = tonumber(r.bottom - r.top),
                primary = bit.band(tonumber(mi.dwFlags), 1) ~= 0,
            }
        end
        return 1
    end)
    user32.EnumDisplayMonitors(nil, nil, cb, 0)
    cb:free()
    return list
end
-- Callbacks FFI não podem ser chamados a partir de código compilado pelo JIT.
if jit then pcall(jit.off, enum_monitors) end

---------------------------------------------------------------------------
-- Raw Input (rodinha e botões do mouse)
--
-- Uma janela "message-only" recebe WM_INPUT mesmo sem foco (RIDEV_INPUTSINK).
-- As mensagens são lidas em script_tick, na mesma thread que criou a janela.
---------------------------------------------------------------------------

local RAW_WINDOW_TITLE = "MouseZoomFollowRawInput"
local WM_INPUT = 0x00FF
local RID_INPUT = 0x10000003
local RIDEV_REMOVE = 0x00000001
local RIDEV_INPUTSINK = 0x00000100
local RI_MOUSE_WHEEL = 0x0400

local MOUSE_BUTTONS = {
    middle = { down = 0x0010, up = 0x0020 },
    x1     = { down = 0x0040, up = 0x0080 },
    x2     = { down = 0x0100, up = 0x0200 },
}

local raw = { hwnd = nil, registered = false, failed = false }
local raw_msg = IS_WINDOWS and ffi.new("MZ_MSG") or nil
local raw_buf = IS_WINDOWS and ffi.new("uint8_t[256]") or nil
local raw_size = IS_WINDOWS and ffi.new("unsigned int[1]") or nil
local RAW_HEADER_SIZE = IS_WINDOWS and ffi.sizeof("MZ_RAWINPUTHEADER") or 0
local RAW_MOUSE_SIZE = IS_WINDOWS and ffi.sizeof("MZ_RAWINPUT") or 0

local function raw_register(hwnd, flags)
    local dev = ffi.new("MZ_RAWINPUTDEVICE[1]")
    dev[0].usUsagePage = 0x01 -- Generic Desktop
    dev[0].usUsage = 0x02     -- Mouse
    dev[0].dwFlags = flags
    dev[0].hwndTarget = hwnd
    return user32.RegisterRawInputDevices(dev, 1, ffi.sizeof("MZ_RAWINPUTDEVICE")) ~= 0
end

-- Precisa ser chamada de script_tick: a janela pertence à thread que a cria.
local function raw_start()
    if raw.registered or raw.failed or user32 == nil then return end
    local parent = ffi.cast("void *", -3) -- HWND_MESSAGE
    -- Reaproveita a janela de um carregamento anterior do script, mas só se for
    -- desta thread: a busca também encontra janelas de outros processos.
    local pid = ffi.new("unsigned long[1]")
    local my_pid, my_tid = kernel32.GetCurrentProcessId(), kernel32.GetCurrentThreadId()
    local hwnd = user32.FindWindowExA(parent, nil, "STATIC", RAW_WINDOW_TITLE)
    while hwnd ~= nil do
        local tid = user32.GetWindowThreadProcessId(hwnd, pid)
        if pid[0] == my_pid and tid == my_tid then break end
        hwnd = user32.FindWindowExA(parent, hwnd, "STATIC", RAW_WINDOW_TITLE)
    end
    if hwnd == nil then
        hwnd = user32.CreateWindowExA(0, "STATIC", RAW_WINDOW_TITLE, 0, 0, 0, 0, 0, parent, nil, nil, nil)
    end
    if hwnd == nil or not raw_register(hwnd, RIDEV_INPUTSINK) then
        raw.failed = true
        obs.script_log(obs.LOG_WARNING, "Não foi possível ativar a leitura da rodinha/botões do mouse.")
        return
    end
    raw.hwnd = hwnd
    raw.registered = true
end

local function raw_stop()
    if not raw.registered then return end
    raw_register(nil, RIDEV_REMOVE)
    raw.registered = false
end

-- Chama handler(button_flags, button_data) para cada evento de mouse pendente.
local function raw_poll(handler)
    while user32.PeekMessageA(raw_msg, raw.hwnd, WM_INPUT, WM_INPUT, 1) ~= 0 do
        raw_size[0] = 256
        local n = user32.GetRawInputData(ffi.cast("void *", raw_msg.lParam), RID_INPUT,
            raw_buf, raw_size, RAW_HEADER_SIZE)
        if n ~= 0xFFFFFFFF and n >= RAW_MOUSE_SIZE then
            local ri = ffi.cast("MZ_RAWINPUT *", raw_buf)
            if ri.header.dwType == 0 then -- RIM_TYPEMOUSE
                local flags = tonumber(ri.mouse.usButtonFlags)
                if flags ~= 0 then handler(flags, tonumber(ri.mouse.usButtonData)) end
            end
        end
        user32.DispatchMessageA(raw_msg) -- DefWindowProc faz a limpeza do WM_INPUT
    end
end

---------------------------------------------------------------------------
-- Configuração e estado
---------------------------------------------------------------------------

local cfg = {
    source_name    = "",
    zoom_factor    = 2.0,
    zoom_step      = 0.5,
    zoom_min       = 1.25,
    zoom_max       = 8.0,
    remember_level = false,
    duration       = 0.35,       -- segundos
    easing         = "cubic",
    origin         = "cursor_anchor",
    sampling       = "bicubic",
    follow_on_zoom = true,
    follow_speed   = 10,
    dead_zone      = 0.4,        -- fração da área visível
    follow_outside = false,
    idle_timeout   = 0,          -- segundos (0 = desativado)
    wheel_enabled  = true,
    wheel_mod      = "shift",
    wheel_step     = 0.25,
    wheel_invert   = false,
    wheel_duration = 0.15,
    btn_toggle     = "none",
    btn_toggle_mod = "none",
    btn_hold       = "none",
    btn_hold_mod   = "none",
    btn_follow     = "none",
    btn_follow_mod = "none",
    monitor_mode   = "auto",
    manual         = { x = 0, y = 0, w = 0, h = 0 },
    debug          = false,

    -- Cursor (cores no formato do OBS: 0xAABBGGRR)
    cursor_style      = "original",  -- original | arrow | image | dot | hidden
    cursor_size       = 32,          -- px (seta e ponto)
    arrow_fill        = 0xFFFFFFFF,
    arrow_outline     = 0xFF000000,
    dot_color         = 0xE63D3DFF,
    cursor_image      = "",
    cursor_image_scale = 1.0,
    cursor_hotspot_x  = 0,
    cursor_hotspot_y  = 0,
    cursor_keep_size  = false,       -- não ampliar o cursor junto com o zoom
    cursor_hide_idle  = 0,           -- segundos (0 = nunca)
    halo_enabled      = false,
    halo_color        = 0x6600D7FF,
    halo_size         = 60,
    click_enabled     = false,
    click_left_color  = 0xCCFF9B3D,
    click_right_color = 0xCC3D5BFF,
    click_size        = 50,
    click_duration    = 0.4,
}

local st = {
    source    = nil,    -- fonte com zoom (referência própria)
    source_name = nil,
    crop      = nil,    -- filtro de recorte (referência própria)
    scale     = nil,    -- filtro de escala (referência própria)
    w = 0, h = 0,       -- tamanho da fonte sem zoom
    region    = nil,
    mon       = nil,    -- retângulo da tela capturada, em coordenadas de tela
    zoomed    = false,  -- estado lógico (entrando/em zoom vs saindo/sem zoom)
    following = true,
    level     = 2.0,    -- nível de zoom alvo
    zoom      = 1.0,    -- nível de zoom atual (animado)
    cx = 0, cy = 0,     -- centro atual da área visível (coordenadas da fonte)
    tx = 0, ty = 0,     -- centro alvo
    anim      = nil,
    idle      = 0,
    last_mx   = nil,
    last_my   = nil,
    applied   = {},
    wheel     = 0,      -- cliques de rodinha acumulados no quadro
    hold_btn  = false,
}

local function log(msg) obs.script_log(obs.LOG_INFO, msg) end
local function dbg(msg) if cfg.debug then log(msg) end end

-- Evita repetir o mesmo aviso no log em sequência.
local last_warning = { msg = nil, time = 0 }
local function warn(msg)
    local now = obs.os_gettime_ns() / 1e9
    if msg == last_warning.msg and now - last_warning.time < 10 then return end
    last_warning.msg, last_warning.time = msg, now
    obs.script_log(obs.LOG_WARNING, msg)
end

local function clamp(v, lo, hi)
    if hi < lo then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local EASINGS = {
    linear   = function(t) return t end,
    smooth   = function(t) return t * t * (3 - 2 * t) end,
    cubic    = function(t)
        if t < 0.5 then return 4 * t * t * t end
        local f = -2 * t + 2
        return 1 - f * f * f / 2
    end,
    quad_out = function(t) return 1 - (1 - t) * (1 - t) end,
    expo_out = function(t)
        if t >= 1 then return 1 end
        return 1 - 2 ^ (-10 * t)
    end,
    back_out = function(t)
        local c1 = 1.70158
        local c3 = c1 + 1
        return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
    end,
}

local function ease(t)
    return (EASINGS[cfg.easing] or EASINGS.cubic)(t)
end

-- Compara exatamente as teclas Ctrl/Shift/Alt pressionadas com a combinação escolhida.
local function modifiers_match(mod)
    local want_ctrl = mod:find("ctrl", 1, true) ~= nil
    local want_shift = mod:find("shift", 1, true) ~= nil
    local want_alt = mod:find("alt", 1, true) ~= nil
    return key_down(0x11) == want_ctrl and key_down(0x10) == want_shift and key_down(0x12) == want_alt
end

---------------------------------------------------------------------------
-- Detecção do monitor capturado
---------------------------------------------------------------------------

-- Lê o monitor escolhido numa "Captura de Tela" a partir das propriedades da
-- própria fonte, cujos nomes têm o formato "...: 1920x1080 @ 0,0".
local function monitor_from_display_capture(source)
    if obs.obs_source_get_unversioned_id(source) ~= "monitor_capture" then return nil end

    local settings = obs.obs_source_get_settings(source)
    local cur_id = obs.obs_data_get_string(settings, "monitor_id")
    local cur_idx = obs.obs_data_get_int(settings, "monitor")
    obs.obs_data_release(settings)

    local props = obs.obs_source_properties(source)
    if props == nil then return nil end

    local result = nil
    local by_string = true
    local p = obs.obs_properties_get(props, "monitor_id")
    if p == nil then
        p = obs.obs_properties_get(props, "monitor")
        by_string = false
    end
    if p ~= nil then
        for i = 0, obs.obs_property_list_item_count(p) - 1 do
            local match
            if by_string then
                match = obs.obs_property_list_item_string(p, i) == cur_id
            else
                match = obs.obs_property_list_item_int(p, i) == cur_idx
            end
            if match then
                local name = obs.obs_property_list_item_name(p, i) or ""
                local w, h, x, y = name:match("(%d+)x(%d+) @ (%-?%d+),(%-?%d+)")
                if w then
                    result = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
                end
                break
            end
        end
    end
    obs.obs_properties_destroy(props)
    return result
end

-- Para uma cena, usa a primeira Captura de Tela dentro dela (incluindo grupos).
local function monitor_from_scene(source)
    local scene = obs.obs_scene_from_source(source)
    if scene == nil then scene = obs.obs_group_from_source(source) end
    if scene == nil then return nil end
    local result = nil
    local items = obs.obs_scene_enum_items(scene)
    if items ~= nil then
        for _, item in ipairs(items) do
            local child = obs.obs_sceneitem_get_source(item)
            result = monitor_from_display_capture(child)
            if result == nil and obs.obs_sceneitem_is_group(item) then
                result = monitor_from_scene(child)
            end
            if result ~= nil then break end
        end
        obs.sceneitem_list_release(items)
    end
    return result
end

local function resolve_monitor(source, src_w, src_h)
    local mode = cfg.monitor_mode

    if mode == "manual" then
        local m = cfg.manual
        if m.w > 0 and m.h > 0 then return { x = m.x, y = m.y, w = m.w, h = m.h } end
        warn("Área manual inválida (largura/altura 0); usando detecção automática.")
    else
        local x, y, w, h = mode:match("^mon:(%-?%d+),(%-?%d+),(%d+),(%d+)$")
        if x then return { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) } end
    end

    local m = monitor_from_display_capture(source) or monitor_from_scene(source)
    if m then return m end

    -- Sem Captura de Tela: tenta um monitor do mesmo tamanho da fonte (prioriza o principal).
    local primary, same_size = nil, nil
    for _, mon in ipairs(enum_monitors()) do
        if mon.primary then primary = mon end
        if mon.w == src_w and mon.h == src_h and (same_size == nil or mon.primary) then same_size = mon end
    end
    return same_size or primary or { x = 0, y = 0, w = src_w, h = src_h }
end

---------------------------------------------------------------------------
-- Filtros de zoom
---------------------------------------------------------------------------

local function set_filters_enabled(source, enabled)
    for _, name in ipairs({ CROP_FILTER_NAME, SCALE_FILTER_NAME }) do
        local f = obs.obs_source_get_filter_by_name(source, name)
        if f ~= nil then
            obs.obs_source_set_enabled(f, enabled)
            obs.obs_source_release(f)
        end
    end
end

local ZOOM_FILTERS = { CROP_FILTER_NAME, SCALE_FILTER_NAME }
local ALL_FILTERS = { CURSOR_FILTER_NAME, CROP_FILTER_NAME, SCALE_FILTER_NAME }

local function remove_filters_from(source, names)
    for _, name in ipairs(names or ALL_FILTERS) do
        local f = obs.obs_source_get_filter_by_name(source, name)
        if f ~= nil then
            obs.obs_source_filter_remove(source, f)
            obs.obs_source_release(f)
        end
    end
end

-- Remove os filtros do script de todas as fontes e cenas.
local function remove_all_filters()
    for _, list_fn in ipairs({ obs.obs_enum_sources, obs.obs_frontend_get_scenes }) do
        local list = list_fn()
        if list ~= nil then
            for _, s in ipairs(list) do remove_filters_from(s, ALL_FILTERS) end
            obs.source_list_release(list)
        end
    end
end

-- Retorna o filtro (com referência), criando-o no fim da lista se não existir.
local function ensure_filter(source, name, kind, settings)
    local f = obs.obs_source_get_filter_by_name(source, name)
    if f == nil then
        f = obs.obs_source_create_private(kind, name, settings)
        if f ~= nil then obs.obs_source_filter_add(source, f) end
    else
        obs.obs_source_update(f, settings)
    end
    return f
end

local function update_scale_filter()
    if st.scale == nil then return end
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "resolution", string.format("%dx%d", st.w, st.h))
    obs.obs_data_set_string(s, "sampling", cfg.sampling)
    obs.obs_data_set_bool(s, "undistort", false)
    obs.obs_source_update(st.scale, s)
    obs.obs_data_release(s)
end

---------------------------------------------------------------------------
-- Sessão de zoom
---------------------------------------------------------------------------

-- Posição do cursor em coordenadas da fonte.
local function cursor_source()
    if st.source == nil or st.mon == nil then return nil end
    local mx, my = get_cursor_pos()
    if mx == nil then return nil end
    local m = st.mon
    local inside = mx >= m.x and mx < m.x + m.w and my >= m.y and my < m.y + m.h
    local sx = (mx - m.x) * st.w / m.w
    local sy = (my - m.y) * st.h / m.h
    return sx, sy, inside, mx, my
end

-- Nome da primeira Captura de Tela visível dentro da cena (entra em grupos e cenas aninhadas).
local function find_capture_in_scene(scene_source, depth)
    if depth > 8 then return nil end
    local scene = obs.obs_scene_from_source(scene_source)
    if scene == nil then scene = obs.obs_group_from_source(scene_source) end
    if scene == nil then return nil end
    local found = nil
    local items = obs.obs_scene_enum_items(scene)
    if items ~= nil then
        -- A lista vem de baixo para cima; percorre de cima para baixo (o que aparece por cima primeiro).
        for i = #items, 1, -1 do
            local item = items[i]
            if obs.obs_sceneitem_visible(item) then
                local child = obs.obs_sceneitem_get_source(item)
                local id = obs.obs_source_get_unversioned_id(child)
                if id == "monitor_capture" then
                    found = obs.obs_source_get_name(child)
                elseif id == "scene" or id == "group" then
                    found = find_capture_in_scene(child, depth + 1)
                end
                if found ~= nil then break end
            end
        end
        obs.sceneitem_list_release(items)
    end
    return found
end

local function find_auto_capture()
    local scene_source = obs.obs_frontend_get_current_scene()
    if scene_source ~= nil then
        local name = find_capture_in_scene(scene_source, 0)
        obs.obs_source_release(scene_source)
        if name ~= nil then return name end
    end
    -- Nenhuma visível na cena: usa qualquer Captura de Tela existente.
    local name = nil
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            if obs.obs_source_get_unversioned_id(s) == "monitor_capture" then
                name = obs.obs_source_get_name(s)
                break
            end
        end
        obs.source_list_release(sources)
    end
    return name
end

-- Fonte configurada, ou a Captura de Tela automática. Retorna a fonte com referência e seu nome.
local function resolve_source(quiet)
    if cfg.source_name ~= "" then
        local source = obs.obs_get_source_by_name(cfg.source_name)
        if source ~= nil then return source, cfg.source_name end
        if not quiet then
            warn("A fonte '" .. cfg.source_name .. "' não existe; usando a Captura de Tela da cena atual. " ..
                "Escolha a fonte certa em Ferramentas > Scripts.")
        end
    end
    local name = find_auto_capture()
    if name == nil then return nil end
    return obs.obs_get_source_by_name(name), name
end

local function begin_session()
    if st.source ~= nil then return true end
    if not IS_WINDOWS then
        warn("Este script suporta apenas Windows no momento.")
        return false
    end

    local source, name = resolve_source()
    if source == nil then
        warn("Nenhuma Captura de Tela encontrada. Adicione uma à cena ou escolha a fonte em Ferramentas > Scripts.")
        return false
    end

    -- Filtros desativados deixam a imagem passar direto: mede o tamanho sem zoom.
    set_filters_enabled(source, false)
    local w = obs.obs_source_get_width(source)
    local h = obs.obs_source_get_height(source)
    if w == 0 or h == 0 then
        warn("A fonte '" .. name .. "' está sem imagem (tamanho 0).")
        obs.obs_source_release(source)
        return false
    end

    local cs = obs.obs_data_create()
    obs.obs_data_set_bool(cs, "relative", false)
    obs.obs_data_set_int(cs, "left", 0)
    obs.obs_data_set_int(cs, "top", 0)
    obs.obs_data_set_int(cs, "cx", w)
    obs.obs_data_set_int(cs, "cy", h)
    local crop = ensure_filter(source, CROP_FILTER_NAME, "crop_filter", cs)
    obs.obs_data_release(cs)

    local ss = obs.obs_data_create()
    local scale = ensure_filter(source, SCALE_FILTER_NAME, "scale_filter", ss)
    obs.obs_data_release(ss)

    if crop == nil or scale == nil then
        warn("Não foi possível criar os filtros de zoom na fonte '" .. name .. "'.")
        if crop ~= nil then obs.obs_source_release(crop) end
        if scale ~= nil then obs.obs_source_release(scale) end
        obs.obs_source_release(source)
        return false
    end

    st.source, st.crop, st.scale = source, crop, scale
    st.source_name = name
    st.w, st.h = w, h
    st.region = { x = 0, y = 0, w = w, h = h }
    st.mon = resolve_monitor(source, w, h)
    st.zoom = 1.0
    st.cx, st.cy = w / 2, h / 2
    st.tx, st.ty = st.cx, st.cy
    st.anim = nil
    st.applied = {}
    update_scale_filter()
    obs.obs_source_set_enabled(crop, true)
    obs.obs_source_set_enabled(scale, true)

    dbg(string.format("Sessão iniciada: fonte '%s' %dx%d, monitor %dx%d @ %d,%d",
        name, w, h, st.mon.w, st.mon.h, st.mon.x, st.mon.y))
    return true
end

local function end_session()
    if st.source ~= nil then
        obs.obs_source_set_enabled(st.crop, false)
        obs.obs_source_set_enabled(st.scale, false)
        obs.obs_source_release(st.crop)
        obs.obs_source_release(st.scale)
        obs.obs_source_release(st.source)
        dbg("Sessão encerrada.")
    end
    st.source, st.crop, st.scale = nil, nil, nil
    st.source_name = nil
    st.region = nil
    st.anim = nil
    st.zoomed = false
    st.zoom = 1.0
    st.applied = {}
    st.hold_btn = false
end

local function apply_transform()
    local reg = st.region
    local z = math.max(1, st.zoom)
    local vw, vh = reg.w / z, reg.h / z

    local W = clamp(math.floor(vw + 0.5), 1, reg.w)
    local H = clamp(math.floor(vh + 0.5), 1, reg.h)
    local L = clamp(math.floor(st.cx - vw / 2 + 0.5), reg.x, reg.x + reg.w - W)
    local T = clamp(math.floor(st.cy - vh / 2 + 0.5), reg.y, reg.y + reg.h - H)

    local a = st.applied
    if a.L == L and a.T == T and a.W == W and a.H == H then return end
    a.L, a.T, a.W, a.H = L, T, W, H

    local s = obs.obs_data_create()
    obs.obs_data_set_int(s, "left", L)
    obs.obs_data_set_int(s, "top", T)
    obs.obs_data_set_int(s, "cx", W)
    obs.obs_data_set_int(s, "cy", H)
    obs.obs_source_update(st.crop, s)
    obs.obs_data_release(s)
end

---------------------------------------------------------------------------
-- Animação e controle de zoom
---------------------------------------------------------------------------

local function step_animation(dt)
    local a, reg = st.anim, st.region
    if a.dur <= 0 then
        a.t = 1
    else
        a.t = math.min(1, a.t + dt / a.dur)
    end

    local e = ease(a.t)
    local z = math.max(1, a.z0 * (a.z1 / a.z0) ^ e)   -- interpolação exponencial = zoom uniforme
    local vw, vh = reg.w / z, reg.h / z

    -- A posição acompanha a variação de largura: mantém o ponto de ancoragem fixo na tela.
    local k = e
    if math.abs(a.vw0 - a.vw1) > 1e-6 then k = (a.vw0 - vw) / (a.vw0 - a.vw1) end
    local l = a.l0 + (a.l1 - a.l0) * k
    local t = a.t0 + (a.t1 - a.t0) * k

    st.zoom = z
    st.cx, st.cy = l + vw / 2, t + vh / 2

    if a.t >= 1 then
        st.anim = nil
        st.zoom = a.z1
        st.cx, st.cy = a.l1 + a.vw1 / 2, a.t1 + a.vh1 / 2
        st.tx, st.ty = st.cx, st.cy
        if not st.zoomed then end_session() end
    end
end

local function animate_to(z_to, duration)
    local reg = st.region
    local z0 = math.max(1, st.zoom)
    local vw0, vh0 = reg.w / z0, reg.h / z0
    local l0 = clamp(st.cx - vw0 / 2, reg.x, reg.x + reg.w - vw0)
    local t0 = clamp(st.cy - vh0 / 2, reg.y, reg.y + reg.h - vh0)

    -- Ponto de ancoragem do zoom e sua posição relativa na área visível.
    local px, py = l0 + vw0 / 2, t0 + vh0 / 2
    local sx, sy, inside = cursor_source()
    if cfg.origin ~= "center" and sx ~= nil and (inside or cfg.follow_outside) then
        px = clamp(sx, l0, l0 + vw0)
        py = clamp(sy, t0, t0 + vh0)
    end
    local fx, fy = (px - l0) / vw0, (py - t0) / vh0
    if cfg.origin == "cursor_center" then fx, fy = 0.5, 0.5 end

    local vw1, vh1 = reg.w / z_to, reg.h / z_to
    st.anim = {
        t = 0, dur = duration or cfg.duration, z0 = z0, z1 = z_to,
        l0 = l0, t0 = t0, vw0 = vw0, vh0 = vh0,
        l1 = clamp(px - fx * vw1, reg.x, reg.x + reg.w - vw1),
        t1 = clamp(py - fy * vh1, reg.y, reg.y + reg.h - vh1),
        vw1 = vw1, vh1 = vh1,
    }

    if st.anim.dur <= 0 then
        step_animation(0)
        if st.source ~= nil then apply_transform() end
    end
end

local function clamp_level(z)
    return clamp(z, cfg.zoom_min, cfg.zoom_max)
end

-- level: nível inicial opcional (usado pela rodinha).
local function zoom_in(level, duration)
    if not begin_session() then return end
    if not st.zoomed then
        st.zoomed = true
        st.following = cfg.follow_on_zoom
        st.idle = 0
        if level ~= nil then
            st.level = clamp_level(level)
        elseif not cfg.remember_level then
            st.level = clamp_level(cfg.zoom_factor)
        end
    end
    dbg(string.format("Zoom %.2fx", st.level))
    animate_to(st.level, duration)
end

local function zoom_out(duration)
    if st.source == nil then return end
    st.zoomed = false
    dbg("Saindo do zoom")
    animate_to(1.0, duration)
end

-- Soma delta ao nível de zoom; abaixo do mínimo sai do zoom.
local function change_level(delta, duration)
    if not st.zoomed then
        if delta > 0 then zoom_in(nil, duration) end
        return
    end
    local new_level = st.level + delta
    if new_level < cfg.zoom_min - 1e-6 then
        zoom_out(duration)
        return
    end
    st.level = clamp_level(new_level)
    dbg(string.format("Zoom %.2fx", st.level))
    animate_to(st.level, duration)
end

local function toggle_zoom()
    if st.zoomed then zoom_out() else zoom_in() end
end

local function toggle_follow()
    st.following = not st.following
    log("Seguir mouse: " .. (st.following and "ativado" or "desativado"))
end

---------------------------------------------------------------------------
-- Cursor personalizado
--
-- O filtro de cursor fica antes dos filtros de zoom, então o que ele desenha
-- é ampliado junto com a imagem, como o cursor real da captura.
---------------------------------------------------------------------------

-- Chave da opção "capturar cursor" em cada tipo de captura.
local CAPTURE_CURSOR_KEYS = {
    monitor_capture = "capture_cursor",
    window_capture  = "cursor",
    game_capture    = "capture_cursor",
}

local cur = {
    target      = nil,   -- nome da fonte com o filtro de cursor
    hidden      = nil,   -- nome da captura com o cursor real ocultado
    mon         = nil,   -- monitor da fonte com o filtro
    mon_dirty   = true,
    image       = nil,   -- image_source privada
    image_path  = "",
    effect      = nil,   -- efeito de círculo (criado na thread gráfica)
    effect_failed = false,
    ripples     = {},    -- efeitos de clique ativos
    last_x = nil, last_y = nil,
    idle        = 0,
    sync_timer  = 1e9,   -- força a primeira sincronização
}

local CIRCLE_EFFECT = [[
uniform float4x4 ViewProj;
uniform float4 color;
uniform float ring_start;
uniform float soft;

struct VertData {
    float4 pos : POSITION;
    float2 uv  : TEXCOORD0;
};

VertData VSDefault(VertData v_in)
{
    VertData v_out;
    v_out.pos = mul(float4(v_in.pos.xyz, 1.0), ViewProj);
    v_out.uv = v_in.uv;
    return v_out;
}

float4 PSCircle(VertData v_in) : TARGET
{
    float d = distance(v_in.uv, float2(0.5, 0.5)) * 2.0;
    float a = 1.0 - smoothstep(1.0 - soft, 1.0, d);
    a = a * lerp(1.0, smoothstep(ring_start - soft, ring_start, d), step(0.0001, ring_start));
    a = a * color.a;
    return float4(color.rgb * a, a);
}

technique Draw
{
    pass
    {
        vertex_shader = VSDefault(v_in);
        pixel_shader  = PSCircle(v_in);
    }
}
]]

-- Seta clássica com a ponta em (0,0) e altura 1, em triângulos.
local ARROW_TRIS = {
    { 0, 0,       0, 0.85,     0.22, 0.66 },
    { 0, 0,       0.22, 0.66,  0.34, 0.62 },
    { 0, 0,       0.34, 0.62,  0.62, 0.62 },
    { 0.22, 0.66, 0.36, 1.0,   0.48, 0.95 },
    { 0.22, 0.66, 0.48, 0.95,  0.34, 0.62 },
}
local OUTLINE_OFFSETS = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }

local function cursor_features_on()
    return cfg.cursor_style ~= "original" or cfg.halo_enabled or cfg.click_enabled
end

local color_vec = obs.vec4()

-- Cor do OBS (0xAABBGGRR) para o parâmetro do efeito; premultiply para o efeito Solid.
local function set_color_param(effect, abgr, alpha, premultiply)
    local a = bit.band(bit.rshift(abgr, 24), 0xFF) / 255 * alpha
    local m = premultiply and a or 1
    color_vec.x = bit.band(abgr, 0xFF) / 255 * m
    color_vec.y = bit.band(bit.rshift(abgr, 8), 0xFF) / 255 * m
    color_vec.z = bit.band(bit.rshift(abgr, 16), 0xFF) / 255 * m
    color_vec.w = a
    obs.gs_effect_set_vec4(obs.gs_effect_get_param_by_name(effect, "color"), color_vec)
end

-- inner: 0 = círculo cheio; >0 = anel (fração do raio onde o anel começa).
local function draw_circle(x, y, radius, abgr, alpha, inner)
    local e = cur.effect
    if e == nil or radius < 0.5 or alpha <= 0 then return end
    set_color_param(e, abgr, alpha, false)
    obs.gs_effect_set_float(obs.gs_effect_get_param_by_name(e, "ring_start"), inner or 0)
    obs.gs_effect_set_float(obs.gs_effect_get_param_by_name(e, "soft"), math.min(0.5, 1.5 / radius))
    local size = math.max(1, math.floor(radius * 2 + 0.5))
    obs.gs_matrix_push()
    obs.gs_matrix_translate3f(x - size / 2, y - size / 2, 0)
    while obs.gs_effect_loop(e, "Draw") do
        obs.gs_draw_sprite(nil, 0, size, size)
    end
    obs.gs_matrix_pop()
end

local function draw_arrow_shape(x, y, size, abgr, alpha)
    local solid = obs.obs_get_base_effect(obs.OBS_EFFECT_SOLID)
    set_color_param(solid, abgr, alpha, true)
    while obs.gs_effect_loop(solid, "Solid") do
        obs.gs_render_start(true)
        for _, t in ipairs(ARROW_TRIS) do
            for i = 1, 5, 2 do obs.gs_vertex2f(x + t[i] * size, y + t[i + 1] * size) end
        end
        obs.gs_render_stop(obs.GS_TRIS)
    end
end

local function draw_arrow(x, y, size, alpha)
    if alpha <= 0 then return end
    local o = math.max(1, size / 16)
    for _, d in ipairs(OUTLINE_OFFSETS) do
        draw_arrow_shape(x + d[1] * o, y + d[2] * o, size, cfg.arrow_outline, alpha)
    end
    draw_arrow_shape(x, y, size, cfg.arrow_fill, alpha)
end

local function draw_image(x, y, scale)
    local img = cur.image
    if img == nil or obs.obs_source_get_width(img) == 0 then return false end
    obs.gs_matrix_push()
    obs.gs_matrix_translate3f(x - cfg.cursor_hotspot_x * scale, y - cfg.cursor_hotspot_y * scale, 0)
    obs.gs_matrix_scale3f(scale, scale, 1)
    obs.obs_source_video_render(img)
    obs.gs_matrix_pop()
    return true
end

-- O OBS sempre usa get_width/get_height de filtros Lua; sem elas o filtro teria
-- tamanho 0. Devolve o tamanho da imagem que chega ao filtro. Usa o tamanho
-- "base" do alvo para não voltar a consultar este mesmo filtro.
local function filter_input_size(data)
    local target = obs.obs_filter_get_target(data.source)
    if target == nil then return 0, 0 end
    return obs.obs_source_get_base_width(target), obs.obs_source_get_base_height(target)
end

local function cursor_filter_render(data)
    local filter = data.source
    obs.obs_source_skip_video_filter(filter)

    local m = cur.mon
    if m == nil or not cursor_features_on() then return end
    local parent = obs.obs_filter_get_parent(filter)
    local w, h = filter_input_size(data)
    if parent == nil or w == 0 or h == 0 then return end
    if not cur.render_logged then
        cur.render_logged = true
        dbg(string.format("Desenhando cursor: fonte %dx%d, monitor %dx%d @ %d,%d", w, h, m.w, m.h, m.x, m.y))
    end
    local mx, my = get_cursor_pos()
    if mx == nil then return end

    if cur.effect == nil and not cur.effect_failed then
        cur.effect = obs.gs_effect_create(CIRCLE_EFFECT, "mouse_zoom_circle.effect", nil)
        if cur.effect == nil then
            cur.effect_failed = true
            warn("Não foi possível criar o efeito de desenho do cursor.")
        end
    end

    -- Tamanhos são configurados em pixels da tela; k desfaz a ampliação do zoom se pedido.
    local k = w / m.w
    if cfg.cursor_keep_size and st.source_name ~= nil and st.source_name == obs.obs_source_get_name(parent) then
        k = k / math.max(1, st.zoom)
    end
    local function to_source(x, y) return (x - m.x) * w / m.w, (y - m.y) * h / m.h end

    obs.gs_blend_state_push()
    obs.gs_blend_function(obs.GS_BLEND_ONE, obs.GS_BLEND_INVSRCALPHA)

    -- Efeitos de clique: anel que cresce e some.
    local now = obs.os_gettime_ns() / 1e9
    for i = #cur.ripples, 1, -1 do
        local r = cur.ripples[i]
        local p = (now - r.t) / math.max(0.05, cfg.click_duration)
        if p >= 1 then
            table.remove(cur.ripples, i)
        else
            local rx, ry = to_source(r.x, r.y)
            local grow = 1 - (1 - p) * (1 - p)
            draw_circle(rx, ry, cfg.click_size / 2 * (0.3 + 0.7 * grow) * k, r.color, 1 - p, 0.7)
        end
    end

    local inside = mx >= m.x and mx < m.x + m.w and my >= m.y and my < m.y + m.h
    if inside then
        local alpha = 1
        if cfg.cursor_hide_idle > 0 and cur.idle > cfg.cursor_hide_idle then
            alpha = math.max(0, 1 - (cur.idle - cfg.cursor_hide_idle) / 0.4)
        end
        local sx, sy = to_source(mx, my)
        if cfg.halo_enabled then draw_circle(sx, sy, cfg.halo_size / 2 * k, cfg.halo_color, alpha, 0) end

        local style = cfg.cursor_style
        if style == "image" and alpha > 0 then
            if not draw_image(sx, sy, cfg.cursor_image_scale * k) then style = "arrow" end
        end
        if style == "arrow" then
            draw_arrow(sx, sy, cfg.cursor_size * k, alpha)
        elseif style == "dot" then
            draw_circle(sx, sy, cfg.cursor_size / 2 * k, cfg.dot_color, alpha, 0)
        end
    end

    obs.gs_blend_state_pop()
end

local cursor_filter_info = {
    id = CURSOR_FILTER_ID,
    type = obs.OBS_SOURCE_TYPE_FILTER,
    output_flags = obs.OBS_SOURCE_VIDEO,
    get_name = function() return "Mouse Zoom: cursor personalizado" end,
    create = function(settings, source) return { source = source } end,
    destroy = function(data) end,
    get_width = function(data) return (filter_input_size(data)) end,
    get_height = function(data) local _, h = filter_input_size(data); return h end,
    video_render = function(data, effect) cursor_filter_render(data) end,
}

local function set_capture_cursor(name, visible)
    local s = obs.obs_get_source_by_name(name)
    if s == nil then return end
    local key = CAPTURE_CURSOR_KEYS[obs.obs_source_get_unversioned_id(s)]
    if key ~= nil then
        local d = obs.obs_data_create()
        obs.obs_data_set_bool(d, key, visible)
        obs.obs_source_update(s, d)
        obs.obs_data_release(d)
    end
    obs.obs_source_release(s)
end

local function restore_capture_cursor()
    if cur.hidden ~= nil then
        set_capture_cursor(cur.hidden, true)
        dbg("Cursor real reexibido em '" .. cur.hidden .. "'.")
        cur.hidden = nil
    end
end

local function detach_cursor_filter()
    if cur.target == nil then return end
    local s = obs.obs_get_source_by_name(cur.target)
    if s ~= nil then
        remove_filters_from(s, { CURSOR_FILTER_NAME })
        obs.obs_source_release(s)
    end
    cur.target = nil
end

-- Mantém o filtro de cursor na fonte certa e o cursor real oculto quando necessário.
local function sync_cursor()
    local source, name = nil, nil
    if cursor_features_on() then source, name = resolve_source(true) end

    local want_hidden = nil
    if source ~= nil and cfg.cursor_style ~= "original" then
        if CAPTURE_CURSOR_KEYS[obs.obs_source_get_unversioned_id(source)] ~= nil then
            want_hidden = name
        else
            want_hidden = find_capture_in_scene(source, 0)
        end
    end

    -- Durante o zoom não mexe na ordem dos filtros; tenta de novo depois.
    if name ~= cur.target and st.source == nil then
        detach_cursor_filter()
        if source ~= nil then
            -- O cursor precisa vir antes do recorte: tira os filtros de zoom (são recriados no próximo zoom).
            remove_filters_from(source, ALL_FILTERS)
            local f = obs.obs_source_create_private(CURSOR_FILTER_ID, CURSOR_FILTER_NAME, nil)
            if f ~= nil then
                obs.obs_source_filter_add(source, f)
                obs.obs_source_release(f)
                cur.target = name
                cur.mon_dirty = true
                dbg("Filtro de cursor adicionado em '" .. name .. "'.")
            end
        end
    end

    if want_hidden ~= cur.hidden then
        restore_capture_cursor()
        if want_hidden ~= nil then
            set_capture_cursor(want_hidden, false)
            cur.hidden = want_hidden
            dbg("Cursor real ocultado em '" .. want_hidden .. "'.")
        end
    end

    if source ~= nil and cur.mon_dirty and name == cur.target then
        cur.mon = resolve_monitor(source, obs.obs_source_get_width(source), obs.obs_source_get_height(source))
        cur.mon_dirty = false
    end
    if source ~= nil then obs.obs_source_release(source) end
end

-- Carrega a imagem do cursor quando o caminho muda (chamada fora da thread gráfica).
local function sync_cursor_image()
    local path = (cfg.cursor_style == "image") and cfg.cursor_image or ""
    if path == cur.image_path then return end
    if cur.image ~= nil then
        obs.obs_source_dec_showing(cur.image)
        obs.obs_source_release(cur.image)
        cur.image = nil
    end
    cur.image_path = path
    if path ~= "" then
        local s = obs.obs_data_create()
        obs.obs_data_set_string(s, "file", path)
        cur.image = obs.obs_source_create_private("image_source", "Mouse Zoom (imagem do cursor)", s)
        obs.obs_data_release(s)
        if cur.image ~= nil then obs.obs_source_inc_showing(cur.image) end
    end
end

local function cursor_tick(dt)
    local mx, my = get_cursor_pos()
    if mx ~= cur.last_x or my ~= cur.last_y then
        cur.idle = 0
        cur.last_x, cur.last_y = mx, my
    else
        cur.idle = cur.idle + dt
    end
    cur.sync_timer = cur.sync_timer + dt
    if cur.sync_timer >= 1 and (cursor_features_on() or cur.target ~= nil or cur.hidden ~= nil) then
        cur.sync_timer = 0
        sync_cursor()
    end
end

local function add_click_ripple(color)
    local x, y = get_cursor_pos()
    if x == nil then return end
    if #cur.ripples >= 20 then table.remove(cur.ripples, 1) end
    cur.ripples[#cur.ripples + 1] = { x = x, y = y, t = obs.os_gettime_ns() / 1e9, color = color }
end

local function shutdown_cursor()
    detach_cursor_filter()
    restore_capture_cursor()
    cur.ripples = {}
end

---------------------------------------------------------------------------
-- Rodinha e botões do mouse
---------------------------------------------------------------------------

local RI_MOUSE_LEFT_DOWN = 0x0001
local RI_MOUSE_RIGHT_DOWN = 0x0004

local function mouse_input_wanted()
    return cfg.wheel_enabled or cfg.click_enabled
        or cfg.btn_toggle ~= "none" or cfg.btn_hold ~= "none" or cfg.btn_follow ~= "none"
end

local function button_pressed(flags, button, mod)
    local b = MOUSE_BUTTONS[button]
    return b ~= nil and bit.band(flags, b.down) ~= 0 and modifiers_match(mod)
end

local function on_raw_mouse(flags, data)
    if cfg.click_enabled then
        if bit.band(flags, RI_MOUSE_LEFT_DOWN) ~= 0 then add_click_ripple(cfg.click_left_color) end
        if bit.band(flags, RI_MOUSE_RIGHT_DOWN) ~= 0 then add_click_ripple(cfg.click_right_color) end
    end
    if cfg.wheel_enabled and bit.band(flags, RI_MOUSE_WHEEL) ~= 0 and modifiers_match(cfg.wheel_mod) then
        st.wheel = st.wheel + data / 120
    end
    if button_pressed(flags, cfg.btn_toggle, cfg.btn_toggle_mod) then toggle_zoom() end
    if button_pressed(flags, cfg.btn_follow, cfg.btn_follow_mod) then toggle_follow() end
    if button_pressed(flags, cfg.btn_hold, cfg.btn_hold_mod) then
        st.hold_btn = true
        zoom_in()
    end
    local hold = MOUSE_BUTTONS[cfg.btn_hold]
    if hold ~= nil and st.hold_btn and bit.band(flags, hold.up) ~= 0 then
        st.hold_btn = false
        zoom_out()
    end
end

local function process_mouse_input()
    if not mouse_input_wanted() then
        raw_stop()
        return
    end
    raw_start()
    if not raw.registered then return end
    raw_poll(on_raw_mouse)

    if st.wheel ~= 0 then
        local notches = st.wheel
        st.wheel = 0
        if cfg.wheel_invert then notches = -notches end
        if notches > 0 and not st.zoomed then
            zoom_in(1 + cfg.wheel_step * notches, cfg.wheel_duration)
        else
            change_level(cfg.wheel_step * notches, cfg.wheel_duration)
        end
    end
end

---------------------------------------------------------------------------
-- Atalhos de teclado
---------------------------------------------------------------------------

local HOTKEYS = {
    { id = "toggle_zoom",   desc = "Mouse Zoom: Ativar/desativar zoom",
      default = { key = "OBS_KEY_Z", ctrl = true, alt = true },
      cb = function(pressed) if pressed then toggle_zoom() end end },
    { id = "hold_zoom",     desc = "Mouse Zoom: Zoom enquanto segurar",
      default = { key = "OBS_KEY_X", ctrl = true, alt = true },
      cb = function(pressed) if pressed then zoom_in() else zoom_out() end end },
    { id = "toggle_follow", desc = "Mouse Zoom: Ativar/desativar seguir o mouse",
      default = { key = "OBS_KEY_F", ctrl = true, alt = true },
      cb = function(pressed) if pressed then toggle_follow() end end },
    { id = "zoom_more",     desc = "Mouse Zoom: Aumentar zoom",
      default = { key = "OBS_KEY_UP", ctrl = true, alt = true },
      cb = function(pressed) if pressed then change_level(cfg.zoom_step) end end },
    { id = "zoom_less",     desc = "Mouse Zoom: Diminuir zoom",
      default = { key = "OBS_KEY_DOWN", ctrl = true, alt = true },
      cb = function(pressed) if pressed then change_level(-cfg.zoom_step) end end },
    { id = "reset_level",   desc = "Mouse Zoom: Voltar ao nível de zoom padrão",
      default = { key = "OBS_KEY_0", ctrl = true, alt = true },
      cb = function(pressed)
          if not pressed then return end
          st.level = clamp_level(cfg.zoom_factor)
          if st.zoomed then animate_to(st.level) end
      end },
    { id = "recenter",      desc = "Mouse Zoom: Centralizar no mouse",
      default = { key = "OBS_KEY_C", ctrl = true, alt = true },
      cb = function(pressed)
          if not pressed or st.source == nil then return end
          local sx, sy = cursor_source()
          if sx ~= nil then st.tx, st.ty = sx, sy end
      end },
}

local function make_binding(def)
    local arr = obs.obs_data_array_create()
    if def ~= nil then
        local d = obs.obs_data_create()
        obs.obs_data_set_string(d, "key", def.key)
        if def.ctrl then obs.obs_data_set_bool(d, "control", true) end
        if def.alt then obs.obs_data_set_bool(d, "alt", true) end
        if def.shift then obs.obs_data_set_bool(d, "shift", true) end
        obs.obs_data_array_push_back(arr, d)
        obs.obs_data_release(d)
    end
    return arr
end

local function restore_default_hotkeys()
    for _, hk in ipairs(HOTKEYS) do
        local arr = make_binding(hk.default)
        obs.obs_hotkey_load(hk.handle, arr)
        obs.obs_data_array_release(arr)
    end
    log("Atalhos padrão restaurados. Reabra Configurações > Teclas de atalho para vê-los.")
end

---------------------------------------------------------------------------
-- Propriedades (interface em Ferramentas > Scripts)
---------------------------------------------------------------------------

local function fill_source_list(p)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, "Automático (Captura de Tela visível na cena atual)", "")
    local captures, others, scenes = {}, {}, {}
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, s in ipairs(sources) do
            if bit.band(obs.obs_source_get_output_flags(s), obs.OBS_SOURCE_VIDEO) ~= 0 then
                local name = obs.obs_source_get_name(s)
                if obs.obs_source_get_unversioned_id(s) == "monitor_capture" then
                    captures[#captures + 1] = name
                else
                    others[#others + 1] = name
                end
            end
        end
        obs.source_list_release(sources)
    end
    local scene_sources = obs.obs_frontend_get_scenes()
    if scene_sources ~= nil then
        for _, s in ipairs(scene_sources) do scenes[#scenes + 1] = obs.obs_source_get_name(s) end
        obs.source_list_release(scene_sources)
    end
    table.sort(captures)
    table.sort(others)
    table.sort(scenes)
    for _, n in ipairs(captures) do obs.obs_property_list_add_string(p, n .. "  (Captura de Tela)", n) end
    for _, n in ipairs(others) do obs.obs_property_list_add_string(p, n, n) end
    for _, n in ipairs(scenes) do obs.obs_property_list_add_string(p, n .. "  (Cena inteira)", n) end
end

local function fill_monitor_list(p)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, "Automático (usa o monitor da Captura de Tela)", "auto")
    for i, m in ipairs(enum_monitors()) do
        local label = string.format("Monitor %d: %dx%d @ %d,%d%s",
            i, m.w, m.h, m.x, m.y, m.primary and " (principal)" or "")
        obs.obs_property_list_add_string(p, label, string.format("mon:%d,%d,%d,%d", m.x, m.y, m.w, m.h))
    end
    obs.obs_property_list_add_string(p, "Manual (definir a área abaixo)", "manual")
end

local function add_modifier_list(props, key, label, allow_none_warning)
    local p = obs.obs_properties_add_list(props, key, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p, allow_none_warning and "Nenhuma (qualquer rolagem dá zoom)" or "Nenhuma", "none")
    obs.obs_property_list_add_string(p, "Shift", "shift")
    obs.obs_property_list_add_string(p, "Ctrl", "ctrl")
    obs.obs_property_list_add_string(p, "Alt", "alt")
    obs.obs_property_list_add_string(p, "Ctrl + Shift", "ctrl+shift")
    obs.obs_property_list_add_string(p, "Ctrl + Alt", "ctrl+alt")
    obs.obs_property_list_add_string(p, "Shift + Alt", "shift+alt")
    return p
end

local function add_button_list(props, key, label)
    local p = obs.obs_properties_add_list(props, key, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p, "Nenhum", "none")
    obs.obs_property_list_add_string(p, "Botão do meio (clique da rodinha)", "middle")
    obs.obs_property_list_add_string(p, "Botão lateral 1 (voltar)", "x1")
    obs.obs_property_list_add_string(p, "Botão lateral 2 (avançar)", "x2")
    return p
end

-- Campos do grupo de cursor e os estilos em que aparecem.
local CURSOR_STYLE_FIELDS = {
    cursor_size        = { arrow = true, dot = true },
    arrow_fill         = { arrow = true },
    arrow_outline      = { arrow = true },
    dot_color          = { dot = true },
    cursor_image       = { image = true },
    cursor_image_scale = { image = true },
    cursor_hotspot_x   = { image = true },
    cursor_hotspot_y   = { image = true },
    cursor_hide_idle   = { arrow = true, image = true, dot = true },
}

local function on_cursor_options_modified(props, prop, settings)
    local style = obs.obs_data_get_string(settings, "cursor_style")
    for key, styles in pairs(CURSOR_STYLE_FIELDS) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then obs.obs_property_set_visible(p, styles[style] == true) end
    end
    local halo = obs.obs_data_get_bool(settings, "halo_enabled")
    for _, key in ipairs({ "halo_color", "halo_size" }) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then obs.obs_property_set_visible(p, halo) end
    end
    local click = obs.obs_data_get_bool(settings, "click_enabled")
    for _, key in ipairs({ "click_left_color", "click_right_color", "click_size", "click_duration_ms" }) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then obs.obs_property_set_visible(p, click) end
    end
    return true
end

local MANUAL_KEYS = { "manual_x", "manual_y", "manual_w", "manual_h" }

local function on_monitor_mode_modified(props, prop, settings)
    local manual = obs.obs_data_get_string(settings, "monitor_mode") == "manual"
    for _, k in ipairs(MANUAL_KEYS) do
        local p = obs.obs_properties_get(props, k)
        if p ~= nil then obs.obs_property_set_visible(p, manual) end
    end
    return true
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Fonte
    local g = obs.obs_properties_create()
    local p_src = obs.obs_properties_add_list(g, "source_name", "Fonte ou cena para dar zoom",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_source_list(p_src)
    obs.obs_properties_add_button(g, "refresh_sources", "Atualizar lista de fontes", function(pp)
        fill_source_list(obs.obs_properties_get(pp, "source_name"))
        return true
    end)
    obs.obs_properties_add_group(props, "grp_source", "Fonte", obs.OBS_GROUP_NORMAL, g)

    -- Zoom
    g = obs.obs_properties_create()
    obs.obs_properties_add_float_slider(g, "zoom_factor", "Nível de zoom padrão (x)", 1.05, 10.0, 0.05)
    obs.obs_properties_add_float_slider(g, "zoom_step", "Passo dos atalhos de aumentar/diminuir (x)", 0.05, 3.0, 0.05)
    obs.obs_properties_add_float_slider(g, "zoom_min", "Zoom mínimo (x)", 1.05, 10.0, 0.05)
    obs.obs_properties_add_float_slider(g, "zoom_max", "Zoom máximo (x)", 1.05, 20.0, 0.05)
    obs.obs_properties_add_bool(g, "remember_level", "Lembrar o último nível de zoom usado")
    obs.obs_properties_add_int_slider(g, "duration_ms", "Duração da animação (ms, 0 = instantâneo)", 0, 3000, 10)
    local p_ease = obs.obs_properties_add_list(g, "easing", "Curva da animação",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_ease, "Linear", "linear")
    obs.obs_property_list_add_string(p_ease, "Suave (smoothstep)", "smooth")
    obs.obs_property_list_add_string(p_ease, "Acelera e desacelera (cúbica)", "cubic")
    obs.obs_property_list_add_string(p_ease, "Desacelera no fim (quadrática)", "quad_out")
    obs.obs_property_list_add_string(p_ease, "Desacelera forte (exponencial)", "expo_out")
    obs.obs_property_list_add_string(p_ease, "Com leve ultrapassagem (back)", "back_out")
    local p_origin = obs.obs_properties_add_list(g, "origin", "Origem do zoom",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_origin, "Cursor (o ponto sob o mouse fica parado)", "cursor_anchor")
    obs.obs_property_list_add_string(p_origin, "Cursor (centraliza no mouse)", "cursor_center")
    obs.obs_property_list_add_string(p_origin, "Centro da área visível", "center")
    local p_sampling = obs.obs_properties_add_list(g, "sampling", "Qualidade da ampliação",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_sampling, "Bilinear (mais leve)", "bilinear")
    obs.obs_property_list_add_string(p_sampling, "Bicúbico (recomendado)", "bicubic")
    obs.obs_property_list_add_string(p_sampling, "Lanczos (mais nítido)", "lanczos")
    obs.obs_property_list_add_string(p_sampling, "Pixels nítidos (ponto)", "point")
    obs.obs_properties_add_group(props, "grp_zoom", "Zoom", obs.OBS_GROUP_NORMAL, g)

    -- Seguir mouse
    g = obs.obs_properties_create()
    obs.obs_properties_add_bool(g, "follow_on_zoom", "Seguir o mouse automaticamente ao dar zoom")
    obs.obs_properties_add_float_slider(g, "follow_speed", "Velocidade de acompanhamento (50 = instantâneo)", 1, 50, 0.5)
    obs.obs_properties_add_int_slider(g, "dead_zone", "Zona morta (% central sem mover a câmera)", 0, 100, 1)
    obs.obs_properties_add_bool(g, "follow_outside", "Continuar seguindo quando o mouse sair da tela capturada")
    obs.obs_properties_add_float_slider(g, "idle_timeout", "Sair do zoom após mouse parado (s, 0 = nunca)", 0, 120, 0.5)
    obs.obs_properties_add_group(props, "grp_follow", "Seguir o mouse", obs.OBS_GROUP_NORMAL, g)

    -- Controles pelo mouse
    g = obs.obs_properties_create()
    obs.obs_properties_add_bool(g, "wheel_enabled", "Zoom com a rodinha do mouse")
    add_modifier_list(g, "wheel_mod", "Tecla para segurar junto com a rodinha", true)
    obs.obs_properties_add_float_slider(g, "wheel_step", "Zoom por clique da rodinha (x)", 0.05, 2.0, 0.05)
    obs.obs_properties_add_bool(g, "wheel_invert", "Inverter direção da rodinha")
    obs.obs_properties_add_int_slider(g, "wheel_duration_ms", "Duração da animação da rodinha (ms)", 0, 1000, 10)
    add_button_list(g, "btn_toggle", "Botão: ativar/desativar zoom")
    add_modifier_list(g, "btn_toggle_mod", "   Tecla junto com o botão")
    add_button_list(g, "btn_hold", "Botão: zoom enquanto segurar")
    add_modifier_list(g, "btn_hold_mod", "   Tecla junto com o botão")
    add_button_list(g, "btn_follow", "Botão: ativar/desativar seguir")
    add_modifier_list(g, "btn_follow_mod", "   Tecla junto com o botão")
    obs.obs_properties_add_group(props, "grp_mouse", "Controles pelo mouse", obs.OBS_GROUP_NORMAL, g)

    -- Cursor
    g = obs.obs_properties_create()
    local p_style = obs.obs_properties_add_list(g, "cursor_style", "Aparência do cursor",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_style, "Original (cursor capturado pelo OBS)", "original")
    obs.obs_property_list_add_string(p_style, "Seta (cores personalizadas)", "arrow")
    obs.obs_property_list_add_string(p_style, "Imagem personalizada (PNG, GIF...)", "image")
    obs.obs_property_list_add_string(p_style, "Ponto colorido", "dot")
    obs.obs_property_list_add_string(p_style, "Oculto", "hidden")
    obs.obs_property_set_modified_callback(p_style, on_cursor_options_modified)
    obs.obs_properties_add_int_slider(g, "cursor_size", "Tamanho do cursor (px)", 8, 200, 1)
    obs.obs_properties_add_color_alpha(g, "arrow_fill", "Cor da seta")
    obs.obs_properties_add_color_alpha(g, "arrow_outline", "Cor do contorno da seta")
    obs.obs_properties_add_color_alpha(g, "dot_color", "Cor do ponto")
    obs.obs_properties_add_path(g, "cursor_image", "Imagem do cursor", obs.OBS_PATH_FILE,
        "Imagens (*.png *.gif *.jpg *.jpeg *.bmp *.webp)", nil)
    obs.obs_properties_add_float_slider(g, "cursor_image_scale", "Escala da imagem", 0.1, 5.0, 0.05)
    obs.obs_properties_add_int(g, "cursor_hotspot_x", "Ponta do cursor na imagem: X (px)", 0, 1024, 1)
    obs.obs_properties_add_int(g, "cursor_hotspot_y", "Ponta do cursor na imagem: Y (px)", 0, 1024, 1)
    obs.obs_properties_add_float_slider(g, "cursor_hide_idle", "Esconder cursor após parado (s, 0 = nunca)", 0, 30, 0.5)
    obs.obs_properties_add_bool(g, "cursor_keep_size", "Manter o tamanho do cursor e dos efeitos durante o zoom")
    local p_halo = obs.obs_properties_add_bool(g, "halo_enabled", "Destaque (círculo em volta do cursor)")
    obs.obs_property_set_modified_callback(p_halo, on_cursor_options_modified)
    obs.obs_properties_add_color_alpha(g, "halo_color", "   Cor do destaque")
    obs.obs_properties_add_int_slider(g, "halo_size", "   Tamanho do destaque (px)", 10, 400, 1)
    local p_click = obs.obs_properties_add_bool(g, "click_enabled", "Efeito de clique")
    obs.obs_property_set_modified_callback(p_click, on_cursor_options_modified)
    obs.obs_properties_add_color_alpha(g, "click_left_color", "   Cor do clique esquerdo")
    obs.obs_properties_add_color_alpha(g, "click_right_color", "   Cor do clique direito")
    obs.obs_properties_add_int_slider(g, "click_size", "   Tamanho do efeito (px)", 10, 400, 1)
    obs.obs_properties_add_int_slider(g, "click_duration_ms", "   Duração do efeito (ms)", 100, 2000, 10)
    obs.obs_properties_add_group(props, "grp_cursor", "Cursor do mouse", obs.OBS_GROUP_NORMAL, g)

    -- Monitor
    g = obs.obs_properties_create()
    local p_mon = obs.obs_properties_add_list(g, "monitor_mode", "Tela capturada",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_monitor_list(p_mon)
    obs.obs_property_set_modified_callback(p_mon, on_monitor_mode_modified)
    obs.obs_properties_add_button(g, "refresh_monitors", "Detectar monitores novamente", function(pp)
        fill_monitor_list(obs.obs_properties_get(pp, "monitor_mode"))
        return true
    end)
    obs.obs_properties_add_int(g, "manual_x", "Área manual: X", -32768, 32768, 1)
    obs.obs_properties_add_int(g, "manual_y", "Área manual: Y", -32768, 32768, 1)
    obs.obs_properties_add_int(g, "manual_w", "Área manual: largura", 0, 32768, 1)
    obs.obs_properties_add_int(g, "manual_h", "Área manual: altura", 0, 32768, 1)
    obs.obs_properties_add_group(props, "grp_monitor", "Monitor", obs.OBS_GROUP_NORMAL, g)

    -- Atalhos e avançado
    g = obs.obs_properties_create()
    obs.obs_properties_add_button(g, "restore_hotkeys", "Restaurar atalhos de teclado padrão", function()
        restore_default_hotkeys()
        return false
    end)
    obs.obs_properties_add_button(g, "log_cursor", "Mostrar posição do mouse no log", function()
        local mx, my = get_cursor_pos()
        if mx == nil then
            log("Não foi possível ler a posição do mouse.")
        else
            log(string.format("Mouse na tela: %d, %d", mx, my))
        end
        return false
    end)
    obs.obs_properties_add_bool(g, "debug", "Registrar mensagens de depuração no log")
    obs.obs_properties_add_group(props, "grp_advanced", "Atalhos e avançado", obs.OBS_GROUP_NORMAL, g)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "source_name", "")
    obs.obs_data_set_default_double(settings, "zoom_factor", 2.0)
    obs.obs_data_set_default_double(settings, "zoom_step", 0.5)
    obs.obs_data_set_default_double(settings, "zoom_min", 1.25)
    obs.obs_data_set_default_double(settings, "zoom_max", 8.0)
    obs.obs_data_set_default_bool(settings, "remember_level", false)
    obs.obs_data_set_default_int(settings, "duration_ms", 350)
    obs.obs_data_set_default_string(settings, "easing", "cubic")
    obs.obs_data_set_default_string(settings, "origin", "cursor_anchor")
    obs.obs_data_set_default_string(settings, "sampling", "bicubic")
    obs.obs_data_set_default_bool(settings, "follow_on_zoom", true)
    obs.obs_data_set_default_double(settings, "follow_speed", 10)
    obs.obs_data_set_default_int(settings, "dead_zone", 40)
    obs.obs_data_set_default_bool(settings, "follow_outside", false)
    obs.obs_data_set_default_double(settings, "idle_timeout", 0)
    obs.obs_data_set_default_bool(settings, "wheel_enabled", true)
    obs.obs_data_set_default_string(settings, "wheel_mod", "shift")
    obs.obs_data_set_default_double(settings, "wheel_step", 0.25)
    obs.obs_data_set_default_bool(settings, "wheel_invert", false)
    obs.obs_data_set_default_int(settings, "wheel_duration_ms", 150)
    obs.obs_data_set_default_string(settings, "btn_toggle", "none")
    obs.obs_data_set_default_string(settings, "btn_toggle_mod", "none")
    obs.obs_data_set_default_string(settings, "btn_hold", "none")
    obs.obs_data_set_default_string(settings, "btn_hold_mod", "none")
    obs.obs_data_set_default_string(settings, "btn_follow", "none")
    obs.obs_data_set_default_string(settings, "btn_follow_mod", "none")
    obs.obs_data_set_default_string(settings, "monitor_mode", "auto")
    obs.obs_data_set_default_bool(settings, "debug", false)
    obs.obs_data_set_default_string(settings, "cursor_style", "original")
    obs.obs_data_set_default_int(settings, "cursor_size", 32)
    obs.obs_data_set_default_int(settings, "arrow_fill", 0xFFFFFFFF)
    obs.obs_data_set_default_int(settings, "arrow_outline", 0xFF000000)
    obs.obs_data_set_default_int(settings, "dot_color", 0xE63D3DFF)
    obs.obs_data_set_default_string(settings, "cursor_image", "")
    obs.obs_data_set_default_double(settings, "cursor_image_scale", 1.0)
    obs.obs_data_set_default_int(settings, "cursor_hotspot_x", 0)
    obs.obs_data_set_default_int(settings, "cursor_hotspot_y", 0)
    obs.obs_data_set_default_double(settings, "cursor_hide_idle", 0)
    obs.obs_data_set_default_bool(settings, "cursor_keep_size", false)
    obs.obs_data_set_default_bool(settings, "halo_enabled", false)
    obs.obs_data_set_default_int(settings, "halo_color", 0x6600D7FF)
    obs.obs_data_set_default_int(settings, "halo_size", 60)
    obs.obs_data_set_default_bool(settings, "click_enabled", false)
    obs.obs_data_set_default_int(settings, "click_left_color", 0xCCFF9B3D)
    obs.obs_data_set_default_int(settings, "click_right_color", 0xCC3D5BFF)
    obs.obs_data_set_default_int(settings, "click_size", 50)
    obs.obs_data_set_default_int(settings, "click_duration_ms", 400)
end

function script_update(settings)
    local new_source = obs.obs_data_get_string(settings, "source_name")
    if new_source ~= cfg.source_name then
        end_session()
        restore_capture_cursor()
        remove_all_filters()
        cur.target = nil
    end
    cfg.source_name = new_source

    cfg.zoom_factor = obs.obs_data_get_double(settings, "zoom_factor")
    cfg.zoom_step = obs.obs_data_get_double(settings, "zoom_step")
    cfg.zoom_min = obs.obs_data_get_double(settings, "zoom_min")
    cfg.zoom_max = obs.obs_data_get_double(settings, "zoom_max")
    if cfg.zoom_min > cfg.zoom_max then cfg.zoom_min, cfg.zoom_max = cfg.zoom_max, cfg.zoom_min end
    cfg.remember_level = obs.obs_data_get_bool(settings, "remember_level")
    cfg.duration = obs.obs_data_get_int(settings, "duration_ms") / 1000
    cfg.easing = obs.obs_data_get_string(settings, "easing")
    cfg.origin = obs.obs_data_get_string(settings, "origin")
    cfg.sampling = obs.obs_data_get_string(settings, "sampling")
    cfg.follow_on_zoom = obs.obs_data_get_bool(settings, "follow_on_zoom")
    cfg.follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    cfg.dead_zone = obs.obs_data_get_int(settings, "dead_zone") / 100
    cfg.follow_outside = obs.obs_data_get_bool(settings, "follow_outside")
    cfg.idle_timeout = obs.obs_data_get_double(settings, "idle_timeout")
    cfg.wheel_enabled = obs.obs_data_get_bool(settings, "wheel_enabled")
    cfg.wheel_mod = obs.obs_data_get_string(settings, "wheel_mod")
    cfg.wheel_step = obs.obs_data_get_double(settings, "wheel_step")
    cfg.wheel_invert = obs.obs_data_get_bool(settings, "wheel_invert")
    cfg.wheel_duration = obs.obs_data_get_int(settings, "wheel_duration_ms") / 1000
    cfg.btn_toggle = obs.obs_data_get_string(settings, "btn_toggle")
    cfg.btn_toggle_mod = obs.obs_data_get_string(settings, "btn_toggle_mod")
    cfg.btn_hold = obs.obs_data_get_string(settings, "btn_hold")
    cfg.btn_hold_mod = obs.obs_data_get_string(settings, "btn_hold_mod")
    cfg.btn_follow = obs.obs_data_get_string(settings, "btn_follow")
    cfg.btn_follow_mod = obs.obs_data_get_string(settings, "btn_follow_mod")
    cfg.monitor_mode = obs.obs_data_get_string(settings, "monitor_mode")
    cfg.manual.x = obs.obs_data_get_int(settings, "manual_x")
    cfg.manual.y = obs.obs_data_get_int(settings, "manual_y")
    cfg.manual.w = obs.obs_data_get_int(settings, "manual_w")
    cfg.manual.h = obs.obs_data_get_int(settings, "manual_h")
    cfg.debug = obs.obs_data_get_bool(settings, "debug")

    cfg.cursor_style = obs.obs_data_get_string(settings, "cursor_style")
    cfg.cursor_size = obs.obs_data_get_int(settings, "cursor_size")
    cfg.arrow_fill = obs.obs_data_get_int(settings, "arrow_fill")
    cfg.arrow_outline = obs.obs_data_get_int(settings, "arrow_outline")
    cfg.dot_color = obs.obs_data_get_int(settings, "dot_color")
    cfg.cursor_image = obs.obs_data_get_string(settings, "cursor_image")
    cfg.cursor_image_scale = obs.obs_data_get_double(settings, "cursor_image_scale")
    cfg.cursor_hotspot_x = obs.obs_data_get_int(settings, "cursor_hotspot_x")
    cfg.cursor_hotspot_y = obs.obs_data_get_int(settings, "cursor_hotspot_y")
    cfg.cursor_hide_idle = obs.obs_data_get_double(settings, "cursor_hide_idle")
    cfg.cursor_keep_size = obs.obs_data_get_bool(settings, "cursor_keep_size")
    cfg.halo_enabled = obs.obs_data_get_bool(settings, "halo_enabled")
    cfg.halo_color = obs.obs_data_get_int(settings, "halo_color")
    cfg.halo_size = obs.obs_data_get_int(settings, "halo_size")
    cfg.click_enabled = obs.obs_data_get_bool(settings, "click_enabled")
    cfg.click_left_color = obs.obs_data_get_int(settings, "click_left_color")
    cfg.click_right_color = obs.obs_data_get_int(settings, "click_right_color")
    cfg.click_size = obs.obs_data_get_int(settings, "click_size")
    cfg.click_duration = obs.obs_data_get_int(settings, "click_duration_ms") / 1000
    if cfg.cursor_style == "image" and cfg.cursor_image == "" then
        warn("Estilo 'Imagem personalizada' sem imagem escolhida; usando a seta.")
    end
    sync_cursor_image()
    cur.mon_dirty = true
    cur.sync_timer = 1e9

    if not (cfg.remember_level and st.zoomed) then st.level = clamp_level(cfg.zoom_factor) end

    if st.source ~= nil then
        st.mon = resolve_monitor(st.source, st.w, st.h)
        update_scale_filter()
        if st.zoomed and st.anim == nil then
            st.level = clamp_level(st.level)
            if math.abs(st.level - st.zoom) > 1e-6 then animate_to(st.level) end
        end
    end
end

---------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------

function script_tick(dt)
    if not IS_WINDOWS then return end
    process_mouse_input()
    cursor_tick(dt)
    if st.source == nil then return end
    local reg = st.region

    local sx, sy, inside, mx, my = cursor_source()
    if mx ~= nil then
        if mx ~= st.last_mx or my ~= st.last_my then
            st.idle = 0
            st.last_mx, st.last_my = mx, my
        else
            st.idle = st.idle + dt
        end
    end

    if st.anim ~= nil then
        step_animation(dt)
        if st.source == nil then return end
    else
        local vw, vh = reg.w / st.zoom, reg.h / st.zoom

        if st.following and sx ~= nil and (inside or cfg.follow_outside) then
            local hw, hh = vw * cfg.dead_zone / 2, vh * cfg.dead_zone / 2
            if sx > st.tx + hw then st.tx = sx - hw elseif sx < st.tx - hw then st.tx = sx + hw end
            if sy > st.ty + hh then st.ty = sy - hh elseif sy < st.ty - hh then st.ty = sy + hh end
        end
        st.tx = clamp(st.tx, reg.x + vw / 2, reg.x + reg.w - vw / 2)
        st.ty = clamp(st.ty, reg.y + vh / 2, reg.y + reg.h - vh / 2)

        if cfg.follow_speed >= 50 then
            st.cx, st.cy = st.tx, st.ty
        else
            local k = 1 - math.exp(-cfg.follow_speed * dt)
            st.cx = st.cx + (st.tx - st.cx) * k
            st.cy = st.cy + (st.ty - st.cy) * k
        end

        if st.zoomed and cfg.idle_timeout > 0 and st.idle >= cfg.idle_timeout then
            zoom_out()
        end
    end

    apply_transform()
end

local function shutdown()
    end_session()
    shutdown_cursor()
    remove_all_filters()
end

local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING
        or event == obs.OBS_FRONTEND_EVENT_EXIT
        or event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        shutdown()
    elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING
        or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
        -- Remove filtros que tenham ficado de uma sessão interrompida.
        if st.source == nil then
            remove_all_filters()
            cur.target = nil
            cur.mon_dirty = true
            cur.sync_timer = 1e9
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        cur.sync_timer = 1e9 -- no modo automático a fonte pode ter mudado
    end
end

function script_load(settings)
    local initialized = obs.obs_data_get_bool(settings, "hotkeys_initialized")
    for _, hk in ipairs(HOTKEYS) do
        hk.handle = obs.obs_hotkey_register_frontend("mouse_zoom_follow." .. hk.id, hk.desc, hk.cb)
        local arr
        if initialized then
            arr = obs.obs_data_get_array(settings, "hotkey_" .. hk.id)
            if arr == nil then arr = obs.obs_data_array_create() end
        else
            arr = make_binding(hk.default)
        end
        obs.obs_hotkey_load(hk.handle, arr)
        obs.obs_data_array_release(arr)
    end
    obs.obs_frontend_add_event_callback(on_frontend_event)
    obs.obs_register_source(cursor_filter_info)
    log("Mouse Zoom & Follow " .. SCRIPT_VERSION .. " carregado.")
    if not IS_WINDOWS then warn("Mouse Zoom & Follow: apenas Windows é suportado no momento.") end
end

function script_save(settings)
    for _, hk in ipairs(HOTKEYS) do
        local arr = obs.obs_hotkey_save(hk.handle)
        obs.obs_data_set_array(settings, "hotkey_" .. hk.id, arr)
        obs.obs_data_array_release(arr)
    end
    obs.obs_data_set_bool(settings, "hotkeys_initialized", true)
end

function script_unload()
    shutdown()
    raw_stop()
    if cur.image ~= nil then
        obs.obs_source_dec_showing(cur.image)
        obs.obs_source_release(cur.image)
        cur.image = nil
    end
    if cur.effect ~= nil then
        obs.obs_enter_graphics()
        obs.gs_effect_destroy(cur.effect)
        obs.obs_leave_graphics()
        cur.effect = nil
    end
end

function script_description()
    return [[
<h2>Mouse Zoom &amp; Follow ]] .. SCRIPT_VERSION .. [[</h2>
<p>Feito por <b>Pablo Ruan</b> — <a href="https://github.com/pabloruancoder/mouse-zoom-follow">github.com/pabloruancoder/mouse-zoom-follow</a></p>
<p>Dá zoom na fonte ou cena escolhida em volta do cursor e faz a imagem seguir o mouse.
Funciona em qualquer cena onde a fonte aparecer.</p>
<p><b>Mouse:</b> <b>Shift + rodinha</b> aumenta/diminui o zoom (configurável abaixo).</p>
<p><b>Cursor:</b> troque a aparência do cursor, adicione destaque e efeito de clique no grupo "Cursor do mouse".</p>
<p><b>Teclado</b> (mude em Configurações &gt; Teclas de atalho):</p>
<ul>
<li><b>Ctrl+Alt+Z</b> — ativar/desativar zoom</li>
<li><b>Ctrl+Alt+X</b> — zoom enquanto segurar</li>
<li><b>Ctrl+Alt+F</b> — ativar/desativar seguir o mouse</li>
<li><b>Ctrl+Alt+↑ / ↓</b> — aumentar / diminuir zoom</li>
<li><b>Ctrl+Alt+0</b> — voltar ao nível de zoom padrão</li>
<li><b>Ctrl+Alt+C</b> — centralizar no mouse</li>
</ul>
]]
end
