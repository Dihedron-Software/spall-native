package main

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:time"
import "core:os"
import "core:mem"
import "core:strings"
import "core:math"
import "core:slice"
import "core:flags"
import "core:container/queue"
import "core:container/lru"
import "core:unicode/utf8"
import "core:prof/spall"

import glm "core:math/linalg/glsl"

import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// input state
is_mouse_down  := false
was_mouse_down := false
clicked        := false
double_clicked := false
clicked_t      : time.Tick
mouse_up_now   := false
is_hovering    := false

alt_down       := false
shift_down     := false
ctrl_down      := false
super_down     := false

last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
scroll_val_y: f64 = 0
velocity_multiplier: f64 = 0

cam := Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}

// selection state
clicked_on_rect := false

// tooltip-state
rect_tooltip_rect := empty_event
rect_tooltip_pos := Vec2{}
rendered_rect_tooltip := false

did_pan := false

stat_sort_type := SortState.SelfTime
stat_sort_descending := true
resort_stats := false

// drawing state
colormode      := ColorMode.Dark

// font data
dpr:       f64 = 1
p_height:  f64 = 14
h1_height: f64 = 18
h2_height: f64 = 16
em:        f64 = p_height
p_font_size:  f64 = p_height
h1_font_size: f64 = h1_height
h2_font_size: f64 = h2_height
ch_width:   f64 = 0
thread_gap: f64 = 8

build_hash := 0
enable_debug := false
fps_history: queue.Queue(f64)
lru_text_cache: lru.Cache(Font_LRU_Key, Font_LRU_Text)


fullscreen := false

t               : f64
multiselect_t   : f64
greyanim_t      : f32
greymotion      : f32
frame_count     : int
last_frame_count: int
rect_count      : int
bucket_count    : int
was_sleeping    : bool
awake           : bool
random_seed     : u64

// loading / trace state
loader := Loader{}

// gl-rect nonsense
idx_pos := [?]glm.vec2{
	{0.0, 0.0},
	{1.0, 0.0},
	{0.0, 1.0},
	{1.0, 1.0},
}

ThreadSampleRunState :: struct {
	trace: ^Trace,
	ui_state: ^UIState,
	program_name: string,
	program_path: string,
	program_args: string,
}

threaded_sample_start :: proc(loader: ^Loader, data: rawptr) {
	state := cast(^ThreadSampleRunState)(data)

	trace := state.trace
	ui_state := state.ui_state
	program_name := state.program_name
	program_args := state.program_args
	program_path := state.program_path
	free(state)

	// TODO replace me with something that respects quote-escapes
	args := []string{}
	if len(program_args) > 0 {
		args = strings.split(program_args, " ")
	}

	sample_child(trace, program_name, program_path, args)

	pool_wait(&loader.pool)
	free_trace_temps(trace)

	ui_state.loading_config = false
	ui_state.post_loading = true
}

start_sampling :: proc(loader: ^Loader, trace: ^Trace, ui_state: ^UIState, program_name: string, program_path: string, program_args: string) -> bool {
	if ui_state.loading_config || program_name == "" {
		return false
	}

	free_trace(trace)
	init_trace(trace)
	trace.load_kickoff = time.tick_now()
	ui_state.loading_config = true
	ui_state.post_loading = false
	ui_state.ui_mode = .SampleRunning

	state := new(ThreadSampleRunState)
	state^ = ThreadSampleRunState{
		trace = trace,
		ui_state = ui_state,
		program_name = program_name,
		program_path = program_path,
		program_args = program_args,
	}

	loader_set_task(loader, Loader_Task{threaded_sample_start, state})
	return true
}

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer

SELF_TRACE :: false
GOOD_BOY_MODE :: false
opt := Cmd_Options{}

when SELF_TRACE {
	@(instrumentation_enter)
	spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
}

Cmd_Options :: struct {
	file: string `args:"pos=0" usage:"Trace file to load"`,
	terminal_mode: bool `args:"hidden, name=terminal-mode" usage:"Loads traces headlessly"`,
	full_speed: bool `args:"hidden, name=full-speed" usage:"Disables power-limiter to max out framerate"`,
	sample_exe: string `args:name=sample-exe" usage:"Sets sample exe path"`,
	sample_path: string `args:name=sample-path" usage:"Sets sample exe target path"`,
	sample_args: string `args:name=sample-args" usage:"Sets sample args"`,
	exe_path: string `args:"name=exe-path" usage:"Overrides exe path for trace files"`,
	pdb_path: string `args:"name=pdb-path" usage:"Overrides pdb path for trace files"`,
}

main :: proc() {
	when SELF_TRACE {
		current_time := time.time_to_unix(time.now())
		trace_name := fmt.tprintf("spall_timing_%d.spall", current_time)
		spall_ctx = spall.context_create(trace_name)
		defer spall.context_destroy(&spall_ctx)

		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		spall_buffer = spall.buffer_create(buffer_backing)
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
	}

	flags.parse_or_exit(&opt, os.args, .Unix)

	ui_state := UIState{
		post_loading = true,
		textboxes = make(map[TextboxKind]TextboxState),
	}

	ui_state.textboxes[.ProgramInput] = init_textbox_state()
	ui_state.textboxes[.CmdArgsInput] = init_textbox_state()
	ui_state.textboxes[.PathInput] = init_textbox_state()
	first  := &ui_state.textboxes[.ProgramInput]
	second := &ui_state.textboxes[.PathInput]
	third  := &ui_state.textboxes[.CmdArgsInput]
	first.next = second
	first.prev = third
	second.next = third
	second.prev = first
	third.next = first
	third.prev = second

	start_trace := ""
	open_mode := UIMode.TraceView
	// If user set a file on the cmdline
	if opt.file != "" {
		start_trace = strings.clone(opt.file)
	} else {

		// Does the platform support sampling?
		if supports_sampling() {
			open_mode = .MainMenu

			if opt.sample_exe != "" {
				strings.write_string(&first.b, opt.sample_exe)
				first.cursor = len(opt.sample_exe)
			}
			if opt.sample_path != "" {
				strings.write_string(&second.b, opt.sample_path)
				second.cursor = len(opt.sample_path)
			}
			if opt.sample_args != "" {
				strings.write_string(&third.b, opt.sample_args)
				third.cursor = len(opt.sample_args)
			}
		}
	}

	clicked_t = time.tick_now()
	ui_state.ui_mode = open_mode

	thread_count := 1//max(os.processor_core_count() - 1, 1)
	loader_init(&loader, thread_count)
	trace := new(Trace)
	init_trace(trace)

	if opt.terminal_mode {
		if !load_trace(&loader, trace, &ui_state, start_trace) {
			return
		}
		loader_wait(&loader)
		loader_destroy(&loader)
		return
	}
	load_trace(&loader, trace, &ui_state, start_trace)

	set_color_mode(false, true)

	gfx := GFX_Context{}
	width, height: f64
	gfx, dpr, width, height = create_context("spall", 1280, 720)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.Enable(gl.MULTISAMPLE)
	gl.Enable(gl.FRAMEBUFFER_SRGB)

	lru.init(&lru_text_cache, 1000)
	lru_text_cache.on_remove = rm_text_cache

	// Load statically packed fonts
	sans_font := #load("../fonts/Montserrat-Regular.ttf")
	mono_font := #load("../fonts/FiraMono-Regular.ttf")
	icon_font := #load("../fonts/fontawesome-webfont.ttf")
	fonts := [][]u8{ sans_font, mono_font, icon_font }
	sizes := []f64{ p_height * dpr, h1_height * dpr, h2_height * dpr }

	stbtt.InitFont(&font_map[FontType.DefaultFont], raw_data(sans_font), 0)
	stbtt.InitFont(&font_map[FontType.MonoFont], raw_data(mono_font), 0)
	stbtt.InitFont(&font_map[FontType.IconFont], raw_data(icon_font), 0)

	font_size[FontSize.PSize] = cast(f32)sizes[0]
	font_size[FontSize.H1Size] = cast(f32)sizes[1]
	font_size[FontSize.H2Size] = cast(f32)sizes[2]

	rect_program, rect_prog_ok := gl.load_shaders_source(rect_vert_src, rect_frag_src)
	if !rect_prog_ok {
		fmt.eprintln("Failed to create rect shader")
		return
	}

	rect_uniforms := gl.get_uniforms_from_program(rect_program)
	gl.UseProgram(rect_program)
	u_dpr := rect_uniforms["u_dpr"].location
	u_res := rect_uniforms["u_resolution"].location

	vao: u32
	gl.GenVertexArrays(1, &vao)
	gl.BindVertexArray(vao)

	// Set up dynamic rect buffer
	rect_deets_buffer: u32
	gl.GenBuffers(1, &rect_deets_buffer)
	gl.BindBuffer(gl.ARRAY_BUFFER, rect_deets_buffer)

	gl.EnableVertexAttribArray(u32(VertAttrs.RectPos))
	gl.VertexAttribPointer(u32(VertAttrs.RectPos), 4, gl.FLOAT, false, size_of(DrawRect), offset_of(DrawRect, pos))
	gl.VertexAttribDivisor(u32(VertAttrs.RectPos), 1)

	gl.EnableVertexAttribArray(u32(VertAttrs.Color))
	gl.VertexAttribPointer(u32(VertAttrs.Color), 4, gl.UNSIGNED_BYTE, true, size_of(DrawRect), offset_of(DrawRect, color))
	gl.VertexAttribDivisor(u32(VertAttrs.Color), 1)

	gl.EnableVertexAttribArray(u32(VertAttrs.UV))
	gl.VertexAttribPointer(u32(VertAttrs.UV), 2, gl.FLOAT, false, size_of(DrawRect), offset_of(DrawRect, uv))
	gl.VertexAttribDivisor(u32(VertAttrs.UV), 1)

	// Set up rect points buffer
	rect_points_buffer: u32
	gl.GenBuffers(1, &rect_points_buffer)
	gl.BindBuffer(gl.ARRAY_BUFFER, rect_points_buffer)
	gl.BufferData(gl.ARRAY_BUFFER, len(idx_pos)*size_of(idx_pos[0]), raw_data(idx_pos[:]), gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(u32(VertAttrs.IdxPos))
	gl.VertexAttribPointer(u32(VertAttrs.IdxPos), 2, gl.FLOAT, false, 0, 0)

	ch_width = measure_text("a", .PSize, .MonoFont)

	next_line(&ui_state.line_height, em)
	ui_state.info_pane_height = (ui_state.line_height * 12)

	start_tick := time.tick_now()
	last_tick: time.Tick
	awake := true
	was_sleeping := false
	main_loop: for {
		defer {
			clicked = false
			double_clicked = false
			is_hovering = false
			was_mouse_down = false
			mouse_up_now = false
			ui_state.render_one_more = false
			frame_count += 1
			free_all(context.temp_allocator)
		}

		cur_tick := time.tick_now()
		duration := time.tick_since(start_tick)
		t = time.duration_milliseconds(duration)

		dt := time.duration_seconds(time.tick_diff(last_tick, cur_tick))
		last_tick = cur_tick

		if queue.len(fps_history) > 100 { queue.pop_front(&fps_history) }
		queue.push_back(&fps_history, 1 / dt)

		// prevent dt from going *too* nuts if we've just woken up
		if was_sleeping {
			dt = min(0.016, dt)
			was_sleeping = false
		}

		should_toggle_fullscreen := false

		// if any of the textboxes are in focus, enable keyboard capture
		capture_text := false
		selected_box_id: TextboxKind
		selected_box: ^TextboxState = nil
		for id, box in &ui_state.textboxes {
			if box.focus {
				capture_text = true
				selected_box_id = id
				break
			}
		}

		if capture_text {
			selected_box = &ui_state.textboxes[selected_box_id]
		}

		ev := PlatformEvent{}
		event_loop: for {
			if !awake {
				ev = get_next_event(&gfx, true) // block for event
				if ev.type == .None {
					break event_loop
				}
				was_sleeping = true
				awake = true
			} else {
				ev = get_next_event(&gfx, false) // don't block for event
				if ev.type == .None {
					break event_loop
				}
			}

			#partial switch ev.type {
				case .Exit: break main_loop
				case .MouseMoved: {
					mouse_moved(ev.x, ev.y)
				}
				case .MouseUp: {
					if ev.mouse == .Left {
						mouse_up(ev.x, ev.y)
					}
				}
				case .MouseDown: {
					if ev.mouse == .Left {
						mouse_down(ev.x, ev.y)
					}
				}
				case .Scroll: {
					mouse_scroll(ev.y)
				}
				case .KeyDown: {
					#partial switch ev.key {
						case .LeftShift:    shift_down = true
						case .RightShift:   shift_down = true
						case .LeftControl:  ctrl_down = true
						case .RightControl: ctrl_down = true
						case .LeftAlt:      alt_down = true
						case .RightAlt:     alt_down = true
						case .LeftSuper:    super_down = true
						case .RightSuper:   super_down = true

						case .F11: should_toggle_fullscreen = true
						case .Return: {
							if alt_down {
								should_toggle_fullscreen = true
							}
						}
						case .Backspace:
							if capture_text {
								new_cursor := step_left_rune(selected_box.b.buf[:], selected_box.cursor)
								remove_range(&selected_box.b.buf, new_cursor, selected_box.cursor)
								selected_box.cursor = new_cursor
							}
						case .Tab:
							if capture_text {
								selected_box.focus = false
								if shift_down {
									selected_box = selected_box.prev
								} else {
									selected_box = selected_box.next
								}
								selected_box.focus = true
							}
						case .Left:
							if capture_text {
								selected_box.cursor = step_left_rune(selected_box.b.buf[:], selected_box.cursor)
							}
						case .Right:
							if capture_text {
								selected_box.cursor = step_right_rune(selected_box.b.buf[:], selected_box.cursor)
							}
						case .Up:
							if capture_text {
								selected_box.cursor = 0
							}
						case .Down:
							if capture_text {
								selected_box.cursor = len(selected_box.b.buf)
							}
						case .V:
							if capture_text && (ctrl_down || super_down) {
								path := get_clipboard(&gfx)
								strings.builder_reset(&selected_box.b)
								strings.write_string(&selected_box.b, path)
								selected_box.cursor = len(selected_box.b.buf)
							}
						case .R: {
							if !capture_text && (ctrl_down || super_down) {
								load_trace(&loader, trace, &ui_state, strings.clone(trace.file_name))
							}
						}
					}
				}
				case .KeyUp: {
					#partial switch ev.key {
						case .LeftShift:    shift_down = false
						case .RightShift:   shift_down = false
						case .LeftControl:  ctrl_down = false
						case .RightControl: ctrl_down = false
						case .LeftAlt:      alt_down = false
						case .RightAlt:     alt_down = false
						case .LeftSuper:    super_down = false
						case .RightSuper:   super_down = false
					}
				}
				case .Resize: {
					width = ev.w
					height = ev.h
				}
				case .FileDropped: {
					load_trace(&loader, trace, &ui_state, ev.str)
				}
				case .Rune: {
					if capture_text {
						cur_str := strings.to_string(selected_box.b)
						r_len := utf8.rune_count_in_string(cur_str)

						new_rune := ev.str
						defer delete(new_rune)
						if selected_box.cursor == r_len {
							strings.write_string(&selected_box.b, new_rune)
							selected_box.cursor += 1
						} else {
							inject_at(&selected_box.b.buf, selected_box.cursor, new_rune)
							selected_box.cursor += 1
						}
					}
				}
			}
		}

		if should_toggle_fullscreen {
			fullscreen = !fullscreen
			w, h := set_fullscreen(&gfx, fullscreen)
			width = f64(w)
			height = f64(h)
		}

		gl.Viewport(0, 0, i32(width), i32(height))
		gl.Uniform1f(u_dpr, f32(dpr))
		gl.Uniform2f(u_res, f32(width), f32(height))
		gl.BindBuffer(gl.ARRAY_BUFFER, rect_deets_buffer)
		gl.BindVertexArray(vao)

		gl.ClearColor(
			f32(bg_color2.x) / 255,
			f32(bg_color2.y) / 255,
			f32(bg_color2.z) / 255,
			f32(bg_color2.w) / 255,
		)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		ui_state.height = height / dpr
		ui_state.width  = width / dpr

		header_height   := 3 * em
		spall_x_pad     := 3 * em
		activity_height := 2 * em
		timebar_height  := 3 * em
		rect_height     := em + (0.75 * em)
		top_line_gap    := (em / 1.5)

		topbars_height    := header_height + timebar_height + activity_height
		minigraph_width   := 15 * em
		flamegraph_width  := ui_state.width - (spall_x_pad + minigraph_width)
		flamegraph_height := ui_state.height - topbars_height - ui_state.info_pane_height

		tab_select_height := 2 * em
		filter_pane_width := ui_state.filters_open ? (15 * em) : 0
		stats_pane_x := filter_pane_width

		ui_state.side_pad                  = spall_x_pad
		ui_state.rect_height               = rect_height
		ui_state.topbars_height            = topbars_height
		ui_state.top_line_gap              = top_line_gap
		ui_state.flamegraph_toptext_height = (ui_state.top_line_gap * 2) + (2 * em)
		ui_state.flamegraph_header_height  = ui_state.flamegraph_toptext_height + em

		ui_state.header_rect             = Rect{0, 0, ui_state.width, header_height}
		ui_state.global_timebar_rect     = Rect{0, header_height, ui_state.width, timebar_height}
		ui_state.global_activity_rect    = Rect{spall_x_pad, header_height + timebar_height, flamegraph_width, activity_height}
		ui_state.local_timebar_rect      = Rect{spall_x_pad, header_height + timebar_height + activity_height, flamegraph_width, timebar_height}
		ui_state.minimap_rect            = Rect{ui_state.width - minigraph_width, topbars_height, minigraph_width, flamegraph_height}

		ui_state.info_pane_rect          = Rect{0, ui_state.height - ui_state.info_pane_height, ui_state.width, ui_state.info_pane_height}
		ui_state.tab_rect                = Rect{0, ui_state.info_pane_rect.y, ui_state.width, tab_select_height}

		pane_start_y := ui_state.tab_rect.y + ui_state.tab_rect.h

		info_subpane_height := ui_state.info_pane_height - tab_select_height
		ui_state.filter_pane_rect        = Rect{0, pane_start_y, filter_pane_width, info_subpane_height}
		ui_state.stats_pane_rect         = Rect{stats_pane_x, pane_start_y, ui_state.width - stats_pane_x, info_subpane_height}

		ui_state.full_flamegraph_rect    = Rect{spall_x_pad, topbars_height, flamegraph_width, flamegraph_height}

		ui_state.inner_flamegraph_rect    = ui_state.full_flamegraph_rect
		ui_state.inner_flamegraph_rect.y += ui_state.flamegraph_toptext_height
		ui_state.inner_flamegraph_rect.h -= ui_state.flamegraph_toptext_height

		ui_state.padded_flamegraph_rect    = ui_state.inner_flamegraph_rect
		ui_state.padded_flamegraph_rect.y += em
		ui_state.padded_flamegraph_rect.h -= em

		#partial switch ui_state.ui_mode {
			case .MainMenu: draw_main_menu(&gfx, trace, &ui_state, dt)
			case .SampleRunning: draw_sample_running(&gfx, trace, &ui_state, dt)
			case .TraceLoading: draw_trace_loading(&gfx, trace, &ui_state, dt)
			case .TraceView: draw_trace_view(&gfx, trace, &ui_state,  dt)
		}

		// reset the cursor if we're not over a selectable thing
		if !is_hovering {
			reset_cursor(&gfx)
		}

		// Phew... Ok, time to dump to the screen
		flush_rects(&gfx)

		// save me my battery, plz
		if should_sleep(&cam, &ui_state) {
			cam.pan.x = cam.target_pan_x
			cam.vel.y = 0
			cam.current_scale = cam.target_scale
			ui_state.stats_pane_scroll_vel = 0
			ui_state.filter_pane_scroll_vel = 0

			awake = false
		} else {
			awake = true
		}

		gl.Finish()
		swap_buffers(&gfx)
		gl.Finish()
	}

	when SELF_TRACE || GOOD_BOY_MODE {
		loader_destroy(&loader)
	}

	when GOOD_BOY_MODE {
		gl.destroy_uniforms(rect_uniforms)

		delete(gfx.rects)
		delete(gfx.text_rects)

		free_trace(trace)
		free(trace)

		queue.destroy(&fps_history)
		lru.destroy(&lru_text_cache, true)
	}
}

should_sleep :: proc(cam: ^Camera, ui_state: ^UIState) -> bool {
	PAN_X_EPSILON :: 0.01
	PAN_Y_EPSILON :: 1.0
	SCALE_EPSILON :: 0.01
	SCROLL_EPSILON :: 0.01

	if opt.full_speed {
		return false
	}

	panning_x := math.abs(cam.pan.x - cam.target_pan_x) > PAN_X_EPSILON
	panning_y := math.abs(cam.vel.y - 0) > PAN_Y_EPSILON
	scaling   := math.abs((cam.current_scale - cam.target_scale) / cam.target_scale) > SCALE_EPSILON
	scrolling := (math.abs(ui_state.filter_pane_scroll_vel) > SCROLL_EPSILON) || (math.abs(ui_state.stats_pane_scroll_vel) > SCROLL_EPSILON)

	return (!ui_state.render_one_more && !panning_x && !panning_y && !scaling && !scrolling)
}
