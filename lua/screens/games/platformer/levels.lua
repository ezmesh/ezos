-- Platformer level data + per-environment palettes.
--
-- Each level is a table:
--   env  -- key into PALETTES below; drives tile colours and HUD theme
--   rows -- array of equal-length strings, top-to-bottom
--
-- Tile alphabet (one char per cell):
--   ' '  '.'   empty space
--   '#'         solid block (collidable from all sides)
--   '='         one-way platform: collide from above only
--   '^'         spike (instant death)
--   's'         player 1 spawn
--   'S'         player 2 spawn (falls back to player 1 spawn if missing)
--   'G'         level goal (touch to clear)
--   'e'         enemy patrol seed (engine spawns a left-walking enemy)
--
-- All cells are 16x16. Levels are 14 rows tall (top row of the screen
-- is reserved for the HUD). Width is whatever the rows say, capped at
-- ~40 cells in practice — wider works but reads as a marathon level.
--
-- Twelve levels in four environments, three each: forest, cave, ice,
-- volcano. Difficulty climbs gently within an environment and resets
-- on transition so each new biome reads as a fresh start.

local M = {}

-- ---------------------------------------------------------------------------
-- Palettes — one per environment. Each palette is an RGB triple per role
-- so the engine can call ez.display.rgb() once per role at init time.
-- Roles: bg (sky), block (solid tile), block_edge, spike, goal, enemy,
--        p1 (player 1 fill), p2 (player 2 fill), eye (player eye dot),
--        hud_bg, hud_fg.
-- ---------------------------------------------------------------------------

M.PALETTES = {
    forest = {
        bg         = {  35,  90, 150 },  -- soft daytime sky
        block      = {  60, 130,  60 },  -- mossy green
        block_edge = {  20,  60,  20 },
        spike      = { 230,  60,  60 },
        goal       = { 250, 220,  70 },
        enemy      = { 200,  60, 140 },
        p1         = { 240, 240, 250 },
        p2         = {  90, 200, 240 },
        eye        = {  10,  10,  10 },
        hud_bg     = {  10,  20,  35 },
        hud_fg     = { 220, 230, 240 },
        hud_dim    = { 130, 150, 170 },
    },
    cave = {
        bg         = {  15,  15,  25 },  -- pitch black
        block      = {  90,  85,  80 },  -- raw stone
        block_edge = {  35,  35,  35 },
        spike      = { 220,  90,  60 },
        goal       = { 250, 220,  70 },
        enemy      = { 200,  60, 140 },
        p1         = { 240, 240, 250 },
        p2         = {  90, 200, 240 },
        eye        = {  10,  10,  10 },
        hud_bg     = {   8,   8,  14 },
        hud_fg     = { 200, 210, 220 },
        hud_dim    = { 110, 120, 130 },
    },
    ice = {
        bg         = { 160, 200, 230 },  -- pale icy blue
        block      = { 200, 230, 250 },  -- packed snow
        block_edge = { 110, 150, 200 },
        spike      = { 240, 110, 110 },
        goal       = { 250, 220,  70 },
        enemy      = { 180,  80, 200 },
        p1         = {  40,  60,  90 },
        p2         = { 160,  40, 110 },
        eye        = {  10,  10,  20 },
        hud_bg     = { 230, 240, 250 },
        hud_fg     = {  20,  40,  70 },
        hud_dim    = {  90, 120, 160 },
    },
    volcano = {
        bg         = {  60,  20,  20 },  -- ember haze
        block      = { 100,  40,  30 },  -- scorched rock
        block_edge = {  40,  10,  10 },
        spike      = { 250, 200,  60 },
        goal       = { 240, 240, 100 },
        enemy      = { 240, 100,  40 },
        p1         = { 240, 240, 250 },
        p2         = { 200, 240, 100 },
        eye        = {  10,  10,  10 },
        hud_bg     = {  20,   8,   8 },
        hud_fg     = { 250, 220, 200 },
        hud_dim    = { 180, 130, 110 },
    },
}

-- ---------------------------------------------------------------------------
-- Level definitions.
--
-- Authoring tip: each row must be the same length within a level. The
-- engine doesn't pad — it will refuse to load a malformed level and
-- log a complaint to ez.log.
-- ---------------------------------------------------------------------------

M.LEVELS = {
    -- =====================================================================
    -- Forest (1..3) — tutorial. Mostly flat, a couple of pits, one spike row.
    -- =====================================================================

    -- 1: walk and jump.
    {
        env = "forest",
        rows = {
            "                                ",
            "                                ",
            "                                ",
            "                                ",
            "                                ",
            "                                ",
            "                                ",
            "                                ",
            "                       ###     G",
            "                  ###          #",
            "             ###               #",
            "       ###                     #",
            "  s                            #",
            "################################",
        },
    },

    -- 2: small pits + a spike pit floor.
    {
        env = "forest",
        rows = {
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                  ###                   ",
            "          ###                  ###      ",
            "                                        ",
            "  s                                   G ",
            "######      ######      ######    ######",
            "      ^^^^^^      ^^^^^^      ^^^^      ",
            "########################################",
        },
    },

    -- 3: introduces a one-way platform stack and the first enemy patrol.
    {
        env = "forest",
        rows = {
            "                                        ",
            "                                        ",
            "                                        ",
            "                       =====            ",
            "                                        ",
            "              =====                     ",
            "                              =====     ",
            "      =====                             ",
            "                                       G",
            "                                       #",
            "                                       #",
            "  s                e                   #",
            "######    ######    ######    ##########",
            "                                        ",
        },
    },

    -- =====================================================================
    -- Cave (4..6) — darker, tighter corridors, more spikes, two enemies.
    -- =====================================================================

    -- 4: ceiling spikes + a one-tile gap.
    {
        env = "cave",
        rows = {
            "##############################",
            "#^^^^^^^^^^^^^^^^^^^^^^^^^^^^#",
            "#                            #",
            "#                            #",
            "#                            #",
            "#                            #",
            "#         ###       ###      #",
            "#                            #",
            "#                            #",
            "#  s                         #",
            "######  ###   #####    #######",
            "#       ^^^                  #",
            "#                          G #",
            "##############################",
        },
    },

    -- 5: zigzag with enemies, longer level.
    {
        env = "cave",
        rows = {
            "########################################",
            "#                                      #",
            "#       =====                          #",
            "#                                      #",
            "#                =====                 #",
            "#                                      #",
            "#                         =====        #",
            "#                                      #",
            "#                                      #",
            "#                                      #",
            "#  s    e                e           G #",
            "########                          ######",
            "#      ^^^^^^^^^^^^^^^^^^^^^^^^^^      #",
            "########################################",
        },
    },

    -- 6: vertical chamber climb — one-way platforms staircase.
    {
        env = "cave",
        rows = {
            "##############################",
            "#                          G #",
            "#                        =====",
            "#                            #",
            "#                =====       #",
            "#                            #",
            "#         =====              #",
            "#                            #",
            "#  =====                     #",
            "#                            #",
            "#                            #",
            "#  s            e            #",
            "##############################",
            "                              ",
        },
    },

    -- =====================================================================
    -- Ice (7..9) — slippery floors. Engine reads env="ice" to lower
    -- ground friction. Lots of momentum management.
    -- =====================================================================

    -- 7: long ice slide with safe pits and a single spike strip.
    {
        env = "ice",
        rows = {
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "  s                                    G",
            "########      ##########      ##########",
            "        ^^^^^^          ^^^^^^          ",
            "########################################",
        },
    },

    -- 8: tight ice ledges with overhead one-way platforms.
    {
        env = "ice",
        rows = {
            "                                        ",
            "                                        ",
            "                                        ",
            "      =====        =====      =====     ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "  s                                    G",
            "######    ####    ####    ####    ######",
            "      ^^^^    ^^^^    ^^^^    ^^^^      ",
            "########################################",
        },
    },

    -- 9: long ice marathon with two enemies on slippery ground.
    {
        env = "ice",
        rows = {
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "          =====              =====                ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "  s        e                  e                  G",
            "##################################################",
            "                                                  ",
            "                                                  ",
        },
    },

    -- =====================================================================
    -- Volcano (10..12) — finale. Lava floor (spikes), tight platforming,
    -- multiple enemies. Last level is a victory lap with a long run.
    -- =====================================================================

    -- 10: lava floor with platform islands.
    {
        env = "volcano",
        rows = {
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "                                        ",
            "  s                                    G",
            "####    ####    ####    ####    ########",
            "    ^^^^    ^^^^    ^^^^    ^^^^        ",
            "########################################",
        },
    },

    -- 11: enemy gauntlet on a long ridge above lava.
    {
        env = "volcano",
        rows = {
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "                                                  ",
            "  s    e         e         e         e           G",
            "##################################################",
            "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^",
            "##################################################",
        },
    },

    -- 12: tower climb finale.
    {
        env = "volcano",
        rows = {
            "##############################",
            "#                          G #",
            "#                        =====",
            "#                            #",
            "#                  e         #",
            "#                =====       #",
            "#                            #",
            "#         e                  #",
            "#         =====              #",
            "#                            #",
            "#                            #",
            "#  s            e            #",
            "######    ####################",
            "    ^^^^^^                    ",
        },
    },
}

return M
