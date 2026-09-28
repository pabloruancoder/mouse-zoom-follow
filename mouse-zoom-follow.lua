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

local SCRIPT_VERSION = "1.4.0"
local IS_WINDOWS = (ffi.os == "Windows")

local CROP_FILTER_NAME = "Mouse Zoom (crop)"
local SCALE_FILTER_NAME = "Mouse Zoom (scale)"
local CURSOR_FILTER_NAME = "Mouse Zoom (cursor)"
local CURSOR_FILTER_ID = "mouse_zoom_follow_cursor"
-- Nomes usados até a versão 1.3.1; removidos na limpeza.
local LEGACY_FILTER_NAMES = { "Mouse Zoom (recorte)", "Mouse Zoom (escala)" }

---------------------------------------------------------------------------
-- Idiomas (Português do Brasil e Inglês)
---------------------------------------------------------------------------

local STRINGS = {
    -- Mensagens do log
    loaded             = { pt = "Mouse Zoom & Follow %s carregado.", en = "Mouse Zoom & Follow %s loaded." },
    windows_only       = { pt = "Este script suporta apenas Windows no momento.",
                           en = "This script currently supports Windows only." },
    raw_fail           = { pt = "Não foi possível ativar a leitura da rodinha/botões do mouse.",
                           en = "Could not enable mouse wheel/button input." },
    manual_invalid     = { pt = "Área manual inválida (largura/altura 0); usando detecção automática.",
                           en = "Invalid manual area (width/height 0); using automatic detection." },
    source_missing     = { pt = "A fonte '%s' não existe; usando a Captura de Tela da cena atual. Escolha a fonte certa em Ferramentas > Scripts.",
                           en = "Source '%s' does not exist; using the Display Capture in the current scene. Pick the right source in Tools > Scripts." },
    no_capture         = { pt = "Nenhuma Captura de Tela encontrada. Adicione uma à cena ou escolha a fonte em Ferramentas > Scripts.",
                           en = "No Display Capture found. Add one to the scene or pick the source in Tools > Scripts." },
    source_empty       = { pt = "A fonte '%s' está sem imagem (tamanho 0).", en = "Source '%s' has no image (size 0)." },
    filters_fail       = { pt = "Não foi possível criar os filtros de zoom na fonte '%s'.",
                           en = "Could not create the zoom filters on source '%s'." },
    session_start      = { pt = "Sessão iniciada: fonte '%s' %dx%d, monitor %dx%d @ %d,%d",
                           en = "Session started: source '%s' %dx%d, monitor %dx%d @ %d,%d" },
    session_end        = { pt = "Sessão encerrada.", en = "Session ended." },
    zoom_level         = { pt = "Zoom %.2fx", en = "Zoom %.2fx" },
    zooming_out        = { pt = "Saindo do zoom", en = "Zooming out" },
    follow_state       = { pt = "Seguir mouse: %s", en = "Mouse follow: %s" },
    state_on           = { pt = "ativado", en = "on" },
    state_off          = { pt = "desativado", en = "off" },
    render_info        = { pt = "Desenhando cursor: fonte %dx%d, monitor %dx%d @ %d,%d",
                           en = "Drawing cursor: source %dx%d, monitor %dx%d @ %d,%d" },
    effect_fail        = { pt = "Não foi possível criar o efeito de desenho do cursor.",
                           en = "Could not create the cursor drawing effect." },
    cursor_shown       = { pt = "Cursor real reexibido em '%s'.", en = "Real cursor shown again on '%s'." },
    cursor_hidden      = { pt = "Cursor real ocultado em '%s'.", en = "Real cursor hidden on '%s'." },
    cursor_filter_added = { pt = "Filtro de cursor adicionado em '%s'.", en = "Cursor filter added to '%s'." },
    image_missing      = { pt = "Estilo 'Imagem personalizada' sem imagem escolhida; usando a seta.",
                           en = "'Custom image' style without an image selected; using the arrow." },
    hotkeys_restored   = { pt = "Atalhos padrão restaurados. Reabra Configurações > Teclas de atalho para vê-los.",
                           en = "Default hotkeys restored. Reopen Settings > Hotkeys to see them." },
    cursor_read_fail   = { pt = "Não foi possível ler a posição do mouse.", en = "Could not read the mouse position." },
    cursor_pos         = { pt = "Mouse na tela: %d, %d", en = "Mouse on screen: %d, %d" },
    lang_reload        = { pt = "Idioma alterado. Recarregue o script (↻) para traduzir também os nomes dos atalhos e a descrição.",
                           en = "Language changed. Reload the script (↻) to also translate the hotkey names and the description." },
    filter_type_name   = { pt = "Mouse Zoom: cursor personalizado", en = "Mouse Zoom: custom cursor" },

    -- Descrição
    d_by               = { pt = "Feito por", en = "Made by" },
    d_intro            = { pt = "Dá zoom na fonte ou cena escolhida em volta do cursor e faz a imagem seguir o mouse. Funciona em qualquer cena onde a fonte aparecer.",
                           en = "Zooms the chosen source or scene around the cursor and makes the view follow the mouse. Works in any scene where the source appears." },
    d_mouse            = { pt = "<b>Mouse:</b> <b>Shift + rodinha</b> aumenta/diminui o zoom (configurável abaixo).",
                           en = "<b>Mouse:</b> <b>Shift + mouse wheel</b> zooms in/out (configurable below)." },
    d_cursor           = { pt = "<b>Cursor:</b> troque a aparência do cursor, adicione destaque e efeito de clique no grupo \"Cursor do mouse\".",
                           en = "<b>Cursor:</b> change the cursor appearance and add highlight and click effects in the \"Mouse cursor\" group." },
    d_keyboard         = { pt = "<b>Teclado</b> (mude em Configurações &gt; Teclas de atalho):",
                           en = "<b>Keyboard</b> (change in Settings &gt; Hotkeys):" },
    d_k_toggle         = { pt = "ativar/desativar zoom", en = "toggle zoom" },
    d_k_hold           = { pt = "zoom enquanto segurar", en = "zoom while held" },
    d_k_follow         = { pt = "ativar/desativar seguir o mouse", en = "toggle mouse follow" },
    d_k_inout          = { pt = "aumentar / diminuir zoom", en = "zoom in / out" },
    d_k_reset          = { pt = "voltar ao nível de zoom padrão", en = "reset to default zoom level" },
    d_k_center         = { pt = "centralizar no mouse", en = "center on mouse" },
    d_lang             = { pt = "escolha no topo das configurações abaixo.", en = "choose it at the top of the settings below." },

    -- Atalhos
    hk_toggle_zoom     = { pt = "Mouse Zoom: Ativar/desativar zoom", en = "Mouse Zoom: Toggle zoom" },
    hk_hold_zoom       = { pt = "Mouse Zoom: Zoom enquanto segurar", en = "Mouse Zoom: Zoom while held" },
    hk_toggle_follow   = { pt = "Mouse Zoom: Ativar/desativar seguir o mouse", en = "Mouse Zoom: Toggle mouse follow" },
    hk_zoom_more       = { pt = "Mouse Zoom: Aumentar zoom", en = "Mouse Zoom: Zoom in" },
    hk_zoom_less       = { pt = "Mouse Zoom: Diminuir zoom", en = "Mouse Zoom: Zoom out" },
    hk_reset_level     = { pt = "Mouse Zoom: Voltar ao nível de zoom padrão", en = "Mouse Zoom: Reset to default zoom level" },
    hk_recenter        = { pt = "Mouse Zoom: Centralizar no mouse", en = "Mouse Zoom: Center on mouse" },

    -- Idioma
    lang_auto          = { pt = "Automático (idioma do OBS)", en = "Automatic (OBS language)" },
    lang_pt            = { pt = "Português (Brasil)", en = "Português (Brasil)" },
    lang_en            = { pt = "English", en = "English" },

    -- Fonte
    g_source           = { pt = "Fonte", en = "Source" },
    p_source           = { pt = "Fonte ou cena para dar zoom", en = "Source or scene to zoom" },
    b_refresh_sources  = { pt = "Atualizar lista de fontes", en = "Refresh source list" },
    src_auto           = { pt = "Automático (Captura de Tela visível na cena atual)",
                           en = "Automatic (visible Display Capture in the current scene)" },
    src_capture_suffix = { pt = "  (Captura de Tela)", en = "  (Display Capture)" },
    src_scene_suffix   = { pt = "  (Cena inteira)", en = "  (Whole scene)" },

    -- Zoom
    g_zoom             = { pt = "Zoom", en = "Zoom" },
    p_zoom_factor      = { pt = "Nível de zoom padrão (x)", en = "Default zoom level (x)" },
    p_zoom_step        = { pt = "Passo dos atalhos de aumentar/diminuir (x)", en = "Zoom in/out hotkey step (x)" },
    p_zoom_min         = { pt = "Zoom mínimo (x)", en = "Minimum zoom (x)" },
    p_zoom_max         = { pt = "Zoom máximo (x)", en = "Maximum zoom (x)" },
    p_remember         = { pt = "Lembrar o último nível de zoom usado", en = "Remember the last zoom level used" },
    p_duration         = { pt = "Duração da animação (ms, 0 = instantâneo)", en = "Animation duration (ms, 0 = instant)" },
    p_easing           = { pt = "Curva da animação", en = "Animation curve" },
    ease_linear        = { pt = "Linear", en = "Linear" },
    ease_smooth        = { pt = "Suave (smoothstep)", en = "Smooth (smoothstep)" },
    ease_cubic         = { pt = "Acelera e desacelera (cúbica)", en = "Ease in and out (cubic)" },
    ease_quad_out      = { pt = "Desacelera no fim (quadrática)", en = "Ease out (quadratic)" },
    ease_expo_out      = { pt = "Desacelera forte (exponencial)", en = "Strong ease out (exponential)" },
    ease_back_out      = { pt = "Com leve ultrapassagem (back)", en = "Slight overshoot (back)" },
    p_origin           = { pt = "Origem do zoom", en = "Zoom origin" },
    origin_anchor      = { pt = "Cursor (o ponto sob o mouse fica parado)", en = "Cursor (point under the mouse stays still)" },
    origin_cursor_center = { pt = "Cursor (centraliza no mouse)", en = "Cursor (center on the mouse)" },
    origin_center      = { pt = "Centro da área visível", en = "Center of the visible area" },
    p_sampling         = { pt = "Qualidade da ampliação", en = "Scaling quality" },
    s_bilinear         = { pt = "Bilinear (mais leve)", en = "Bilinear (lightest)" },
    s_bicubic          = { pt = "Bicúbico (recomendado)", en = "Bicubic (recommended)" },
    s_lanczos          = { pt = "Lanczos (mais nítido)", en = "Lanczos (sharpest)" },
    s_point            = { pt = "Pixels nítidos (ponto)", en = "Sharp pixels (point)" },

    -- Seguir o mouse
    g_follow           = { pt = "Seguir o mouse", en = "Mouse follow" },
    p_follow_on_zoom   = { pt = "Seguir o mouse automaticamente ao dar zoom", en = "Follow the mouse automatically when zooming" },
    p_follow_speed     = { pt = "Velocidade de acompanhamento (50 = instantâneo)", en = "Follow speed (50 = instant)" },
    p_dead_zone        = { pt = "Zona morta (% central sem mover a câmera)", en = "Dead zone (central % where the view stays still)" },
    p_follow_outside   = { pt = "Continuar seguindo quando o mouse sair da tela capturada",
                           en = "Keep following when the mouse leaves the captured screen" },
    p_idle_timeout     = { pt = "Sair do zoom após mouse parado (s, 0 = nunca)", en = "Zoom out after the mouse is idle (s, 0 = never)" },

    -- Controles pelo mouse
    g_mouse            = { pt = "Controles pelo mouse", en = "Mouse controls" },
    p_wheel_enabled    = { pt = "Zoom com a rodinha do mouse", en = "Zoom with the mouse wheel" },
    p_wheel_mod        = { pt = "Tecla para segurar junto com a rodinha", en = "Key to hold with the wheel" },
    p_wheel_step       = { pt = "Zoom por clique da rodinha (x)", en = "Zoom per wheel notch (x)" },
    p_wheel_invert     = { pt = "Inverter direção da rodinha", en = "Invert wheel direction" },
    p_wheel_duration   = { pt = "Duração da animação da rodinha (ms)", en = "Wheel animation duration (ms)" },
    p_btn_toggle       = { pt = "Botão: ativar/desativar zoom", en = "Button: toggle zoom" },
    p_btn_hold         = { pt = "Botão: zoom enquanto segurar", en = "Button: zoom while held" },
    p_btn_follow       = { pt = "Botão: ativar/desativar seguir", en = "Button: toggle follow" },
    p_btn_mod          = { pt = "   Tecla junto com o botão", en = "   Key held with the button" },
    mod_none           = { pt = "Nenhuma", en = "None" },
    mod_none_wheel     = { pt = "Nenhuma (qualquer rolagem dá zoom)", en = "None (any scroll zooms)" },
    btn_none           = { pt = "Nenhum", en = "None" },
    btn_middle         = { pt = "Botão do meio (clique da rodinha)", en = "Middle button (wheel click)" },
    btn_x1             = { pt = "Botão lateral 1 (voltar)", en = "Side button 1 (back)" },
    btn_x2             = { pt = "Botão lateral 2 (avançar)", en = "Side button 2 (forward)" },

    -- Cursor
    g_cursor           = { pt = "Cursor do mouse", en = "Mouse cursor" },
    p_cursor_style     = { pt = "Aparência do cursor", en = "Cursor appearance" },
    style_original     = { pt = "Original (cursor capturado pelo OBS)", en = "Original (cursor captured by OBS)" },
    style_arrow        = { pt = "Seta (cores personalizadas)", en = "Arrow (custom colors)" },
    style_image        = { pt = "Imagem personalizada (PNG, GIF...)", en = "Custom image (PNG, GIF...)" },
    style_dot          = { pt = "Ponto colorido", en = "Colored dot" },
    style_hidden       = { pt = "Oculto", en = "Hidden" },
    p_cursor_size      = { pt = "Tamanho do cursor (px)", en = "Cursor size (px)" },
    p_arrow_fill       = { pt = "Cor da seta", en = "Arrow color" },
    p_arrow_outline    = { pt = "Cor do contorno da seta", en = "Arrow outline color" },
    p_dot_color        = { pt = "Cor do ponto", en = "Dot color" },
    p_cursor_image     = { pt = "Imagem do cursor", en = "Cursor image" },
    image_filter       = { pt = "Imagens (*.png *.gif *.jpg *.jpeg *.bmp *.webp)",
                           en = "Images (*.png *.gif *.jpg *.jpeg *.bmp *.webp)" },
    p_image_scale      = { pt = "Escala da imagem", en = "Image scale" },
    p_hotspot_x        = { pt = "Ponta do cursor na imagem: X (px)", en = "Cursor tip in the image: X (px)" },
    p_hotspot_y        = { pt = "Ponta do cursor na imagem: Y (px)", en = "Cursor tip in the image: Y (px)" },
    p_hide_idle        = { pt = "Esconder cursor após parado (s, 0 = nunca)", en = "Hide cursor when idle (s, 0 = never)" },
    p_keep_size        = { pt = "Manter o tamanho do cursor e dos efeitos durante o zoom",
                           en = "Keep cursor and effect size while zoomed" },
    p_halo             = { pt = "Destaque (círculo em volta do cursor)", en = "Highlight (circle around the cursor)" },
    p_halo_color       = { pt = "   Cor do destaque", en = "   Highlight color" },
    p_halo_size        = { pt = "   Tamanho do destaque (px)", en = "   Highlight size (px)" },
    p_click            = { pt = "Efeito de clique", en = "Click effect" },
    p_click_left       = { pt = "   Cor do clique esquerdo", en = "   Left click color" },
    p_click_right      = { pt = "   Cor do clique direito", en = "   Right click color" },
    p_click_size       = { pt = "   Tamanho do efeito (px)", en = "   Effect size (px)" },
    p_click_duration   = { pt = "   Duração do efeito (ms)", en = "   Effect duration (ms)" },

    -- Monitor
    g_monitor          = { pt = "Monitor", en = "Monitor" },
    p_monitor_mode     = { pt = "Tela capturada", en = "Captured screen" },
    b_refresh_monitors = { pt = "Detectar monitores novamente", en = "Detect monitors again" },
    mon_auto           = { pt = "Automático (usa o monitor da Captura de Tela)", en = "Automatic (uses the Display Capture's monitor)" },
    mon_primary        = { pt = " (principal)", en = " (primary)" },
    mon_manual         = { pt = "Manual (definir a área abaixo)", en = "Manual (set the area below)" },
    p_manual_x         = { pt = "Área manual: X", en = "Manual area: X" },
    p_manual_y         = { pt = "Área manual: Y", en = "Manual area: Y" },
    p_manual_w         = { pt = "Área manual: largura", en = "Manual area: width" },
    p_manual_h         = { pt = "Área manual: altura", en = "Manual area: height" },

    -- Atalhos e avançado
    g_advanced         = { pt = "Atalhos e avançado", en = "Hotkeys and advanced" },
    b_restore_hotkeys  = { pt = "Restaurar atalhos de teclado padrão", en = "Restore default keyboard hotkeys" },
    b_log_cursor       = { pt = "Mostrar posição do mouse no log", en = "Show mouse position in the log" },
    p_debug            = { pt = "Registrar mensagens de depuração no log", en = "Write debug messages to the log" },
}

-- "auto" segue o idioma da interface do OBS: português para pt-*, inglês para o resto.
local function resolve_lang(choice)
    if choice == "pt" or choice == "en" then return choice end
    local locale = obs.obs_get_locale() or ""
    return locale:lower():sub(1, 2) == "pt" and "pt" or "en"
end

local LANG = resolve_lang("auto")

-- Texto traduzido; argumentos extras são aplicados com string.format.
local function T(id, ...)
    local entry = STRINGS[id]
    local text = entry and (entry[LANG] or entry.pt) or id
    if select("#", ...) > 0 then return string.format(text, ...) end
    return text
end

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
        obs.script_log(obs.LOG_WARNING, T("raw_fail"))
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
        warn(T("manual_invalid"))
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
local ALL_FILTERS = { CURSOR_FILTER_NAME, CROP_FILTER_NAME, SCALE_FILTER_NAME,
    LEGACY_FILTER_NAMES[1], LEGACY_FILTER_NAMES[2] }

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
            warn(T("source_missing", cfg.source_name))
        end
    end
    local name = find_auto_capture()
    if name == nil then return nil end
    return obs.obs_get_source_by_name(name), name
end

local function begin_session()
    if st.source ~= nil then return true end
    if not IS_WINDOWS then
        warn(T("windows_only"))
        return false
    end

    local source, name = resolve_source()
    if source == nil then
        warn(T("no_capture"))
        return false
    end

    -- Filtros desativados deixam a imagem passar direto: mede o tamanho sem zoom.
    set_filters_enabled(source, false)
    local w = obs.obs_source_get_width(source)
    local h = obs.obs_source_get_height(source)
    if w == 0 or h == 0 then
        warn(T("source_empty", name))
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
        warn(T("filters_fail", name))
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

    dbg(T("session_start", name, w, h, st.mon.w, st.mon.h, st.mon.x, st.mon.y))
    return true
end

local function end_session()
    if st.source ~= nil then
        obs.obs_source_set_enabled(st.crop, false)
        obs.obs_source_set_enabled(st.scale, false)
        obs.obs_source_release(st.crop)
        obs.obs_source_release(st.scale)
        obs.obs_source_release(st.source)
        dbg(T("session_end"))
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
    dbg(T("zoom_level", st.level))
    animate_to(st.level, duration)
end

local function zoom_out(duration)
    if st.source == nil then return end
    st.zoomed = false
    dbg(T("zooming_out"))
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
    dbg(T("zoom_level", st.level))
    animate_to(st.level, duration)
end

local function toggle_zoom()
    if st.zoomed then zoom_out() else zoom_in() end
end

local function toggle_follow()
    st.following = not st.following
    log(T("follow_state", T(st.following and "state_on" or "state_off")))
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
        dbg(T("render_info", w, h, m.w, m.h, m.x, m.y))
    end
    local mx, my = get_cursor_pos()
    if mx == nil then return end

    if cur.effect == nil and not cur.effect_failed then
        cur.effect = obs.gs_effect_create(CIRCLE_EFFECT, "mouse_zoom_circle.effect", nil)
        if cur.effect == nil then
            cur.effect_failed = true
            warn(T("effect_fail"))
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
    get_name = function() return T("filter_type_name") end,
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
        dbg(T("cursor_shown", cur.hidden))
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
                dbg(T("cursor_filter_added", name))
            end
        end
    end

    if want_hidden ~= cur.hidden then
        restore_capture_cursor()
        if want_hidden ~= nil then
            set_capture_cursor(want_hidden, false)
            cur.hidden = want_hidden
            dbg(T("cursor_hidden", want_hidden))
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
    { id = "toggle_zoom",   desc = "hk_toggle_zoom",
      default = { key = "OBS_KEY_Z", ctrl = true, alt = true },
      cb = function(pressed) if pressed then toggle_zoom() end end },
    { id = "hold_zoom",     desc = "hk_hold_zoom",
      default = { key = "OBS_KEY_X", ctrl = true, alt = true },
      cb = function(pressed) if pressed then zoom_in() else zoom_out() end end },
    { id = "toggle_follow", desc = "hk_toggle_follow",
      default = { key = "OBS_KEY_F", ctrl = true, alt = true },
      cb = function(pressed) if pressed then toggle_follow() end end },
    { id = "zoom_more",     desc = "hk_zoom_more",
      default = { key = "OBS_KEY_UP", ctrl = true, alt = true },
      cb = function(pressed) if pressed then change_level(cfg.zoom_step) end end },
    { id = "zoom_less",     desc = "hk_zoom_less",
      default = { key = "OBS_KEY_DOWN", ctrl = true, alt = true },
      cb = function(pressed) if pressed then change_level(-cfg.zoom_step) end end },
    { id = "reset_level",   desc = "hk_reset_level",
      default = { key = "OBS_KEY_0", ctrl = true, alt = true },
      cb = function(pressed)
          if not pressed then return end
          st.level = clamp_level(cfg.zoom_factor)
          if st.zoomed then animate_to(st.level) end
      end },
    { id = "recenter",      desc = "hk_recenter",
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
    log(T("hotkeys_restored"))
end

---------------------------------------------------------------------------
-- Propriedades (interface em Ferramentas > Scripts)
---------------------------------------------------------------------------

-- Chave da propriedade -> id do texto. Preenchida ao criar a interface e usada
-- para retraduzir os rótulos quando o idioma muda.
local PROP_TEXT = {}
local function L(key, id)
    PROP_TEXT[key] = id
    return T(id)
end

-- Listas com itens fixos: { valor, id do texto }.
local STATIC_LISTS = {
    language = { { "auto", "lang_auto" }, { "pt", "lang_pt" }, { "en", "lang_en" } },
    easing = {
        { "linear", "ease_linear" }, { "smooth", "ease_smooth" }, { "cubic", "ease_cubic" },
        { "quad_out", "ease_quad_out" }, { "expo_out", "ease_expo_out" }, { "back_out", "ease_back_out" },
    },
    origin = {
        { "cursor_anchor", "origin_anchor" }, { "cursor_center", "origin_cursor_center" }, { "center", "origin_center" },
    },
    sampling = {
        { "bilinear", "s_bilinear" }, { "bicubic", "s_bicubic" }, { "lanczos", "s_lanczos" }, { "point", "s_point" },
    },
    cursor_style = {
        { "original", "style_original" }, { "arrow", "style_arrow" }, { "image", "style_image" },
        { "dot", "style_dot" }, { "hidden", "style_hidden" },
    },
}

-- Listas de tecla modificadora (true = lista da rodinha) e de botão do mouse.
local MODIFIER_LISTS = { wheel_mod = true, btn_toggle_mod = false, btn_hold_mod = false, btn_follow_mod = false }
local BUTTON_LISTS = { "btn_toggle", "btn_hold", "btn_follow" }

local function fill_static_list(p, key)
    obs.obs_property_list_clear(p)
    for _, item in ipairs(STATIC_LISTS[key]) do
        obs.obs_property_list_add_string(p, T(item[2]), item[1])
    end
end

local function add_static_list(props, key, text_id)
    local p = obs.obs_properties_add_list(props, key, L(key, text_id),
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_static_list(p, key)
    return p
end

local function fill_modifier_list(p, is_wheel)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, T(is_wheel and "mod_none_wheel" or "mod_none"), "none")
    obs.obs_property_list_add_string(p, "Shift", "shift")
    obs.obs_property_list_add_string(p, "Ctrl", "ctrl")
    obs.obs_property_list_add_string(p, "Alt", "alt")
    obs.obs_property_list_add_string(p, "Ctrl + Shift", "ctrl+shift")
    obs.obs_property_list_add_string(p, "Ctrl + Alt", "ctrl+alt")
    obs.obs_property_list_add_string(p, "Shift + Alt", "shift+alt")
end

local function fill_button_list(p)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, T("btn_none"), "none")
    obs.obs_property_list_add_string(p, T("btn_middle"), "middle")
    obs.obs_property_list_add_string(p, T("btn_x1"), "x1")
    obs.obs_property_list_add_string(p, T("btn_x2"), "x2")
end

local function add_modifier_list(props, key, text_id)
    local p = obs.obs_properties_add_list(props, key, L(key, text_id),
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_modifier_list(p, MODIFIER_LISTS[key])
    return p
end

local function add_button_list(props, key, text_id)
    local p = obs.obs_properties_add_list(props, key, L(key, text_id),
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_button_list(p)
    return p
end

local function fill_source_list(p)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, T("src_auto"), "")
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
    for _, n in ipairs(captures) do obs.obs_property_list_add_string(p, n .. T("src_capture_suffix"), n) end
    for _, n in ipairs(others) do obs.obs_property_list_add_string(p, n, n) end
    for _, n in ipairs(scenes) do obs.obs_property_list_add_string(p, n .. T("src_scene_suffix"), n) end
end

local function fill_monitor_list(p)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, T("mon_auto"), "auto")
    for i, m in ipairs(enum_monitors()) do
        local label = string.format("Monitor %d: %dx%d @ %d,%d%s",
            i, m.w, m.h, m.x, m.y, m.primary and T("mon_primary") or "")
        obs.obs_property_list_add_string(p, label, string.format("mon:%d,%d,%d,%d", m.x, m.y, m.w, m.h))
    end
    obs.obs_property_list_add_string(p, T("mon_manual"), "manual")
end

-- Reaplica todos os textos da interface no idioma atual.
local function relabel_properties(props)
    for key, id in pairs(PROP_TEXT) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then obs.obs_property_set_description(p, T(id)) end
    end
    for key in pairs(STATIC_LISTS) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then fill_static_list(p, key) end
    end
    for key, is_wheel in pairs(MODIFIER_LISTS) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then fill_modifier_list(p, is_wheel) end
    end
    for _, key in ipairs(BUTTON_LISTS) do
        local p = obs.obs_properties_get(props, key)
        if p ~= nil then fill_button_list(p) end
    end
    local p = obs.obs_properties_get(props, "source_name")
    if p ~= nil then fill_source_list(p) end
    p = obs.obs_properties_get(props, "monitor_mode")
    if p ~= nil then fill_monitor_list(p) end
end

-- Idioma em que os rótulos da interface aberta foram criados.
local ui_lang = nil

local function on_language_modified(props, prop, settings)
    LANG = resolve_lang(obs.obs_data_get_string(settings, "language"))
    if LANG ~= ui_lang then
        local first = (ui_lang == nil)
        ui_lang = LANG
        relabel_properties(props)
        if not first then log(T("lang_reload")) end
    end
    return true
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
    ui_lang = LANG

    -- Idioma (rótulo fixo nos dois idiomas)
    local p_lang = obs.obs_properties_add_list(props, "language", "Idioma / Language",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_static_list(p_lang, "language")
    obs.obs_property_set_modified_callback(p_lang, on_language_modified)

    -- Fonte
    local g = obs.obs_properties_create()
    local p_src = obs.obs_properties_add_list(g, "source_name", L("source_name", "p_source"),
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_source_list(p_src)
    obs.obs_properties_add_button(g, "refresh_sources", L("refresh_sources", "b_refresh_sources"), function(pp)
        fill_source_list(obs.obs_properties_get(pp, "source_name"))
        return true
    end)
    obs.obs_properties_add_group(props, "grp_source", L("grp_source", "g_source"), obs.OBS_GROUP_NORMAL, g)

    -- Zoom
    g = obs.obs_properties_create()
    obs.obs_properties_add_float_slider(g, "zoom_factor", L("zoom_factor", "p_zoom_factor"), 1.05, 10.0, 0.05)
    obs.obs_properties_add_float_slider(g, "zoom_step", L("zoom_step", "p_zoom_step"), 0.05, 3.0, 0.05)
    obs.obs_properties_add_float_slider(g, "zoom_min", L("zoom_min", "p_zoom_min"), 1.05, 10.0, 0.05)
    obs.obs_properties_add_float_slider(g, "zoom_max", L("zoom_max", "p_zoom_max"), 1.05, 20.0, 0.05)
    obs.obs_properties_add_bool(g, "remember_level", L("remember_level", "p_remember"))
    obs.obs_properties_add_int_slider(g, "duration_ms", L("duration_ms", "p_duration"), 0, 3000, 10)
    add_static_list(g, "easing", "p_easing")
    add_static_list(g, "origin", "p_origin")
    add_static_list(g, "sampling", "p_sampling")
    obs.obs_properties_add_group(props, "grp_zoom", L("grp_zoom", "g_zoom"), obs.OBS_GROUP_NORMAL, g)

    -- Seguir mouse
    g = obs.obs_properties_create()
    obs.obs_properties_add_bool(g, "follow_on_zoom", L("follow_on_zoom", "p_follow_on_zoom"))
    obs.obs_properties_add_float_slider(g, "follow_speed", L("follow_speed", "p_follow_speed"), 1, 50, 0.5)
    obs.obs_properties_add_int_slider(g, "dead_zone", L("dead_zone", "p_dead_zone"), 0, 100, 1)
    obs.obs_properties_add_bool(g, "follow_outside", L("follow_outside", "p_follow_outside"))
    obs.obs_properties_add_float_slider(g, "idle_timeout", L("idle_timeout", "p_idle_timeout"), 0, 120, 0.5)
    obs.obs_properties_add_group(props, "grp_follow", L("grp_follow", "g_follow"), obs.OBS_GROUP_NORMAL, g)

    -- Controles pelo mouse
    g = obs.obs_properties_create()
    obs.obs_properties_add_bool(g, "wheel_enabled", L("wheel_enabled", "p_wheel_enabled"))
    add_modifier_list(g, "wheel_mod", "p_wheel_mod")
    obs.obs_properties_add_float_slider(g, "wheel_step", L("wheel_step", "p_wheel_step"), 0.05, 2.0, 0.05)
    obs.obs_properties_add_bool(g, "wheel_invert", L("wheel_invert", "p_wheel_invert"))
    obs.obs_properties_add_int_slider(g, "wheel_duration_ms", L("wheel_duration_ms", "p_wheel_duration"), 0, 1000, 10)
    add_button_list(g, "btn_toggle", "p_btn_toggle")
    add_modifier_list(g, "btn_toggle_mod", "p_btn_mod")
    add_button_list(g, "btn_hold", "p_btn_hold")
    add_modifier_list(g, "btn_hold_mod", "p_btn_mod")
    add_button_list(g, "btn_follow", "p_btn_follow")
    add_modifier_list(g, "btn_follow_mod", "p_btn_mod")
    obs.obs_properties_add_group(props, "grp_mouse", L("grp_mouse", "g_mouse"), obs.OBS_GROUP_NORMAL, g)

    -- Cursor
    g = obs.obs_properties_create()
    local p_style = add_static_list(g, "cursor_style", "p_cursor_style")
    obs.obs_property_set_modified_callback(p_style, on_cursor_options_modified)
    obs.obs_properties_add_int_slider(g, "cursor_size", L("cursor_size", "p_cursor_size"), 8, 200, 1)
    obs.obs_properties_add_color_alpha(g, "arrow_fill", L("arrow_fill", "p_arrow_fill"))
    obs.obs_properties_add_color_alpha(g, "arrow_outline", L("arrow_outline", "p_arrow_outline"))
    obs.obs_properties_add_color_alpha(g, "dot_color", L("dot_color", "p_dot_color"))
    obs.obs_properties_add_path(g, "cursor_image", L("cursor_image", "p_cursor_image"), obs.OBS_PATH_FILE,
        T("image_filter"), nil)
    obs.obs_properties_add_float_slider(g, "cursor_image_scale", L("cursor_image_scale", "p_image_scale"), 0.1, 5.0, 0.05)
    obs.obs_properties_add_int(g, "cursor_hotspot_x", L("cursor_hotspot_x", "p_hotspot_x"), 0, 1024, 1)
    obs.obs_properties_add_int(g, "cursor_hotspot_y", L("cursor_hotspot_y", "p_hotspot_y"), 0, 1024, 1)
    obs.obs_properties_add_float_slider(g, "cursor_hide_idle", L("cursor_hide_idle", "p_hide_idle"), 0, 30, 0.5)
    obs.obs_properties_add_bool(g, "cursor_keep_size", L("cursor_keep_size", "p_keep_size"))
    local p_halo = obs.obs_properties_add_bool(g, "halo_enabled", L("halo_enabled", "p_halo"))
    obs.obs_property_set_modified_callback(p_halo, on_cursor_options_modified)
    obs.obs_properties_add_color_alpha(g, "halo_color", L("halo_color", "p_halo_color"))
    obs.obs_properties_add_int_slider(g, "halo_size", L("halo_size", "p_halo_size"), 10, 400, 1)
    local p_click = obs.obs_properties_add_bool(g, "click_enabled", L("click_enabled", "p_click"))
    obs.obs_property_set_modified_callback(p_click, on_cursor_options_modified)
    obs.obs_properties_add_color_alpha(g, "click_left_color", L("click_left_color", "p_click_left"))
    obs.obs_properties_add_color_alpha(g, "click_right_color", L("click_right_color", "p_click_right"))
    obs.obs_properties_add_int_slider(g, "click_size", L("click_size", "p_click_size"), 10, 400, 1)
    obs.obs_properties_add_int_slider(g, "click_duration_ms", L("click_duration_ms", "p_click_duration"), 100, 2000, 10)
    obs.obs_properties_add_group(props, "grp_cursor", L("grp_cursor", "g_cursor"), obs.OBS_GROUP_NORMAL, g)

    -- Monitor
    g = obs.obs_properties_create()
    local p_mon = obs.obs_properties_add_list(g, "monitor_mode", L("monitor_mode", "p_monitor_mode"),
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    fill_monitor_list(p_mon)
    obs.obs_property_set_modified_callback(p_mon, on_monitor_mode_modified)
    obs.obs_properties_add_button(g, "refresh_monitors", L("refresh_monitors", "b_refresh_monitors"), function(pp)
        fill_monitor_list(obs.obs_properties_get(pp, "monitor_mode"))
        return true
    end)
    obs.obs_properties_add_int(g, "manual_x", L("manual_x", "p_manual_x"), -32768, 32768, 1)
    obs.obs_properties_add_int(g, "manual_y", L("manual_y", "p_manual_y"), -32768, 32768, 1)
    obs.obs_properties_add_int(g, "manual_w", L("manual_w", "p_manual_w"), 0, 32768, 1)
    obs.obs_properties_add_int(g, "manual_h", L("manual_h", "p_manual_h"), 0, 32768, 1)
    obs.obs_properties_add_group(props, "grp_monitor", L("grp_monitor", "g_monitor"), obs.OBS_GROUP_NORMAL, g)

    -- Atalhos e avançado
    g = obs.obs_properties_create()
    obs.obs_properties_add_button(g, "restore_hotkeys", L("restore_hotkeys", "b_restore_hotkeys"), function()
        restore_default_hotkeys()
        return false
    end)
    obs.obs_properties_add_button(g, "log_cursor", L("log_cursor", "b_log_cursor"), function()
        local mx, my = get_cursor_pos()
        if mx == nil then
            log(T("cursor_read_fail"))
        else
            log(T("cursor_pos", mx, my))
        end
        return false
    end)
    obs.obs_properties_add_bool(g, "debug", L("debug", "p_debug"))
    obs.obs_properties_add_group(props, "grp_advanced", L("grp_advanced", "g_advanced"), obs.OBS_GROUP_NORMAL, g)

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
    obs.obs_data_set_default_string(settings, "language", "auto")
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

    -- O OBS chama script_defaults com as configurações salvas antes de pedir a
    -- descrição, então o idioma escolhido já vale para a descrição e os atalhos.
    LANG = resolve_lang(obs.obs_data_get_string(settings, "language"))
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
    LANG = resolve_lang(obs.obs_data_get_string(settings, "language"))

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
        warn(T("image_missing"))
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
        hk.handle = obs.obs_hotkey_register_frontend("mouse_zoom_follow." .. hk.id, T(hk.desc), hk.cb)
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
    log(T("loaded", SCRIPT_VERSION))
    if not IS_WINDOWS then warn(T("windows_only")) end
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
<p>]] .. T("d_by") .. [[ <b>Pablo Ruan</b> — <a href="https://github.com/pabloruancoder/mouse-zoom-follow">github.com/pabloruancoder/mouse-zoom-follow</a></p>
<p>]] .. T("d_intro") .. [[</p>
<p>]] .. T("d_mouse") .. [[</p>
<p>]] .. T("d_cursor") .. [[</p>
<p>]] .. T("d_keyboard") .. [[</p>
<ul>
<li><b>Ctrl+Alt+Z</b> — ]] .. T("d_k_toggle") .. [[</li>
<li><b>Ctrl+Alt+X</b> — ]] .. T("d_k_hold") .. [[</li>
<li><b>Ctrl+Alt+F</b> — ]] .. T("d_k_follow") .. [[</li>
<li><b>Ctrl+Alt+↑ / ↓</b> — ]] .. T("d_k_inout") .. [[</li>
<li><b>Ctrl+Alt+0</b> — ]] .. T("d_k_reset") .. [[</li>
<li><b>Ctrl+Alt+C</b> — ]] .. T("d_k_center") .. [[</li>
</ul>
<p><i>Idioma / Language: ]] .. T("d_lang") .. [[</i></p>
]]
end
