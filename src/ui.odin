package main

import "base:runtime"
import "core:container/queue"
import "core:time"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "core:os"

import "core:prof/spall"

to_world_x :: proc(cam: Camera, x: f64) -> f64 {
	return (x - cam.pan.x) / cam.current_scale
}
to_world_y :: proc(cam: Camera, y: f64) -> f64 {
	return y + cam.pan.y
}
to_world_pos :: proc(cam: Camera, pos: Vec2) -> Vec2 {
	return Vec2{to_world_x(cam, pos.x), to_world_y(cam, pos.y)}
}

get_current_window :: proc(trace: ^Trace, cam: Camera, ui_state: ^UIState) -> (i64, i64) {
	display_range_start := i64(to_world_x(cam, 0))
	display_range_end   := i64(to_world_x(cam, ui_state.full_flamegraph_rect.w))
	return display_range_start, display_range_end
}

get_event :: proc(trace: ^Trace, ev_id: EventID) -> ^Event {
	p_idx := ev_id.pid
	t_idx := ev_id.tid
	d_idx := ev_id.did
	e_idx := ev_id.eid

	return &trace.processes[p_idx].threads[t_idx].depths[d_idx].events[e_idx]
}

set_flamegraph_camera :: proc(trace: ^Trace, ui_state: ^UIState, start_ticks, duration_ticks: i64) {
	cam.vel = Vec2{}

	cam.current_scale = rescale(1.0, 0, f64(duration_ticks), 0, ui_state.full_flamegraph_rect.w)
	cam.target_scale = cam.current_scale

	adj_start_ticks := f64(start_ticks - trace.total_min_time)

	cam.pan.x = -(adj_start_ticks * cam.current_scale)
	cam.target_pan_x = cam.pan.x
}

reset_flamegraph_camera :: proc(trace: ^Trace, ui_state: ^UIState) {
	cam = Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}
	if trace.event_count == 0 { trace.total_min_time = 0; trace.total_max_time = 100000000000000; trace.stamp_scale = 1 }

	start_time: f64 = 0
	end_time  := f64(trace.total_max_time - trace.total_min_time)

	side_pad  := 2 * em

	cam.current_scale = rescale(cam.current_scale, start_time, end_time, 0, ui_state.full_flamegraph_rect.w - (side_pad * 2))
	cam.target_scale = cam.current_scale

	cam.pan.x += side_pad
	cam.target_pan_x = cam.pan.x
}

next_line :: proc(y: ^f64, h: f64) -> f64 {
	res := y^
	y^ += h + (h / 1.5)
	return res
}
prev_line :: proc(y: ^f64, h: f64) -> f64 {
	res := y^
	y^ -= h + (h / 3)
	return res
}

tooltip :: proc(gfx: ^GFX_Context, pos: Vec2, min_x, max_x: f64, text: string) {
	text_width := measure_text(text, .PSize, .DefaultFont)
	text_height := get_text_height(.PSize, .DefaultFont)

	tooltip_rect := Rect{pos.x, pos.y - (em / 2), text_width + em, text_height + (1.25 * em)}
	if tooltip_rect.x + tooltip_rect.w > max_x {
		tooltip_rect.x = max_x - tooltip_rect.w
	}
	if tooltip_rect.x < min_x {
		tooltip_rect.x = min_x
	}

	draw_rect(gfx, tooltip_rect, bg_color)
	draw_rect_outline(gfx, tooltip_rect, 1, line_color)
	draw_text(gfx, text, Vec2{tooltip_rect.x + (em / 2), tooltip_rect.y + (em / 2)}, .PSize, .DefaultFont, text_color)
}

button :: proc(gfx: ^GFX_Context, in_rect: Rect, label_text, tooltip_text: string, font: FontType, min_x, max_x: f64) -> bool {
	draw_rect(gfx, in_rect, toolbar_button_color)
	label_width := measure_text(label_text, .PSize, font)
	label_height := get_text_height(.PSize, font)
	draw_text(gfx, label_text, 
	Vec2{
		in_rect.x + (in_rect.w / 2) - (label_width / 2), 
		in_rect.y + (in_rect.h / 2) - (label_height / 2),
	}, .PSize, font, toolbar_text_color)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor(gfx, "pointer")
		if clicked {
			return true
		} else if tooltip_text != "" {
			tip_pos := Vec2{in_rect.x, in_rect.y + in_rect.h + em}
			tooltip(gfx, tip_pos, min_x, max_x, tooltip_text)
		}
	}
	return false
}

draw_histogram :: proc(gfx: ^GFX_Context, trace: ^Trace, header: string, stat: ^FunctionStats, pos: Vec2, graph_size: f64) {
	line_width : f64 = 1
	graph_edge_pad : f64 = 2 * em
	line_gap := (em / 1.5)

	history := stat.hist
	temp_history := make([]f64, len(history), context.temp_allocator)

	max_val : f64 = 0
	min_val : f64 = max(f64)
	for entry, i in history {
		val := math.log2_f64(f64(entry + 1))
		temp_history[i] = val

		max_val = max(max_val, val)
		min_val = min(min_val, val)
	}
	max_range := max_val - min_val

	graph_top := pos.y + em + line_gap
	graph_bottom := graph_top + graph_size

	graph_y_bounds := graph_size - (graph_edge_pad * 2)
	graph_x_bounds := graph_size - graph_edge_pad

	text_x_overhead := 6 * em
	graph_overdraw_rect := Rect{pos.x - text_x_overhead, pos.y - line_gap, graph_size + text_x_overhead + (em / 2), ((em + line_gap) * 2) + graph_size + (em / 2) + line_gap}

	// reset mouse if we're in the graph
	if pt_in_rect(mouse_pos, graph_overdraw_rect) {
		rect_tooltip_rect = empty_event
		rect_tooltip_pos = Vec2{}
		rendered_rect_tooltip = false
		reset_cursor(gfx)
	}

	draw_rect(gfx, graph_overdraw_rect, bg_color)
	draw_rect(gfx, Rect{pos.x, graph_top, graph_size, graph_size}, bg_color2)
	draw_rect_outline(gfx, Rect{pos.x, graph_top, graph_size, graph_size}, 2, outline_color)

	header_str := trunc_string(header, (em / 2), graph_size)

	text_render_width := measure_text(header_str, .PSize, .DefaultFont)
	center_offset := (graph_size / 2) - (text_render_width / 2)
	draw_text(gfx, header_str, Vec2{pos.x + center_offset, pos.y}, .PSize, .MonoFont, text_color)

	high_height := graph_top + graph_edge_pad - (em / 2)
	low_height := graph_bottom - graph_edge_pad - (em / 2)

	near_width := pos.x + (graph_edge_pad / 2)
	far_width  := pos.x + graph_size - (graph_edge_pad / 2)

	if len(temp_history) > 1 {
		buf: [384]byte
		b := strings.builder_from_bytes(buf[:])

		y_tac_count := 5
		for i := 0; i < y_tac_count; i += 1 {
			cur_perc := f64(i) / f64(y_tac_count - 1)
			cur_y_val := math.pow(2, math.lerp(min_val, max_val, cur_perc))
			cur_y_height := math.lerp(low_height, high_height, cur_perc)

			strings.builder_reset(&b)
			my_write_float(&b, cur_y_val, 0)
			cur_y_str := strings.to_string(b)
			cur_y_width := measure_text(cur_y_str, .PSize, .DefaultFont) + line_gap
			draw_text(gfx, cur_y_str, Vec2{(pos.x - 5) - cur_y_width, cur_y_height}, .PSize, .DefaultFont, text_color)

			draw_line(gfx, Vec2{pos.x - 5, cur_y_height + (em / 2)}, Vec2{pos.x + 5, cur_y_height + (em / 2)}, 1, graph_color)
		}

		x_tac_count := 4
		for i := 0; i < x_tac_count; i += 1 {
			cur_perc := f64(i) / f64(x_tac_count - 1)
			cur_x_val := math.lerp(f64(stat.min_time), f64(stat.max_time), cur_perc)
			cur_x_pos := math.lerp(near_width, far_width, cur_perc)

			cur_x_str := stat_fmt(disp_time(trace, cur_x_val))
			cur_x_width := measure_text(cur_x_str, .PSize, .DefaultFont)
			draw_text(gfx, cur_x_str, Vec2{cur_x_pos - (cur_x_width / 2), graph_bottom + 5}, .PSize, .DefaultFont, text_color)

			draw_line(gfx, Vec2{cur_x_pos, graph_bottom - 5}, Vec2{cur_x_pos, graph_bottom + 5}, 1, graph_color)
		}
	}


	last_x : f64 = 0
	last_y : f64 = 0
	for entry, i in temp_history {
		point_x_offset : f64 = 0
		if len(temp_history) != 0 {
			point_x_offset = f64(i) * (graph_x_bounds / f64(len(temp_history)))
		}

		point_y_offset : f64 = 0
		if max_range != 0 {
			point_y_offset = f64(entry - min_val) * (graph_y_bounds / f64(max_range))
		}

		point_x := pos.x + point_x_offset + (graph_edge_pad / 2)
		point_y := graph_top + graph_size - point_y_offset - graph_edge_pad

		if len(temp_history) > 1  && i > 0 {
			draw_line(gfx, Vec2{last_x, last_y}, Vec2{point_x, point_y}, line_width, graph_color)
		}

		last_x = point_x
		last_y = point_y
	}

	if len(temp_history) > 1 {
		avg_offset := rescale(stat.avg_time, f64(stat.min_time), f64(stat.max_time), near_width, far_width)
		draw_line(gfx, Vec2{avg_offset, graph_top + graph_edge_pad}, Vec2{avg_offset, graph_bottom - graph_edge_pad}, 1, BVec4{255, 0, 0, 255})
	}
}

draw_graph :: proc(gfx: ^GFX_Context, header: string, history: ^queue.Queue(f64), pos: Vec2) {
	line_width : f64 = 1
	graph_edge_pad : f64 = 2 * em
	line_gap := (em / 1.5)
	graph_size: f64 = 150

	max_val : f64 = 0
	min_val : f64 = max(f64)
	sum_val : f64 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)
		max_val = max(max_val, entry)
		min_val = min(min_val, entry)
		sum_val += entry
	}
	max_range := max_val - min_val
	avg_val := sum_val / 100

	text_width := measure_text(header, .PSize, .DefaultFont)
	center_offset := (graph_size / 2) - (text_width / 2)
	draw_text(gfx, header, Vec2{pos.x + center_offset, pos.y}, .PSize, .DefaultFont, text_color)

	graph_top := pos.y + em + line_gap
	draw_rect(gfx, Rect{pos.x, graph_top, graph_size, graph_size}, bg_color2)
	draw_rect_outline(gfx, Rect{pos.x, graph_top, graph_size, graph_size}, 2, outline_color)

	draw_line(gfx, Vec2{pos.x - 5, graph_top + graph_size - graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_size - graph_edge_pad}, 1, graph_color)
	draw_line(gfx, Vec2{pos.x - 5, graph_top + graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_edge_pad}, 1, graph_color)

	if queue.len(history^) > 1 {
		buf: [384]byte
		b := strings.builder_from_bytes(buf[:])

		high_height := graph_top + graph_edge_pad - (em / 2)
		low_height := graph_top + graph_size - graph_edge_pad - (em / 2)
		avg_height := rescale(f64(avg_val), f64(min_val), f64(max_val), low_height, high_height)

		strings.builder_reset(&b)
		my_write_float(&b, max_val, 3)
		high_str := strings.to_string(b)
		high_width := measure_text(high_str, .PSize, .DefaultFont) + line_gap
		draw_text(gfx, high_str, Vec2{(pos.x - 5) - high_width, high_height}, .PSize, .DefaultFont, text_color)

		if queue.len(history^) > 90 {
			draw_line(gfx, Vec2{pos.x - 5, avg_height + (em / 2)}, Vec2{pos.x + 5, avg_height + (em / 2)}, 1, graph_color)

			strings.builder_reset(&b)
			my_write_float(&b, avg_val, 3)
			avg_str := strings.to_string(b)

			avg_width := measure_text(avg_str, .PSize, .DefaultFont) + line_gap
			draw_text(gfx, avg_str, Vec2{(pos.x - 5) - avg_width, avg_height}, .PSize, .DefaultFont, text_color)
		}

		strings.builder_reset(&b)
		my_write_float(&b, min_val, 3)
		low_str := strings.to_string(b)

		low_width := measure_text(low_str, .PSize, .DefaultFont) + line_gap
		draw_text(gfx, low_str, Vec2{(pos.x - 5) - low_width, low_height}, .PSize, .DefaultFont, text_color)
	}

	graph_y_bounds := graph_size - (graph_edge_pad * 2)
	graph_x_bounds := graph_size - graph_edge_pad

	last_x : f64 = 0
	last_y : f64 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)

		point_x_offset : f64 = 0
		if queue.len(history^) != 0 {
			point_x_offset = f64(i) * (graph_x_bounds / f64(queue.len(history^)))
		}

		point_y_offset : f64 = 0
		if max_range != 0 {
			point_y_offset = f64(entry - min_val) * (graph_y_bounds / f64(max_range))
		}

		point_x := pos.x + point_x_offset + (graph_edge_pad / 2)
		point_y := graph_top + graph_size - point_y_offset - graph_edge_pad

		if queue.len(history^) > 1  && i > 0 {
			draw_line(gfx, Vec2{last_x, last_y}, Vec2{point_x, point_y}, line_width, graph_color)
		}

		last_x = point_x
		last_y = point_y
	}
}

draw_reduced_header :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	header_rect := ui_state.header_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect

	// Render toolbar background
	draw_rect(gfx, header_rect, toolbar_color)

	// draw toolbar
	{
		edge_pad := 1 * em
		button_height := 2 * em
		button_width  := 2 * em
		button_pad    := 0.5 * em

		cursor_x := edge_pad

		// Draw Logo
		logo_text := "spall"
		logo_width := measure_text(logo_text, .H1Size, .DefaultFont)
		draw_text(gfx, logo_text, Vec2{cursor_x, (header_rect.h / 2) - (h1_height / 2)}, .H1Size, .DefaultFont, toolbar_text_color)
		cursor_x += logo_width + edge_pad

		// Open File
		if button(gfx, Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf07c", "open file", .IconFont, 0, ui_state.width) {
			filename, ok := open_file_dialog()
			if ok {
				load_trace(&loader, trace, ui_state, filename)
			}
		}
		cursor_x += button_width + button_pad

		file_name_width := measure_text(trace.base_name, .H1Size, .DefaultFont)
		name_x := max((full_flamegraph_rect.w / 2) - (file_name_width / 2), cursor_x)
		draw_text(gfx, trace.base_name, Vec2{name_x, (header_rect.h / 2) - (h1_height / 2)}, .H1Size, .DefaultFont, toolbar_text_color)

		// colormode button nonsense
		color_text : string
		tool_text : string
		switch colormode {
		case .Auto:
			tool_text = "switch to dark colors"
			color_text = "\uf042"
		case .Dark:
			tool_text = "switch to light colors"
			color_text = "\uf10c"
		case .Light:
			tool_text = "switch to auto colors"
			color_text = "\uf111"
		}

		if button(gfx, Rect{
			ui_state.width - edge_pad - button_width, 
			(header_rect.h / 2) - (button_height / 2), 
			button_width,
			button_height,
		}, color_text, tool_text, .IconFont, 0, ui_state.width) {
			new_colormode: ColorMode

			// rotate between auto, dark, and light
			switch colormode {
			case .Auto:
				new_colormode = .Dark
			case .Dark:
				new_colormode = .Light
			case .Light:
				new_colormode = .Auto
			}

			switch new_colormode {
			case .Auto:
				is_dark := get_system_color()
				set_color_mode(true, is_dark)
				set_session_storage("colormode", "auto")
			case .Dark:
				set_color_mode(false, true)
				set_session_storage("colormode", "dark")
			case .Light:
				set_color_mode(false, false)
				set_session_storage("colormode", "light")
			}
			colormode = new_colormode
		}
	}
}

draw_header :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	header_rect := ui_state.header_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect

	// Render toolbar background
	draw_rect(gfx, header_rect, toolbar_color)

	// draw toolbar
	{
		edge_pad := 1 * em
		button_height := 2 * em
		button_width  := 2 * em
		button_pad    := 0.5 * em

		cursor_x := edge_pad

		// Draw Logo
		logo_text := "spall"
		logo_width := measure_text(logo_text, .H1Size, .DefaultFont)
		draw_text(gfx, logo_text, Vec2{cursor_x, (header_rect.h / 2) - (h1_height / 2)}, .H1Size, .DefaultFont, toolbar_text_color)
		cursor_x += logo_width + edge_pad

		// Open File
		if button(gfx, Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf07c", "open file", .IconFont, 0, ui_state.width) {
			filename, ok := open_file_dialog()
			if ok {
				load_trace(&loader, trace, ui_state, filename)
			}
		}
		cursor_x += button_width + button_pad

		// Reset Camera
		if button(gfx, Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf066", "reset camera", .IconFont, 0, ui_state.width) {
			reset_flamegraph_camera(trace, ui_state)
		}
		cursor_x += button_width + button_pad

		// Process All Events
		if button(gfx, Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf1fe", "get stats for the whole file", .IconFont, 0, ui_state.width) {
			trace.stats.start_time = 0
			trace.stats.end_time = f64(trace.total_max_time - trace.total_min_time)
			ui_state.multiselecting = true
			build_selected_ranges(trace, ui_state)
		}
		cursor_x += button_width + button_pad

		if button(gfx, Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf0e2", "reload the current trace", .IconFont, 0, ui_state.width) {
			// reload the file
			fmt.printf("attempting to load %s\n", trace.file_name)
			load_trace(&loader, trace, ui_state, strings.clone(trace.file_name))
		}

		file_name_width := measure_text(trace.base_name, .H1Size, .DefaultFont)
		name_x := max((full_flamegraph_rect.w / 2) - (file_name_width / 2), cursor_x)
		draw_text(gfx, trace.base_name, Vec2{name_x, (header_rect.h / 2) - (h1_height / 2)}, .H1Size, .DefaultFont, toolbar_text_color)

		// colormode button nonsense
		color_text : string
		tool_text : string
		switch colormode {
		case .Auto:
			tool_text = "switch to dark colors"
			color_text = "\uf042"
		case .Dark:
			tool_text = "switch to light colors"
			color_text = "\uf10c"
		case .Light:
			tool_text = "switch to auto colors"
			color_text = "\uf111"
		}

		if button(gfx, Rect{
			ui_state.width - edge_pad - button_width, 
			(header_rect.h / 2) - (button_height / 2), 
			button_width,
			button_height,
		}, color_text, tool_text, .IconFont, 0, ui_state.width) {
			new_colormode: ColorMode

			// rotate between auto, dark, and light
			switch colormode {
			case .Auto:
				new_colormode = .Dark
			case .Dark:
				new_colormode = .Light
			case .Light:
				new_colormode = .Auto
			}

			switch new_colormode {
			case .Auto:
				is_dark := get_system_color()
				set_color_mode(true, is_dark)
				set_session_storage("colormode", "auto")
			case .Dark:
				set_color_mode(false, true)
				set_session_storage("colormode", "dark")
			case .Light:
				set_color_mode(false, false)
				set_session_storage("colormode", "light")
			}
			colormode = new_colormode
		}
		if button(gfx, Rect{ui_state.width - edge_pad - ((button_width * 2) + (button_pad)), (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf188", "toggle debug mode", .IconFont, 0, ui_state.width) {
			enable_debug = !enable_debug
		}
		if button(gfx, Rect{ui_state.width - edge_pad - ((button_width * 3) + (button_pad * 2)), (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf1fc", "regenerate colors", .IconFont, 0, ui_state.width) {
			generate_color_choices(trace, true)
		}
	}
}

draw_debug :: proc(gfx: ^GFX_Context, ui_state: ^UIState) {
	minimap_rect := ui_state.minimap_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	flamegraph_header_height := ui_state.flamegraph_header_height

	text_y := ui_state.height - em - ui_state.top_line_gap
	graph_pos := Vec2{ui_state.width - minimap_rect.w - 150, full_flamegraph_rect.y + flamegraph_header_height}
	x_subpad := em

	y := text_y
	draw_graph(gfx, "FPS", &fps_history, graph_pos)

	hash_str := fmt.tprintf("Build: 0x%X", abs(build_hash))
	hash_width := measure_text(hash_str, .PSize, .MonoFont)
	draw_text(gfx, hash_str, Vec2{ui_state.width - hash_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
	seed_width := measure_text(seed_str, .PSize, .MonoFont)
	draw_text(gfx, seed_str, Vec2{ui_state.width - seed_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	rects_str := fmt.tprintf("Rect Count: %d", rect_count)
	rects_txt_width := measure_text(rects_str, .PSize, .MonoFont)
	draw_text(gfx, rects_str, Vec2{ui_state.width - rects_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	buckets_str := fmt.tprintf("Bucket Count: %d", bucket_count)
	buckets_txt_width := measure_text(buckets_str, .PSize, .MonoFont)
	draw_text(gfx, buckets_str, Vec2{ui_state.width - buckets_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	events_str := fmt.tprintf("Event Count: %d", rect_count - bucket_count)
	events_txt_width := measure_text(events_str, .PSize, .MonoFont)
	draw_text(gfx, events_str, Vec2{ui_state.width - events_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	cache_hit_str := fmt.tprintf("TTF Cache Hits: %d", cache_hits_this_frame)
	cache_hit_txt_width := measure_text(cache_hit_str, .PSize, .MonoFont)
	draw_text(gfx, cache_hit_str, Vec2{ui_state.width - cache_hit_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	cache_miss_str := fmt.tprintf("TTF Cache Misses: %d", cache_misses_this_frame)
	cache_miss_txt_width := measure_text(cache_miss_str, .PSize, .MonoFont)
	draw_text(gfx, cache_miss_str, Vec2{ui_state.width - cache_miss_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	cache_hits_this_frame = 0
	cache_misses_this_frame = 0
}

draw_rect_tooltip :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	full_flamegraph_rect := ui_state.full_flamegraph_rect

	tip_pos := mouse_pos
	tip_pos += Vec2{1, 2} * em / dpr

	ids := rect_tooltip_rect
	thread := trace.processes[ids.pid].threads[ids.tid]
	depth := thread.depths[ids.did]
	ev := depth.events[ids.eid]

	duration := bound_duration(&ev, thread.max_time)

	rect_tooltip_name := ev_name(trace, &ev)
	if ev.duration == -1 {
		rect_tooltip_name = fmt.tprintf("%s (Did Not Finish)", ev_name(trace, &ev))
	}

	rect_tooltip_stats: string
	if ev.self_time != 0 && ev.self_time != duration {
		rect_tooltip_stats = fmt.tprintf("%s (self %s)", tooltip_fmt(disp_time(trace, f64(duration))), tooltip_fmt(disp_time(trace, f64(ev.self_time))))
	} else {
		rect_tooltip_stats = tooltip_fmt(disp_time(trace, f64(duration)))
	}

	text_height := get_text_height(.PSize, .DefaultFont)
	name_width := measure_text(rect_tooltip_name, .PSize, .DefaultFont)
	stats_width := measure_text(rect_tooltip_stats, .PSize, .DefaultFont)

	rect_height := text_height + (1.25 * em)
	rect_width := name_width + em + stats_width + em

	args := ""
	called_loc := ""
	defined_loc := ""
	if ev.has_addr {
		file, line, ok := get_line_info(trace, ev.args)
		if ok {
			called_loc = fmt.tprintf("%s:%d", file, line)
			info_width := measure_text(called_loc, .PSize, .DefaultFont)
			rect_width = max(rect_width, info_width + em)
			next_line(&rect_height, em)
		}

/*
		file, line, ok = get_line_info(trace, ev.id)
		if ok {
			defined_loc = fmt.tprintf("definition %s:%d", file, line)
			info_width := measure_text(defined_loc, .PSize, .DefaultFont)
			rect_width = max(rect_width, info_width + em)
			next_line(&rect_height, em)
		}
*/
	} else if ev.args > 0 {
		args = in_getstr(&trace.string_block, ev.args)
		args_width := measure_text(args, .PSize, .DefaultFont)
		rect_width = max(rect_width, args_width + em)
		next_line(&rect_height, em)
	}

	tooltip_rect := Rect{tip_pos.x, tip_pos.y - (em / 2), rect_width, rect_height}

	min_x := full_flamegraph_rect.x
	max_x := full_flamegraph_rect.x + full_flamegraph_rect.w
	if tooltip_rect.x + tooltip_rect.w > max_x {
		tooltip_rect.x = max_x - tooltip_rect.w
	}
	if tooltip_rect.x < min_x {
		tooltip_rect.x = min_x
	}

	draw_rect(gfx, tooltip_rect, bg_color)
	draw_rect_outline(gfx, tooltip_rect, 1, line_color)
	tooltip_start_x := tooltip_rect.x + (em / 2)
	tooltip_start_y := tooltip_rect.y + (em / 2)

	cursor_x := tooltip_start_x
	cursor_y := tooltip_start_y

	draw_text(gfx, rect_tooltip_stats, Vec2{cursor_x, cursor_y}, .PSize, .DefaultFont, rect_tooltip_stats_color)
	cursor_x += (em * 0.35) + stats_width
	draw_text(gfx, rect_tooltip_name, Vec2{cursor_x, cursor_y}, .PSize, .DefaultFont, text_color)

	if len(args) > 0 {
		next_line(&cursor_y, em)
		draw_text(gfx, args, Vec2{tooltip_start_x, cursor_y}, .PSize, .DefaultFont, text_color)
	}
	if len(called_loc) > 0 {
		next_line(&cursor_y, em)
		draw_text(gfx, called_loc, Vec2{tooltip_start_x, cursor_y}, .PSize, .DefaultFont, text_color)
	}
	if len(defined_loc) > 0 {
		next_line(&cursor_y, em)
		draw_text(gfx, defined_loc, Vec2{tooltip_start_x, cursor_y}, .PSize, .DefaultFont, text_color)
	}
}

draw_flamegraphs :: proc(gfx: ^GFX_Context, trace: ^Trace, start_time, end_time: i64, ui_state: ^UIState) {
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect
	padded_flamegraph_rect := ui_state.padded_flamegraph_rect

	flamegraph_header_height := ui_state.flamegraph_header_height
	flamegraph_toptext_height := ui_state.flamegraph_toptext_height
	info_pane_rect := ui_state.info_pane_rect

	// graph-relative timebar and subdivisions
	division_ns, draw_tick_start_ns, display_range_start_ns: f64
	ticks: int
	{
		// figure out how many divisions to split the current scale into
		window_range_ns := (full_flamegraph_rect.w / cam.current_scale) * trace.stamp_scale
		v1 := math.log10(window_range_ns)
		v2 := math.floor(v1)
		rem := v1 - v2

		division_ns = math.pow(10, v2)                           // multiples of 10
		if      rem < 0.3 { division_ns -= (division_ns * 0.8) } // multiples of 2
		else if rem < 0.6 { division_ns -= (division_ns / 2)   } // multiples of 5

		// find the current range in ns
		display_range_start_ns =  (                     (0 - cam.pan.x) / cam.current_scale) * trace.stamp_scale
		display_range_end_ns   := ((full_flamegraph_rect.w - cam.pan.x) / cam.current_scale) * trace.stamp_scale

		// round down to make sure we get the first line on screen
		draw_tick_start_ns = f_round_down(display_range_start_ns, division_ns)
		draw_tick_end_ns  := f_round_down(display_range_end_ns,   division_ns)

		// determine how many divisions to draw, with fudge-factor
		tick_range_ns := draw_tick_end_ns - draw_tick_start_ns
		ticks = int(tick_range_ns / division_ns) + 3

		subdivisions := 5
		line_x_start := -4
		line_x_end   := ticks * subdivisions

		// actually draw the lines
		line_start := full_flamegraph_rect.y + flamegraph_header_height - ui_state.top_line_gap
		line_height := full_flamegraph_rect.h
		for i := line_x_start; i < line_x_end; i += 1 {
			tick_time_ns := draw_tick_start_ns + (f64(i) * (division_ns / f64(subdivisions)))
			scaled_tick_time := tick_time_ns / trace.stamp_scale
			x_off := (scaled_tick_time * cam.current_scale) + cam.pan.x
			color := (i % subdivisions) != 0 ? subdivision_color : division_color

			draw_line(gfx, Vec2{ui_state.side_pad + x_off, line_start}, Vec2{ui_state.side_pad + x_off, line_start + line_height}, 1, BVec4{u8(color.x), u8(color.y), u8(color.z), u8(color.w)})
		}

	}

	// global instant markers
	if (full_flamegraph_rect.w / cam.current_scale) * trace.stamp_scale < 1_000_000_000 {
		inst_line_start  := full_flamegraph_rect.y + flamegraph_header_height - ui_state.top_line_gap
		inst_line_height := full_flamegraph_rect.h
		for inst in trace.global_instants {
			mx := ui_state.side_pad + (f64(inst.timestamp - trace.total_min_time) * cam.current_scale) + cam.pan.x
			if mx < ui_state.side_pad || mx > full_flamegraph_rect.w + ui_state.side_pad { continue }
			draw_line(gfx, Vec2{mx, inst_line_start}, Vec2{mx, inst_line_start + inst_line_height}, 1, xbar_color)
		}
	}

	flush_rects(gfx)

	// graph
	cur_y := padded_flamegraph_rect.y - cam.pan.y
	proc_loop: for &proc_v, p_idx in trace.processes {
		h1_size : f64 = 0
		if len(trace.processes) > 1 {
			if cur_y > full_flamegraph_rect.y {
				batch_text(gfx, get_proc_name(trace, &proc_v), Vec2{ui_state.side_pad + 5, cur_y}, .H1Size, .DefaultFont, text_color)
			}

			h1_size = h1_height + (h1_height / 2)
			cur_y += h1_size
		}

		thread_loop: for &thread, t_idx in proc_v.threads {
			last_cur_y := cur_y
			h2_size := h2_height + (h2_height / 2)
			cur_y += h2_size

			thread_gap := 8.0
			thread_advance := ((f64(len(thread.depths)) * ui_state.rect_height) + thread_gap)

			if cur_y > info_pane_rect.y {
				break proc_loop
			}
			if cur_y + thread_advance < 0 {
				cur_y += thread_advance
				continue
			}

			if last_cur_y > full_flamegraph_rect.y {
				batch_text(gfx, get_thread_name(trace, &thread), Vec2{ui_state.side_pad + 5, last_cur_y}, .H2Size, .DefaultFont, text_color)
			}

			cur_depth_off := 0
			for &depth, d_idx in thread.depths {
				tree := depth.tree
                if len(depth.tree) == 0 { continue }

				found_rid := -1
				range_loop: for range, r_idx in trace.stats.selected_ranges {
					if range.pid == p_idx && range.tid == t_idx && range.did == d_idx {
						found_rid = r_idx
						break
					}
				}

				// If we blow this, we're in space
				tree_stack := [128]int{}
				stack_len := 0

				tree_stack[0] = 0; stack_len += 1
				for stack_len > 0 {
					stack_len -= 1

					tree_idx := tree_stack[stack_len]
					cur_node := &tree[tree_idx]

					if cur_node.end_time < start_time || cur_node.start_time > end_time {
						continue
					}

					time_range := f64(cur_node.end_time - cur_node.start_time)
					range_width := time_range * cam.current_scale

					// draw summary faketangle
					min_width := 2.0
					if (range_width / math.sqrt_f64(CHUNK_NARY_WIDTH)) < min_width {
						y := ui_state.rect_height * f64(d_idx)
						h := ui_state.rect_height

						x := f64(cur_node.start_time)
						w := min_width * math.sqrt_f64(CHUNK_NARY_WIDTH)
						xm := x * cam.target_scale

						r_x   := x * cam.current_scale
						end_x := r_x + w

						r_x   += cam.pan.x + full_flamegraph_rect.x
						end_x += cam.pan.x + full_flamegraph_rect.x

						r_x    = max(r_x, 0)

						r_y := cur_y + y
						dr  := Rect{r_x, r_y, end_x - r_x, h}

						rect_color := get_node_color(trace, cur_node)
						grey := greyscale(rect_color)
						if ui_state.multiselecting {
							if found_rid != -1 {
								range := trace.stats.selected_ranges[found_rid]   
								ev_start, ev_end := get_event_range(&depth, tree_idx)

								if !range_in_range(ev_start, ev_end, range.start, range.end) {
									rect_color = grey
								}
							} else {
								rect_color = grey
							}
						}

						draw_rect(gfx, dr, BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255})

						rect_count += 1
						bucket_count += 1
						continue
					}

					// we're at a bottom node, draw the whole thing
					child_count := get_child_count(&depth, tree_idx)
					if child_count <= 0 {
						event_start_idx, event_end_idx := get_event_range(&depth, tree_idx)

						scan_arr := depth.events[event_start_idx:event_end_idx]
						y := ui_state.rect_height * f64(d_idx)
						h := ui_state.rect_height
						for &ev, de_id in scan_arr {
							x := f64(ev.timestamp - trace.total_min_time)
							duration := f64(bound_duration(&ev, thread.max_time))
							w := max(duration * cam.current_scale, 2.0)
							xm := x * cam.target_scale

							// Carefully extract the [start, end] interval of the rect so that we can clip the left
							// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
							// problems drawing a rectangle which starts at a massively huge negative number on
							// the left.
							r_x   := x * cam.current_scale
							end_x := r_x + w

							r_x   += cam.pan.x + full_flamegraph_rect.x
							end_x += cam.pan.x + full_flamegraph_rect.x

							r_x    = max(r_x, 0)

							r_y := cur_y + y
							dr := Rect{r_x, r_y, end_x - r_x, h}

							if !rect_in_rect(dr, inner_flamegraph_rect) {
								continue
							}

							name := ev_name(trace, &ev)
							e_idx := event_start_idx + de_id

							idx := name_color_idx(name)
							rect_color := trace.color_choices[idx]
							grey := greyscale(trace.color_choices[idx])
							if ui_state.multiselecting {
								if found_rid != -1 {
									range := trace.stats.selected_ranges[found_rid]   
									if !val_in_range(e_idx, range.start, range.end - 1) { 
										rect_color = grey
									}
								} else {
									rect_color = grey
								}
							}

							if int(trace.stats.selected_event.pid) == p_idx &&
							   int(trace.stats.selected_event.tid) == t_idx &&
							   int(trace.stats.selected_event.did) == d_idx &&
							   int(trace.stats.selected_event.eid) == e_idx {
								rect_color = adjust(rect_color, 40)
							}

							draw_rect(gfx, dr, BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255})
							rect_count += 1

							underhang := full_flamegraph_rect.x - dr.x
							overhang := (full_flamegraph_rect.x + full_flamegraph_rect.w) - dr.x
							disp_w := min(dr.w - underhang, dr.w, overhang)

							display_name := name
							if ev.duration == -1 {
								display_name = fmt.tprintf("%s (Did Not Finish)", name)
							}

							text_pad := (em / 2)
							text_width := int(math.floor((disp_w - (text_pad * 2)) / ch_width))
							max_chars := max(0, min(len(display_name), text_width))
							name_str := display_name[:max_chars]
							str_x := max(dr.x, full_flamegraph_rect.x) + text_pad

							if len(name_str) > 4 || max_chars == len(display_name) {
								if max_chars != len(display_name) {
									name_str = fmt.tprintf("%s…", name_str[:len(name_str)-1])
								}

								batch_text(gfx, name_str, Vec2{str_x, dr.y + (ui_state.rect_height / 2) - (em / 2)}, .PSize, .MonoFont, text_color3)
							}

							if pt_in_rect(mouse_pos, inner_flamegraph_rect) && pt_in_rect(mouse_pos, dr) {
								set_cursor(gfx, "pointer")
								if !rendered_rect_tooltip && !shift_down {
									rect_tooltip_pos = Vec2{dr.x, dr.y}
									rect_tooltip_rect = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
									rendered_rect_tooltip = true
								}

								if clicked && !shift_down {
									trace.stats.pressed_event = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
								}
								if mouse_up_now && !shift_down {
									trace.stats.released_event = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
								}
								if double_clicked && !shift_down {
									trace.zoom_event = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
								}
							}
						}
						continue
					}

					for i := child_count; i > 0; i -= 1 {
						next_idx := get_left_child(tree_idx) + i - 1
						tree_stack[stack_len] = next_idx; stack_len += 1
					}
				}
			}
			cur_y += thread_advance
		}
	}
	flush_rects(gfx)
	flush_text_batch(gfx)

	// relative time back-cover
	draw_rect(gfx, Rect{ui_state.side_pad, full_flamegraph_rect.y, full_flamegraph_rect.w, flamegraph_toptext_height}, bg_color)

	// draw timestamps for subdivision lines
	time_high_y := full_flamegraph_rect.y + flamegraph_toptext_height - (2 * em) - (2 * (em / 3))
	time_tick_y := full_flamegraph_rect.y + flamegraph_toptext_height - (em)     - (2 * (em / 3))

	div_clump_idx, fract_val, period := get_div_clump_idx(division_ns)
	text_side_pad := em
	old_tick_val: f64 = 0
	early_str, _, _ := clump_time(display_range_start_ns, div_clump_idx)
	_, _, early_tick := clump_time(f_round_down(draw_tick_start_ns, division_ns), div_clump_idx)
	old_tick_val = early_tick

	for i := -1; i < ticks; i += 1 {
		tick_time_ns := draw_tick_start_ns + (f64(i) * division_ns)
		scaled_tick_time := tick_time_ns / trace.stamp_scale
		x_off := (scaled_tick_time * cam.current_scale) + cam.pan.x

		start_str, tick_str, new_tick_val := clump_time(tick_time_ns, div_clump_idx)

		draw_top := false
		if new_tick_val != old_tick_val || fract_val > (period / 2) {
			draw_top = true
		}

		old_tick_val = new_tick_val
		top_text_width := measure_text(start_str, .PSize, .DefaultFont)
		tick_text_width := measure_text(tick_str, .PSize, .DefaultFont)

		if draw_top {
			top_x := ui_state.side_pad + x_off - ((top_text_width + text_side_pad) / 2)
			draw_rect(gfx, Rect{top_x, full_flamegraph_rect.y, top_text_width + text_side_pad, em + (text_side_pad / 2)}, tabbar_color)
			draw_text(gfx, start_str, Vec2{top_x + (text_side_pad / 2), time_high_y - (text_side_pad / 2)}, .PSize, .DefaultFont, text_color)
		}
		draw_text(gfx, tick_str, Vec2{ui_state.side_pad + x_off - (tick_text_width / 2), time_tick_y}, .PSize, .DefaultFont, text_color)
	}

	{
		if len(early_str) > 0 {
			top_text_width := measure_text(early_str, .PSize, .DefaultFont)
			draw_rect(gfx, Rect{ui_state.side_pad, full_flamegraph_rect.y, top_text_width + text_side_pad, em + (text_side_pad / 2)}, toolbar_color)
			draw_text(gfx, early_str, Vec2{ui_state.side_pad + (text_side_pad / 2), time_high_y - (text_side_pad / 2)}, .PSize, .DefaultFont, toolbar_text_color)
			draw_line(gfx, Vec2{ui_state.side_pad, full_flamegraph_rect.y}, Vec2{ui_state.side_pad, full_flamegraph_rect.y + flamegraph_toptext_height}, 5, toolbar_color)
		}
	}
}

draw_global_activity :: proc(gfx: ^GFX_Context, trace: ^Trace, highlight_start_x, highlight_end_x: f64, ui_state: ^UIState) {
	global_activity_rect := ui_state.global_activity_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	minimap_rect := ui_state.minimap_rect

	trace_duration := trace.total_max_time - trace.total_min_time
	wide_scale_x := rescale(1.0, 0, f64(trace_duration), 0, full_flamegraph_rect.w)
	layer_count := 1
	for proc_v, _ in trace.processes {
		layer_count += len(proc_v.threads)
	}

	draw_rect(gfx, global_activity_rect, BVec4{u8(wide_bg_color.x), u8(wide_bg_color.y), u8(wide_bg_color.z), u8(wide_bg_color.w)})

	for &proc_v, p_idx in trace.processes {
		for &tm, t_idx in proc_v.threads {
			if len(tm.depths) == 0 {
				continue
			}

			thread := &trace.processes[p_idx].threads[t_idx]
			depth := &thread.depths[0]
			tree := depth.tree

			// If we blow this, we're in space
			tree_stack := [128]int{}
			stack_len := 0

			alpha := u8(255.0 / f64(layer_count))
			tree_stack[0] = 0; stack_len += 1
			for stack_len > 0 {
				stack_len -= 1

				tree_idx := tree_stack[stack_len]
				cur_node := &tree[tree_idx]
				time_range := f64(cur_node.end_time - cur_node.start_time)
				range_width := time_range * wide_scale_x

				// draw summary faketangle
				min_width := 2.0 
				if (range_width / math.sqrt_f64(CHUNK_NARY_WIDTH)) < min_width {
					x := f64(cur_node.start_time)
					w := min_width * math.sqrt_f64(CHUNK_NARY_WIDTH)
					xm := x * wide_scale_x

					r_x   := x * wide_scale_x
					end_x := r_x + w

					r_x   += ui_state.side_pad
					end_x += ui_state.side_pad

					r_x    = max(r_x, 0)
					r_w   := end_x - r_x

					draw_rect(gfx, Rect{r_x, global_activity_rect.y, r_w, global_activity_rect.h}, BVec4{u8(wide_rect_color.x), u8(wide_rect_color.y), u8(wide_rect_color.z), alpha})
					continue
				}

				// we're at a bottom node, draw the whole thing
				child_count := get_child_count(depth, tree_idx)
				if child_count <= 0 {
					event_count := get_event_count(depth, tree_idx)
					event_start_idx := get_event_start_idx(depth, tree_idx)
					scan_arr := depth.events[event_start_idx:event_start_idx+event_count]
					for &ev, de_id in scan_arr {
						x := f64(ev.timestamp - trace.total_min_time)
						duration := f64(bound_duration(&ev, thread.max_time))
						w := max(duration * wide_scale_x, 2.0)
						xm := x * wide_scale_x

						// Carefully extract the [start, end] interval of the rect so that we can clip the left
						// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
						// problems drawing a rectangle which starts at a massively huge negative number on
						// the left.
						r_x   := x * wide_scale_x
						end_x := r_x + w

						r_x   += ui_state.side_pad
						end_x += ui_state.side_pad

						r_x    = max(r_x, 0)
						r_w   := end_x - r_x

						draw_rect(gfx, Rect{r_x, global_activity_rect.y, r_w, global_activity_rect.h}, BVec4{u8(wide_rect_color.x), u8(wide_rect_color.y), u8(wide_rect_color.z), alpha})
					}
					continue
				}

				for i := child_count; i > 0; i -= 1 {
					tree_stack[stack_len] = get_left_child(tree_idx) + i - 1; stack_len += 1
				}
			}
		}
	}

	highlight_box_l := Rect{ui_state.side_pad, global_activity_rect.y, highlight_start_x, global_activity_rect.h}
	draw_rect(gfx, highlight_box_l, BVec4{0, 0, 0, 150})

	highlight_box_r := Rect{ui_state.side_pad + highlight_end_x, global_activity_rect.y, full_flamegraph_rect.w - highlight_end_x, global_activity_rect.h}
	draw_rect(gfx, highlight_box_r, BVec4{0, 0, 0, 150})

	draw_rect(gfx, Rect{0, global_activity_rect.y, ui_state.side_pad, global_activity_rect.h}, BVec4{0, 0, 0, 255})
	draw_rect(gfx, Rect{ui_state.width - minimap_rect.w, global_activity_rect.y, minimap_rect.w, global_activity_rect.h}, BVec4{0, 0, 0, 255})
}

draw_minimap :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	minimap_rect              := ui_state.minimap_rect
	full_flamegraph_rect      := ui_state.full_flamegraph_rect
	info_pane_rect            := ui_state.info_pane_rect
	padded_flamegraph_rect    := ui_state.padded_flamegraph_rect
	flamegraph_toptext_height := ui_state.flamegraph_toptext_height
	minimap_pad := em

	// draw back-covers
	draw_rect(gfx, minimap_rect, bg_color)

	mini_rect_height := (em / 2)
	trace_duration := trace.total_max_time - trace.total_min_time
	x_scale := rescale(1.0, 0, f64(trace_duration), 0, minimap_rect.w - (2 * minimap_pad))
	y_scale := mini_rect_height / ui_state.rect_height

	tree_y : f64 = padded_flamegraph_rect.y - (cam.pan.y * y_scale)
	proc_loop: for &proc_v, p_idx in trace.processes {
		thread_loop: for &thread, t_idx in proc_v.threads {

			mini_thread_gap := 8.0
			thread_advance := ((f64(len(thread.depths)) * mini_rect_height) + mini_thread_gap)
			if tree_y > info_pane_rect.y {
				break proc_loop
			}
			if tree_y + thread_advance < 0 {
				tree_y += thread_advance
				continue
			}

			for &depth, d_idx in thread.depths {
				found_rid := -1
				range_loop: for range, r_idx in trace.stats.selected_ranges {
					if range.pid == p_idx && range.tid == t_idx && range.did == d_idx {
						found_rid = r_idx
						break
					}
				}

                if len(depth.tree) == 0 { continue }

				y := tree_y + (mini_rect_height * f64(d_idx))

				// If we blow this, we're in space
				tree_stack := [128]int{}
				stack_len := 0

				tree := &depth.tree
				tree_stack[0] = 0; stack_len += 1
				for stack_len > 0 {
					stack_len -= 1

					tree_idx := tree_stack[stack_len]
					cur_node := &tree[tree_idx]
					time_range := f64(cur_node.end_time - cur_node.start_time)
					range_width := time_range * x_scale

					// draw summary faketangle
					min_width := 2.0 
					if (range_width / math.sqrt_f64(CHUNK_NARY_WIDTH)) < min_width {
						x := f64(cur_node.start_time)
						w := min_width * math.sqrt_f64(CHUNK_NARY_WIDTH)
						xm := x * x_scale

						r_x   := x * x_scale
						end_x := r_x + w

						r_x   += minimap_rect.x + minimap_pad
						end_x += minimap_rect.x + minimap_pad

						r_x    = max(r_x, 0)
						r_w   := end_x - r_x

						rect_color := get_node_color(trace, cur_node)
						grey := greyscale(rect_color)
						if ui_state.multiselecting {
							if found_rid != -1 {
								range := trace.stats.selected_ranges[found_rid]   
								ev_start, ev_end := get_event_range(&depth, tree_idx)
								if !range_in_range(ev_start, ev_end, range.start, range.end) {
									rect_color = grey
								}
							} else {
								rect_color = grey
							}
						}

						draw_rect(gfx, Rect{r_x, y, r_w, mini_rect_height}, BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255})
						continue
					}

					// we're at a bottom node, draw the whole thing
					child_count := get_child_count(&depth, tree_idx)
					if child_count <= 0 {
						event_start_idx, event_end_idx := get_event_range(&depth, tree_idx)
						scan_arr := depth.events[event_start_idx:event_end_idx]
						for &ev, de_id in scan_arr {
							x := f64(ev.timestamp - trace.total_min_time)
							duration := f64(bound_duration(&ev, thread.max_time))
							w := max(duration * x_scale, 2.0)
							xm := x * x_scale

							// Carefully extract the [start, end] interval of the rect so that we can clip the left
							// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
							// problems drawing a rectangle which starts at a massively huge negative number on
							// the left.
							r_x   := x * x_scale
							end_x := r_x + w

							r_x   += minimap_rect.x + minimap_pad
							end_x += minimap_rect.x + minimap_pad

							r_x    = max(r_x, 0)
							r_w   := end_x - r_x

							name := ev_name(trace, &ev)
							idx := name_color_idx(name)
							e_idx := event_start_idx + de_id

							rect_color := trace.color_choices[idx]
							grey := greyscale(trace.color_choices[idx])
							if ui_state.multiselecting {
								if found_rid != -1 {
									range := trace.stats.selected_ranges[found_rid]   
									if !val_in_range(e_idx, range.start, range.end - 1) { 
										rect_color = grey
									}
								} else {
									rect_color = grey
								}
							}

							draw_rect(gfx, Rect{r_x, y, r_w, mini_rect_height}, BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255})
						}
						continue
					}

					for i := child_count; i > 0; i -= 1 {
						tree_stack[stack_len] = get_left_child(tree_idx) + i - 1; stack_len += 1
					}
				}
			}

			tree_y += thread_advance
		}
	}

	preview_height := full_flamegraph_rect.h * y_scale

	// alpha overlays
	draw_rect(gfx, Rect{minimap_rect.x, full_flamegraph_rect.y, minimap_rect.w, preview_height}, highlight_color)
	draw_rect(gfx, Rect{minimap_rect.x, full_flamegraph_rect.y + preview_height, minimap_rect.w, full_flamegraph_rect.h - preview_height}, shadow_color)

	// top-right cover-chunk
	draw_rect(gfx, Rect{minimap_rect.x, full_flamegraph_rect.y, minimap_rect.w + (minimap_pad * 2), flamegraph_toptext_height}, bg_color)
}

draw_topbars :: proc(gfx: ^GFX_Context, trace: ^Trace, start_time, end_time: i64, ui_state: ^UIState) {
	header_rect               := ui_state.header_rect
	global_activity_rect      := ui_state.global_activity_rect
	global_timebar_rect       := ui_state.global_timebar_rect
	minimap_rect              := ui_state.minimap_rect
	full_flamegraph_rect      := ui_state.full_flamegraph_rect
	flamegraph_toptext_height := ui_state.flamegraph_toptext_height

	//graph_header_text_height := (top_line_gap * 2) + em

	_start_time := disp_time(trace, f64(start_time))
	_end_time   := disp_time(trace, f64(end_time))
	trace_duration := disp_time(trace, f64(trace.total_max_time - trace.total_min_time))

	// draw back-covers
	draw_rect(gfx, Rect{0, header_rect.h, ui_state.width, global_activity_rect.h + global_timebar_rect.h}, bg_color) // top
	draw_rect(gfx, Rect{0, header_rect.h, ui_state.side_pad, ui_state.height}, bg_color) // left

	draw_line(gfx, Vec2{ui_state.side_pad, full_flamegraph_rect.y + flamegraph_toptext_height}, 
	Vec2{ui_state.width - minimap_rect.w, full_flamegraph_rect.y + flamegraph_toptext_height}, 1, line_color)

	highlight_start_x := rescale(_start_time, 0, trace_duration, 0, full_flamegraph_rect.w)
	highlight_end_x   := rescale(_end_time, 0, trace_duration, 0, full_flamegraph_rect.w)
	highlight_width   := highlight_end_x - highlight_start_x
	min_highlight     := 5.0
	if highlight_width < min_highlight {
		high_center := (highlight_start_x + highlight_end_x) / 2
		highlight_start_x = high_center - (min_highlight / 2)
		highlight_end_x = high_center + (min_highlight / 2)
	}
	draw_global_activity(gfx, trace, highlight_start_x, highlight_end_x, ui_state)

	// global timebar
	{
		start_time : i64 = 0
		end_time   := trace_duration
		default_scale := rescale(1.0, f64(start_time), f64(end_time), 0, full_flamegraph_rect.w)

		mus_range := full_flamegraph_rect.w / default_scale
		v1 := math.log10(mus_range)
		v2 := math.floor(v1)
		rem := v1 - v2

		subdivisions := 10
		division := math.pow(10, v2) // multiples of 10
		if rem < 0.3      { division -= (division * 0.8) } // multiples of 2
		else if rem < 0.6 { division -= (division / 2) } // multiples of 5

		display_range_start := -ui_state.width / default_scale
		display_range_end := ui_state.width / default_scale

		draw_tick_start := f_round_down(display_range_start, division)
		draw_tick_end := f_round_down(display_range_end, division)
		tick_range := draw_tick_end - draw_tick_start

		division /= f64(subdivisions)
		ticks := (int(tick_range / division) + 1)

		for i := 0; i < ticks; i += 1 {
			tick_time := draw_tick_start + (f64(i) * division)
			x_off := (tick_time * default_scale)

			line_start_y: f64
			if (i % subdivisions) == 0 {
				time_str := time_fmt(tick_time)
				text_width := measure_text(time_str, .PSize, .DefaultFont)

				draw_text(gfx, time_str, 
				Vec2{
					ui_state.side_pad + x_off - (text_width / 2),
					header_rect.h + (global_timebar_rect.h / 2) - (em / 2),
				}, .PSize, .DefaultFont, text_color)
				line_start_y = header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height
			} else {
				line_start_y = header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height + (p_height / 6)
			}

			draw_line(gfx,
			Vec2{ui_state.side_pad + x_off, line_start_y}, 
			Vec2{ui_state.side_pad + x_off, header_rect.h + global_timebar_rect.h - 2}, 2, division_color)
		}

		draw_line(gfx, 
			Vec2{ui_state.side_pad + highlight_start_x, header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height},
			Vec2{ui_state.side_pad + highlight_start_x, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 2, xbar_color)
		draw_line(gfx, 
			Vec2{ui_state.side_pad + highlight_end_x, header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height}, 
			Vec2{ui_state.side_pad + highlight_end_x, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 2, xbar_color)
		draw_line(gfx, 
			Vec2{0, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 
			Vec2{ui_state.width, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 1, line_color)
	}
}

INITIAL_ITER :: 500_000
FULL_ITER    :: 2_000_000
draw_stats :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	full_flamegraph_rect  := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect

	info_pane_rect        := ui_state.info_pane_rect
	tab_rect              := ui_state.tab_rect
	stats_pane_rect       := ui_state.stats_pane_rect
	filter_pane_rect      := ui_state.filter_pane_rect

	// Render info pane back-covers
	draw_line(gfx, Vec2{0, info_pane_rect.y}, Vec2{ui_state.width, info_pane_rect.y}, 1, line_color)
	draw_rect(gfx, info_pane_rect, bg_color) // bottom


	pane_start_y := tab_rect.y + tab_rect.h
	draw_rect(gfx, tab_rect, tabbar_color)
	draw_line(gfx, Vec2{0, pane_start_y}, Vec2{ui_state.width, pane_start_y}, 1, line_color)

	// draw pane grip
	handle_text := "\uf00a"
	handle_y := info_pane_rect.y + ((tab_rect.h / 2) - (h2_height / 2))
	handle_width := measure_text(handle_text, .H2Size, .IconFont)

	handle_pad := (em / 2)
	tab_bar_x := (2 * handle_pad) + handle_width
	tab_handle_rect := Rect{0, info_pane_rect.y, tab_bar_x, tab_rect.h}
	draw_rect(gfx, tab_handle_rect, grip_color)
	draw_text(gfx, handle_text, Vec2{handle_pad, handle_y}, .H2Size, .IconFont, toolbar_text_color)

	if pt_in_rect(mouse_pos, tab_handle_rect) || ui_state.resizing_pane {
		set_cursor(gfx, "pointer")
	}

	if clicked && pt_in_rect(clicked_pos, tab_handle_rect) {
		ui_state.resizing_pane = true
		ui_state.grip_delta = clicked_pos.y - tab_handle_rect.y
	}
	if is_mouse_down && ui_state.resizing_pane {
		pos_y := max((ui_state.header_rect.y + ui_state.header_rect.h), mouse_pos.y - ui_state.grip_delta)
		ui_state.info_pane_height = max(ui_state.height - pos_y, tab_rect.h)
	}
	if mouse_up_now && ui_state.resizing_pane {
		ui_state.resizing_pane = false
	}

	tab_bar_x += handle_pad
	filter_text := ui_state.filters_open ? "\uf150" : "\uf152"
	filter_width := measure_text(filter_text, .H2Size, .IconFont)
	draw_text(gfx, filter_text, Vec2{tab_bar_x, handle_y}, .H2Size, .IconFont, toolbar_text_color)
	tab_filter_rect := Rect{tab_bar_x, handle_y, filter_width, h2_height}
	if pt_in_rect(mouse_pos, tab_filter_rect) {
		set_cursor(gfx, "pointer")
	}
	if clicked && pt_in_rect(clicked_pos, tab_filter_rect) {
		ui_state.filters_open = !ui_state.filters_open
		ui_state.render_one_more = true
	}

	// hotpatch position after the update, so we don't have a frame with stale position state
	if ui_state.filters_open {
		stats_pane_rect.x = filter_pane_rect.x + filter_pane_rect.w
	} else {
		stats_pane_rect.x = info_pane_rect.x
	}

	if ui_state.filters_open {
		draw_rect(gfx, ui_state.filter_pane_rect, tabbar_color)
		if pt_in_rect(mouse_pos, ui_state.filter_pane_rect) {
			reset_cursor(gfx)
			is_hovering = false
			rendered_rect_tooltip = false
		}

		y_offset := ui_state.filter_pane_rect.y + (em / 2)

		max_lines := len(trace.processes)
		for proc_v, _ in trace.processes {
			max_lines += len(proc_v.threads)
		}

		line_height : f64 = 0
		next_line(&line_height, em)
		displayed_lines := int(filter_pane_rect.h / line_height)

		max_scroll := f64(max_lines - displayed_lines) * line_height
		ui_state.filter_pane_scroll_pos = max(ui_state.filter_pane_scroll_pos, -max_scroll)
		y_offset += ui_state.filter_pane_scroll_pos
		x_offset := (em / 2)

		thread_pad := (em / 2)

		checked_checkbox_text := "\uf14a"
		unchecked_checkbox_text := "\uf096"
		checkbox_width := measure_text(checked_checkbox_text, .PSize, .IconFont)

		checkbox_gap := (em / 2)
		filter_width := measure_text(filter_text, .H2Size, .IconFont)
		for &proc_v, _ in trace.processes {
			checkbox_text := proc_v.in_stats ? checked_checkbox_text : unchecked_checkbox_text

			y := next_line(&y_offset, em)

			if y > filter_pane_rect.y {
				checkbox_rect := Rect{x_offset, y, em, em}

				if pt_in_rect(mouse_pos, checkbox_rect) {
					set_cursor(gfx, "pointer")
				}
				if clicked && pt_in_rect(clicked_pos, checkbox_rect) {
					proc_v.in_stats = !proc_v.in_stats
					for &thread, _ in proc_v.threads {
						thread.in_stats = proc_v.in_stats
					}
					build_selected_ranges(trace, ui_state)
				}

				draw_text(gfx, checkbox_text, Vec2{checkbox_rect.x, checkbox_rect.y}, .PSize, .IconFont, toolbar_text_color)
				draw_text(gfx, get_proc_name(trace, &proc_v), Vec2{x_offset + checkbox_width + checkbox_gap, y - (em / 4)}, .PSize, .DefaultFont, toolbar_text_color)
			}


			for &thread, _ in proc_v.threads {
				checkbox_text := thread.in_stats ? checked_checkbox_text : unchecked_checkbox_text

				y := next_line(&y_offset, em)
				if y < filter_pane_rect.y {
					continue
				}
				if y >= ui_state.height {
					break
				}

				checkbox_rect := Rect{x_offset + thread_pad, y, em, em}
				draw_text(gfx, checkbox_text, Vec2{checkbox_rect.x, checkbox_rect.y}, .PSize, .IconFont, toolbar_text_color)
				draw_text(gfx, get_thread_name(trace, &thread), Vec2{x_offset + thread_pad + checkbox_width + checkbox_gap, y - (em / 4)}, .PSize, .DefaultFont, toolbar_text_color)

				if pt_in_rect(mouse_pos, checkbox_rect) {
					set_cursor(gfx, "pointer")
				}
				if clicked && pt_in_rect(clicked_pos, checkbox_rect) {
					thread.in_stats = !thread.in_stats
					build_selected_ranges(trace, ui_state)
				}
			}

			if y >= ui_state.height {
				break
			}
		}
	}

	x_subpad := em
	stats_pane_x := x_subpad + stats_pane_rect.x
	pane_gapped_start_y := stats_pane_rect.y + ui_state.top_line_gap

	// If the user selected a single rectangle
	if trace.stats.selected_event.pid != -1 &&
	   trace.stats.selected_event.tid != -1 &&
	   trace.stats.selected_event.did != -1 &&
	   trace.stats.selected_event.eid != -1 {
		y := pane_gapped_start_y

		p_idx := int(trace.stats.selected_event.pid)
		t_idx := int(trace.stats.selected_event.tid)
		d_idx := int(trace.stats.selected_event.did)
		e_idx := int(trace.stats.selected_event.eid)

		edge_pad      := 1 * em
		button_height := 1 * em
		button_width  := 1 * em
		text_x := stats_pane_x + button_width + edge_pad

		thread := trace.processes[p_idx].threads[t_idx]
		ev := thread.depths[d_idx].events[e_idx]
		name := ev_name(trace, &ev)

		rem_width := ui_state.width - text_x
		trunc_name_str := trunc_string(name, 0, rem_width)

		LineVal :: struct {
			y: f64,
			str: string,
		}

		text_val := LineVal{y, name}
		draw_text(gfx, trunc_name_str, Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)

		args_val := LineVal{-1, ""}
		if !ev.has_addr && ev.args > 0 {
			args_str := in_getstr(&trace.string_block, ev.args)
			args_val = LineVal{y, args_str}

			disp_str := fmt.tprintf(" user data: %s", args_str)
			trunc_disp_str := trunc_string(disp_str, 0, rem_width)
			draw_text(gfx, disp_str, Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
		}

		called_val := LineVal{-1, ""}
		defined_val := LineVal{-1, ""}
		if ev.has_addr {
			file, line, ok := get_line_info(trace, ev.args)
			if ok {
				loc_str := fmt.tprintf("%s:%d", file, line)
				line_str := fmt.tprintf("  call site: %s", loc_str)
				called_val = LineVal{y, loc_str}
				draw_text(gfx, line_str, Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
			}

			file, line, ok = get_line_info(trace, ev.id)
			if ok {
				loc_str := fmt.tprintf("%s:%d", file, line)
				line_str := fmt.tprintf(" definition: %s", loc_str)
				defined_val = LineVal{y, loc_str}
				draw_text(gfx, line_str, Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
			}
		}

		if enable_debug {
			cur_bucket, ok := get_bucket(trace, ev.id)
			if ok {
				draw_text(gfx, fmt.tprintf("source: %s", cur_bucket.source_path), Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
			}

			if ev.has_addr {
				draw_text(gfx, fmt.tprintf("address: 0x%08x", ev.id), Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
			}
		}
		draw_text(gfx, fmt.tprintf("start time: %s", time_fmt(disp_time(trace, f64(ev.timestamp - trace.total_min_time)))), Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
		draw_text(gfx, fmt.tprintf("  duration: %s", time_fmt(disp_time(trace, f64(bound_duration(&ev, thread.max_time))))), Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
		draw_text(gfx, fmt.tprintf(" self time: %s", time_fmt(disp_time(trace, f64(ev.self_time)))), Vec2{text_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)

		if called_val.y != -1 {
			if button(gfx, Rect{stats_pane_x, called_val.y, button_height, button_width}, 
					  "\uf0ea", "Copy Called At", .IconFont, 0, ui_state.width) {
				set_clipboard(gfx, called_val.str)
			}
		}
		if defined_val.y != -1 {
			if button(gfx, Rect{stats_pane_x, defined_val.y, button_height, button_width}, 
					  "\uf0ea", "Copy Defined At", .IconFont, 0, ui_state.width) {
				set_clipboard(gfx, defined_val.str)
			}
		}
		if args_val.y != -1 {
			if button(gfx, Rect{stats_pane_x, args_val.y, button_height, button_width}, 
					  "\uf0ea", "Copy Function Extra Data", .IconFont, 0, ui_state.width) {
				set_clipboard(gfx, args_val.str)
			}
		}
		if button(gfx, Rect{stats_pane_x, text_val.y, button_height, button_width}, 
				  "\uf0ea", "Copy Function Name", .IconFont, 0, ui_state.width) {
			set_clipboard(gfx, text_val.str)
		}

		// If we've got stats cooking already
	} else if trace.stats.state == .Pass1 || trace.stats.state == .Pass2 {
		y := pane_gapped_start_y
		center_x := ui_state.width / 2

		total_count := 0
		cur_count := 0
		for range, r_idx in trace.stats.selected_ranges {
			thread := trace.processes[range.pid].threads[range.tid]
			events := thread.depths[range.did].events

			total_count += len(events)
			if trace.stats.cur_offset.range_idx > r_idx {
				cur_count += len(events)
			} else if trace.stats.cur_offset.range_idx == r_idx {
				cur_count += trace.stats.cur_offset.event_idx - range.start
			}
		}

		loading_str := "Stats loading..."
		progress_str := fmt.tprintf("%s of %s", tens_fmt(u64(cur_count)), tens_fmt(u64(total_count)))
		hint_str := "Release multi-select to get the rest of the stats"

		strs := []string{ loading_str, progress_str }
		if trace.stats.just_started && total_count >= INITIAL_ITER {
			strs = []string{ loading_str, progress_str, hint_str }
		}

		max_height := 0.0
		for str in strs {
			next_line(&max_height, em)
		}

		cur_y := y + ((ui_state.height - y) / 2) - (max_height / 2)
		for str in strs {
			str_width := measure_text(str, .PSize, .DefaultFont)
			draw_text(gfx, str, Vec2{center_x - (str_width / 2), next_line(&cur_y, em)}, .PSize, .DefaultFont, text_color)
		}

		// If stats are ready to display
	} else if trace.stats.state == .Finished && ui_state.multiselecting {
		y := pane_gapped_start_y

		header_start := y
		header_height := 2 * em

		column_gap := 1.5 * em

		stats_pane_start := stats_pane_x - x_subpad
		cursor := stats_pane_x

		text_outf :: proc(gfx: ^GFX_Context, cursor: ^f64, y: f64, str: string, color := text_color) {
			width := measure_text(str, .PSize, .MonoFont)
			draw_text(gfx, str, Vec2{cursor^, y}, .PSize, .MonoFont, color)
			cursor^ += width
		}

		full_time := f64(trace.total_max_time - trace.total_min_time)

		y += header_height + (em / 2)

		displayed_lines := int(ui_state.stats_pane_rect.h / ui_state.line_height) - 1
		if displayed_lines < len(trace.stats.stat_map.entries) {
			max_lines := len(trace.stats.stat_map.entries)

			// goofy hack to get line height
			tmp := y
			next_line(&tmp, em)
			line_height := tmp - y

			max_scroll := (f64(max_lines - displayed_lines) * line_height) + em
			ui_state.stats_pane_scroll_pos = max(ui_state.stats_pane_scroll_pos, -max_scroll)
			y += ui_state.stats_pane_scroll_pos
		}

		stat_idx := 0
		last_pos := 0.0
		stat_loop: for i := 0; i < len(trace.stats.stat_map.entries); i += 1 {
			entry := trace.stats.stat_map.entries[i]
			stat := entry.val

			stat_idx += 1
			if y < (pane_gapped_start_y + (em / 2)) {
				next_line(&y, em)
				continue stat_loop
			}

			if y > ui_state.height {
				break stat_loop
			}
			last_pos = y

			y_before   := y - (em / 2)
			y_after    := y_before
			next_line(&y_after, em)

			click_rect := Rect{stats_pane_start, y_before, ui_state.width, 2 * em}
			if pt_in_rect(mouse_pos, click_rect) {
				set_cursor(gfx, "pointer")
			}

			if clicked && pt_in_rect(clicked_pos, click_rect) {
				if trace.stats.selected_func == entry.key {
					trace.stats.selected_func = {}
				} else {
					trace.stats.selected_func = entry.key
				}
			}

			if trace.stats.selected_func == entry.key {
				draw_rect(gfx, click_rect, highlight_color)
			}

			cursor = stats_pane_x
			total_perc := (f64(stat.total_time) / f64(trace.stats.total_time)) * 100

			total_text := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.total_time))))
			total_perc_text := fmt.tprintf("%.1f%%", total_perc)

			self_text  := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.self_time))))
			min_text   := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.min_time))))
			avg_text   := fmt.tprintf("%10s", stat_fmt(disp_time(trace, stat.avg_time)))
			max_text   := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.max_time))))
			count_text := fmt.tprintf("%10s", fmt.tprintf("%d", stat.count))

			text_outf(gfx, &cursor, y, self_text, text_color2);   cursor += column_gap
			{
				full_perc_width := measure_text(total_perc_text, .PSize, .MonoFont)
				perc_width := (ch_width * 5) - full_perc_width

				text_outf(gfx, &cursor, y, total_text, text_color2); cursor += ch_width
				cursor += perc_width
				draw_text(gfx, total_perc_text, Vec2{cursor, y}, .PSize, .MonoFont, text_color2); cursor += column_gap + full_perc_width
			}

			text_outf(gfx, &cursor, y, min_text, text_color2);   cursor += column_gap
			text_outf(gfx, &cursor, y, avg_text, text_color2);   cursor += column_gap
			text_outf(gfx, &cursor, y, max_text, text_color2);   cursor += column_gap
			text_outf(gfx, &cursor, y, count_text, text_color2); cursor += column_gap

			dr := Rect{cursor, y_before, (full_flamegraph_rect.w - cursor - column_gap) * f64(stat.total_time) / full_time, y_after - y_before}
			cursor += column_gap / 2

			ev := Event{has_addr = entry.key.has_addr, id = entry.key.id}
			orig_str := ev_name(trace, &ev)

			rem_width := ui_state.width - cursor
			name_str := trunc_string(orig_str, 0, rem_width)
			name_width := measure_text(orig_str, .PSize, .MonoFont)

			name := ev_name(trace, &ev)
			tmp_color := trace.color_choices[name_color_idx(name)]
			draw_rect(gfx, dr, BVec4{u8(tmp_color.x), u8(tmp_color.y), u8(tmp_color.z), 255})
			draw_text(gfx, name_str, Vec2{cursor, y_before + (em / 3)}, .PSize, .MonoFont, text_color)

			next_line(&y, em)
		}

		if trace.stats.selected_func.id > 0 {
			histogram_height := 18 * em
			line_gap := (em / 1.5)
			edge_gap := (em / 2)
			pos := Vec2{
				(inner_flamegraph_rect.x + inner_flamegraph_rect.w) - histogram_height - edge_gap,
				info_pane_rect.y - histogram_height - ((em + line_gap) * 2) - edge_gap,
			}

			ev := Event{has_addr = trace.stats.selected_func.has_addr, id = trace.stats.selected_func.id}
			name_str := ev_name(trace, &ev)
			stat, ok := sm_get(&trace.stats.stat_map, trace.stats.selected_func)
			if ok {
				draw_histogram(gfx, trace, name_str, stat, pos, histogram_height)
			}
		}

		y = header_start
		cursor = stats_pane_x - x_subpad

		table_header_height := 2 * em
		draw_rect(gfx, Rect{cursor, pane_start_y, ui_state.width, table_header_height + ui_state.top_line_gap}, subbar_color)
		draw_line(gfx, Vec2{cursor, pane_start_y}, Vec2{ui_state.width, pane_start_y}, 1, line_color)

		column_header :: proc(gfx: ^GFX_Context, cursor: ^f64, column_gap, text_y, rect_y, pane_h: f64, text: string, sort_type: SortState) {
			start_x := cursor^
			cursor^ += (column_gap / 2)

			width := measure_text(text, .PSize, .MonoFont)
			draw_text(gfx, text, Vec2{cursor^, text_y}, .PSize, .MonoFont, text_color)
			cursor^ += width + (column_gap / 2)
			end_x := cursor^

			if stat_sort_type == sort_type {
				arrow_icon := stat_sort_descending ? "\uf0dd" : "\uf0de"
				arrow_height := get_text_height(.PSize, .IconFont)
				arrow_width := measure_text(arrow_icon, .PSize, .IconFont)
				draw_text(gfx, arrow_icon, Vec2{end_x - arrow_width - (column_gap / 2), rect_y + (em) - (arrow_height / 2)}, .PSize, .IconFont, text_color)
			}

			draw_line(gfx, Vec2{cursor^, rect_y}, Vec2{cursor^, rect_y + pane_h}, 1, subbar_split_color)

			click_rect := Rect{start_x, rect_y, end_x - start_x, 2 * em}
			if pt_in_rect(mouse_pos, click_rect) {
				set_cursor(gfx, "pointer")
			}

			if clicked && pt_in_rect(clicked_pos, click_rect) {
				if stat_sort_type == sort_type {
					stat_sort_descending = !stat_sort_descending
				} else {
					stat_sort_type = sort_type
					stat_sort_descending = true
				}
				resort_stats = true
			}
		}

		self_header_text   := fmt.tprintf("%-10s", "   self")
		column_header(gfx, &cursor, column_gap, y, pane_start_y, info_pane_rect.h, self_header_text, .SelfTime)

		total_header_text  := fmt.tprintf("%-17s", "      total")
		column_header(gfx, &cursor, column_gap, y, pane_start_y, info_pane_rect.h, total_header_text, .TotalTime)

		min_header_text    := fmt.tprintf("%-10s", "   min.")
		column_header(gfx, &cursor, column_gap, y, pane_start_y, info_pane_rect.h, min_header_text, .MinTime)

		avg_header_text    := fmt.tprintf("%-10s", "   avg.")
		column_header(gfx, &cursor, column_gap, y, pane_start_y, info_pane_rect.h, avg_header_text, .AvgTime)

		max_header_text    := fmt.tprintf("%-10s", "   max.")
		column_header(gfx, &cursor, column_gap, y, pane_start_y, info_pane_rect.h, max_header_text, .MaxTime)

		max_count_text    := fmt.tprintf("%-10s", "   count")
		column_header(gfx, &cursor, column_gap, y, pane_start_y, info_pane_rect.h, max_count_text, .Count)

		name_header_text   := fmt.tprintf("%-10s", "   name")
		text_outf(gfx, &cursor, y, name_header_text, text_color)
	} else if info_pane_rect.h > ((ui_state.line_height * 2) + (ui_state.top_line_gap * 2)) {
		y := (info_pane_rect.y + info_pane_rect.h) - (ui_state.top_line_gap * 3)

		draw_text(gfx, "Shift-click and drag to get stats for multiple rectangles", Vec2{stats_pane_x, prev_line(&y, em)}, .PSize, .DefaultFont, text_color)
		draw_text(gfx, "Click on a rectangle to inspect", Vec2{stats_pane_x, prev_line(&y, em)}, .PSize, .DefaultFont, text_color)
	}
}

process_multiselect :: proc(gfx: ^GFX_Context, trace: ^Trace, pan_delta: Vec2, dt: f64, ui_state: ^UIState) {
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect
	padded_flamegraph_rect := ui_state.padded_flamegraph_rect
	info_pane_rect := ui_state.info_pane_rect

	// Handle single-select
	if mouse_up_now && !did_pan && pt_in_rect(clicked_pos, inner_flamegraph_rect) && trace.stats.pressed_event == trace.stats.released_event && !shift_down {
		trace.stats.selected_event = trace.stats.released_event
		clicked_on_rect = true
		ui_state.multiselecting = false
		ui_state.render_one_more = true
	}

	// Handle de-select
	if mouse_up_now && !did_pan && pt_in_rect(clicked_pos, inner_flamegraph_rect) && !clicked_on_rect && !shift_down {
		trace.stats.selected_event = empty_event
		non_zero_resize(&trace.stats.selected_ranges, 0)

		multiselect_t = 0
		trace.stats.state = .NoStats
		ui_state.multiselecting = false
		ui_state.render_one_more = true
	}

	// user wants to multi-select
	if is_mouse_down && shift_down {
		ui_state.multiselecting = true

		// cap multi-select box at graph edges
		delta := mouse_pos - clicked_pos
		c_x := min(clicked_pos.x, inner_flamegraph_rect.x + inner_flamegraph_rect.w)
		c_x = max(c_x, inner_flamegraph_rect.x)

		m_x := min(c_x + delta.x, inner_flamegraph_rect.x + inner_flamegraph_rect.w)
		m_x = max(m_x, inner_flamegraph_rect.x)

		d_x := m_x - c_x

		// draw multiselect box
		selected_rect := Rect{c_x, inner_flamegraph_rect.y, d_x, inner_flamegraph_rect.h}
		multiselect_color := toolbar_color
		{
			x1 := selected_rect.x + 1
			y1 := selected_rect.y + 1
			x2 := selected_rect.x + selected_rect.w - 1
			y2 := selected_rect.y + selected_rect.h - 1

			draw_line(gfx, Vec2{x1, y1}, Vec2{x1, y2}, 1, multiselect_color)
			draw_line(gfx, Vec2{x2, y1}, Vec2{x2, y2}, 1, multiselect_color)
		}

		multiselect_color.w = 20
		draw_rect(gfx, selected_rect, multiselect_color)

		// transform multiselect rect to screen position
		flopped_rect := Rect{}
		flopped_rect.x = min(selected_rect.x, selected_rect.x + selected_rect.w)
		x2 := max(selected_rect.x, selected_rect.x + selected_rect.w)
		flopped_rect.w = x2 - flopped_rect.x

		flopped_rect.y = selected_rect.y
		flopped_rect.h = selected_rect.h

		trace.stats.start_time = to_world_x(cam, flopped_rect.x - full_flamegraph_rect.x)
		trace.stats.end_time   = to_world_x(cam, flopped_rect.x - full_flamegraph_rect.x + flopped_rect.w)

		// draw multiselect timerange
		width_text := measure_fmt(disp_time(trace, trace.stats.end_time - trace.stats.start_time))
		width_text_width := measure_text(width_text, .PSize, .MonoFont) + em

		text_bg_rect  := flopped_rect
		text_bg_rect.x = text_bg_rect.x + (text_bg_rect.w / 2) - (width_text_width / 2)
		text_bg_rect.w = width_text_width
		text_bg_rect.y = flopped_rect.y
		text_bg_rect.h = (p_height * 2)

		text_bg_rect.x = max(text_bg_rect.x, inner_flamegraph_rect.x)

		multiselect_color.w = 180
		draw_rect(gfx, text_bg_rect, multiselect_color)
		draw_text(gfx,
			width_text, 
			Vec2{
				text_bg_rect.x + (em / 2), 
				text_bg_rect.y + (p_height / 2),
			}, 
			.PSize,
			.MonoFont,
			BVec4{255, 255, 255, 255},
		)

		// push it into screen-space
		flopped_rect.x -= full_flamegraph_rect.x

		build_selected_ranges(trace, ui_state)
	}
}

sort_stats :: proc(trace: ^Trace) {
	less: proc(a, b: StatEntry) -> bool
	switch stat_sort_type {
	case .SelfTime:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.self_time > b.val.self_time
			} else {
				return a.val.self_time < b.val.self_time
			}
		}
	case .TotalTime:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.total_time > b.val.total_time
			} else {
				return a.val.total_time < b.val.total_time
			}
		}
	case .MinTime:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.min_time > b.val.min_time
			} else {
				return a.val.min_time < b.val.min_time
			}
		}
	case .AvgTime:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.avg_time > b.val.avg_time
			} else {
				return a.val.avg_time < b.val.avg_time
			}
		}
	case .MaxTime:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.max_time > b.val.max_time
			} else {
				return a.val.max_time < b.val.max_time
			}
		}
	case .Count:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.count > b.val.count
			} else {
				return a.val.count < b.val.count
			}
		}
	}
	sm_sort(&trace.stats.stat_map, less)
}

process_inputs :: proc(trace: ^Trace, dt: f64, ui_state: ^UIState) -> (i64, i64, Vec2) {
	filter_pane_rect  := ui_state.filter_pane_rect
	stats_pane_rect   := ui_state.stats_pane_rect
	minimap_rect      := ui_state.minimap_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect
	padded_flamegraph_rect := ui_state.padded_flamegraph_rect

	trace_duration := trace.total_max_time - trace.total_min_time

	start_time, end_time: i64
	pan_delta: Vec2

	if ui_state.resizing_pane {
		start_time, end_time := get_current_window(trace, cam, ui_state)
		return start_time, end_time, pan_delta
	}

	{
		old_scale := cam.target_scale

		max_scale := 10000000.0
		min_scale := 0.5 * full_flamegraph_rect.w / f64(trace_duration)
		if pt_in_rect(mouse_pos, inner_flamegraph_rect) {
			cam.target_scale *= math.pow(1.0025, -scroll_val_y)
			cam.target_scale  = min(max(cam.target_scale, min_scale), max_scale)
		} else if pt_in_rect(mouse_pos, filter_pane_rect) {
			ui_state.filter_pane_scroll_vel -= scroll_val_y * 10
		} else if pt_in_rect(mouse_pos, stats_pane_rect) {
			ui_state.stats_pane_scroll_vel -= scroll_val_y * 10
		} else if pt_in_rect(mouse_pos, minimap_rect) {
			cam.vel.y += scroll_val_y * 10
		}
		scroll_val_y = 0

		ui_state.stats_pane_scroll_pos += (ui_state.stats_pane_scroll_vel * dt)
		ui_state.stats_pane_scroll_vel *= math.pow(0.000001, dt)
		ui_state.stats_pane_scroll_pos = min(ui_state.stats_pane_scroll_pos, 0)

		ui_state.filter_pane_scroll_pos += (ui_state.filter_pane_scroll_vel * dt)
		ui_state.filter_pane_scroll_vel *= math.pow(0.000001, dt)
		ui_state.filter_pane_scroll_pos = min(ui_state.filter_pane_scroll_pos, 0)

		cam.current_scale += (cam.target_scale - cam.current_scale) * (1 - math.pow(math.pow_f64(0.1, 12), (dt)))
		cam.current_scale = min(max(cam.current_scale, min_scale), max_scale)

		last_start_time, last_end_time := get_current_window(trace, cam, ui_state)

		get_max_y_pan :: proc(processes: []Process, rect_height: f64) -> f64 {
			cur_y : f64 = 0

			for proc_v, _ in processes {
				if len(processes) > 1 {
					h1_size := h1_height + (h1_height / 2)
					cur_y += h1_size
				}

				for tm, _ in proc_v.threads {
					h2_size := h2_height + (h2_height / 2)
					cur_y += h2_size + ((f64(len(tm.depths)) * rect_height) + thread_gap)
				}
			}

			return cur_y
		}
		max_height := get_max_y_pan(trace.processes[:], ui_state.rect_height)
		max_y_pan := max(+20 * em + max_height - inner_flamegraph_rect.h, 0)
		min_y_pan := min(-20 * em, max_y_pan)
		max_x_pan := max(+20 * em, 0)
		min_x_pan := min(-20 * em + full_flamegraph_rect.w + -(f64(trace_duration)) * cam.target_scale, max_x_pan)

		// compute pan, scale + scroll
		if is_mouse_down || mouse_up_now {
			MIN_PAN :: 5
			pan_dist := distance(mouse_pos, clicked_pos)
			if pan_dist > MIN_PAN {
				did_pan = true
			}
		}

		if did_pan {
			pan_delta = mouse_pos - last_mouse_pos
		}

		if is_mouse_down && !shift_down {
			if pt_in_rect(clicked_pos, padded_flamegraph_rect) {

				if cam.target_pan_x < min_x_pan {
					pan_delta.x *= math.pow_f64(2, (cam.target_pan_x - min_x_pan) / 32)
				}
				if cam.target_pan_x > max_x_pan {
					pan_delta.x *= math.pow(2, (max_x_pan - cam.target_pan_x) / 32)
				}
				if cam.pan.y < min_y_pan {
					pan_delta.y *= math.pow(2, (cam.pan.y - min_y_pan) / 32)
				}
				if cam.pan.y > max_y_pan {
					pan_delta.y *= math.pow(2, (max_y_pan - cam.pan.y) / 32)
				}

				cam.vel.y = -pan_delta.y / dt
				cam.vel.x = pan_delta.x / dt
			}
			last_mouse_pos = mouse_pos
		}

		cam_mouse_x := mouse_pos.x - ui_state.side_pad

		if cam.target_scale != old_scale {
			cam.target_pan_x = ((cam.target_pan_x - cam_mouse_x) * (cam.target_scale / old_scale)) + cam_mouse_x
			if cam.target_pan_x < min_x_pan {
				cam.target_pan_x = min_x_pan
			}
			if cam.target_pan_x > max_x_pan {
				cam.target_pan_x = max_x_pan
			}
		}

		cam.target_pan_x = cam.target_pan_x + (cam.vel.x * dt)
		cam.pan.y = cam.pan.y + (cam.vel.y * dt)
		cam.vel *= math.pow(0.0001, dt)

		edge_sproing : f64 = 0.0001
		if cam.pan.y < min_y_pan && !is_mouse_down {
			cam.pan.y = min_y_pan + (cam.pan.y - min_y_pan) * math.pow(edge_sproing, dt)
			cam.vel.y *= math.pow(0.0001, dt)
		}
		if cam.pan.y > max_y_pan && !is_mouse_down {
			cam.pan.y = max_y_pan + (cam.pan.y - max_y_pan) * math.pow(edge_sproing, dt)
			cam.vel.y *= math.pow(0.0001, dt)
		}

		if cam.target_pan_x < min_x_pan && !is_mouse_down {
			cam.target_pan_x = min_x_pan + (cam.target_pan_x - min_x_pan) * math.pow(edge_sproing, dt)
			cam.vel.x *= math.pow(0.0001, dt)
		}
		if cam.target_pan_x > max_x_pan && !is_mouse_down {
			cam.target_pan_x = max_x_pan + (cam.target_pan_x - max_x_pan) * math.pow(edge_sproing, dt)
			cam.vel.x *= math.pow(0.0001, dt)
		}

		cam.pan.x = cam.target_pan_x + (cam.pan.x - cam.target_pan_x) * math.pow(math.pow_f64(0.1, 12.0), dt)
		start_time, end_time = get_current_window(trace, cam, ui_state)
	}

	return start_time, end_time, pan_delta
}

build_selected_ranges :: proc(trace: ^Trace, ui_state: ^UIState) {
	init_stat_state(&trace.stats, ui_state)

	// build out ranges
	for proc_v, p_idx in trace.processes {
		for thread, t_idx in proc_v.threads {
			if !thread.in_stats {
				continue
			}

			for depth, d_idx in thread.depths {
				if len(depth.events) == 0 { continue }

				start_idx := find_idx(trace, depth.events[:], i64(trace.stats.start_time))
				end_idx := find_idx(trace, depth.events[:], i64(trace.stats.end_time))
				if start_idx == -1 {
					start_idx = 0
				}
				if end_idx == -1 {
					end_idx = len(depth.events) - 1
				}
				scan_arr := depth.events[start_idx:end_idx+1]

				real_start := -1
				fwd_scan_loop: for i := 0; i < len(scan_arr); i += 1 {
					ev := scan_arr[i]

					start := f64(ev.timestamp - trace.total_min_time)
					width := f64(bound_duration(&ev, thread.max_time))
					if !range_in_range(start, start + width, trace.stats.start_time, trace.stats.end_time) {
						continue fwd_scan_loop
					}

					real_start = start_idx + i
					break fwd_scan_loop
				}

				real_end := -1
				rev_scan_loop: for i := len(scan_arr) - 1; i >= 0; i -= 1 {
					ev := scan_arr[i]

					start := f64(ev.timestamp - trace.total_min_time)
					width := f64(bound_duration(&ev, thread.max_time))
					if !range_in_range(start, start + width, trace.stats.start_time, trace.stats.end_time) {
						continue rev_scan_loop
					}

					real_end = start_idx + i + 1
					break rev_scan_loop
				}

				if real_start != -1 && real_end != -1 {
					non_zero_append(&trace.stats.selected_ranges, Range{p_idx, t_idx, d_idx, real_start, real_end})
				}
			}
		}
	}
}

init_stat_state :: proc(stats: ^Stats, ui_state: ^UIState) {
	stats.state = .Pass1
	stats.total_time = 0
	stats.cur_offset = StatOffset{}
	stats.selected_event = empty_event
	stats.pressed_event  = empty_event
	stats.released_event = empty_event

	ui_state.stats_pane_scroll_pos = 0
	ui_state.stats_pane_scroll_vel = 0

	stats.just_started = true

	sm_clear(&stats.stat_map)
	non_zero_resize(&stats.selected_ranges, 0)
}

process_stats :: proc(trace: ^Trace, ui_state: ^UIState) {
	if trace.stats.state == .Finished || trace.stats.state == .NoStats {
		return
	}

	ui_state.render_one_more = true
	if (trace.stats.state == .Pass1 || trace.stats.state == .Pass2) {
		event_count := 0
		iter_max := trace.stats.just_started ? INITIAL_ITER : FULL_ITER

		broke_early := false
		if trace.stats.state == .Pass1 {
			pass1_range_loop: for range, r_idx in trace.stats.selected_ranges {
				start_idx := range.start
				if trace.stats.cur_offset.range_idx > r_idx {
					continue
				} else if trace.stats.cur_offset.range_idx == r_idx {
					start_idx = max(start_idx, trace.stats.cur_offset.event_idx)
				}

				thread := trace.processes[range.pid].threads[range.tid]
				events := thread.depths[range.did].events[start_idx:range.end]

				for &ev, e_idx in events {
					if event_count > iter_max {
						trace.stats.cur_offset = StatOffset{r_idx, start_idx + e_idx}
						broke_early = true
						break pass1_range_loop
					}

					duration := bound_duration(&ev, thread.max_time)

					key := StatKey{ev.has_addr, ev.id}
					s, ok := sm_get(&trace.stats.stat_map, key)
					if !ok {
						s = sm_insert(&trace.stats.stat_map, key, FunctionStats{min_time = max(i64), max_time = min(i64)})
					}

					s.count += 1
					s.total_time += duration
					s.self_time += ev.self_time
					s.min_time = min(s.min_time, duration)
					s.max_time = max(s.max_time, duration)
					trace.stats.total_time += duration

					event_count += 1
				}

			}

			if !broke_early {
				trace.stats.state = .Pass2
				trace.stats.cur_offset = StatOffset{}
			}
		}

		if trace.stats.state == .Pass2 {
			pass2_range_loop: for range, r_idx in trace.stats.selected_ranges {
				start_idx := range.start
				if trace.stats.cur_offset.range_idx > r_idx {
					continue
				} else if trace.stats.cur_offset.range_idx == r_idx {
					start_idx = max(start_idx, trace.stats.cur_offset.event_idx)
				}

				thread := trace.processes[range.pid].threads[range.tid]
				events := thread.depths[range.did].events[start_idx:range.end]

				for &ev, e_idx in events {
					if event_count > iter_max {
						trace.stats.cur_offset = StatOffset{r_idx, start_idx + e_idx}
						broke_early = true
						break pass2_range_loop
					}

					duration := bound_duration(&ev, thread.max_time)
					key := StatKey{ev.has_addr, ev.id}
					s, _ := sm_get(&trace.stats.stat_map, key)

					idx: u32
					if (s.max_time - s.min_time <= 0) {
						idx = 50
					} else {
						t := f64(duration - s.min_time) / f64(s.max_time - s.min_time)
						t = min(1, max(t, 0))
						t *= 99
						idx = u32(t)
					}

					s.hist[idx] += 1
					event_count += 1
				}
			}

			if !broke_early {
				for i := 0; i < len(trace.stats.stat_map.entries); i += 1 {
					stat := &trace.stats.stat_map.entries[i].val
					stat.avg_time = f64(stat.total_time) / f64(stat.count)
				}

				self_sort :: proc(a, b: StatEntry) -> bool {
					return a.val.self_time > b.val.self_time
				}
				sm_sort(&trace.stats.stat_map, self_sort)
				trace.stats.state = .Finished
			}
		}
	}
}

draw_errorbox :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect

	msg_width := measure_text(trace.error_message, .PSize, .DefaultFont)
	msg_height := em

	error_rect := inner_flamegraph_rect
	error_rect.w = min(msg_width  + (2 * em), inner_flamegraph_rect.w)
	error_rect.h = min(msg_height + (2 * em),  inner_flamegraph_rect.h)
	error_rect.x = (inner_flamegraph_rect.x + inner_flamegraph_rect.w) - error_rect.w

	draw_rect(gfx, error_rect, error_color)
	draw_text(gfx, trace.error_message, Vec2{(error_rect.x + (error_rect.w / 2)) - (msg_width / 2), (error_rect.y + (error_rect.h / 2)) - (msg_height / 2)}, .PSize, .DefaultFont, text_color)
}

draw_trace_view :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState, dt: f64) {
		rect_tooltip_rect = empty_event
		rect_tooltip_pos = Vec2{}
		rendered_rect_tooltip = false

		if !event_cmp(trace.zoom_event, empty_event) {
			ev := get_event(trace, trace.zoom_event)
			thread := trace.processes[trace.zoom_event.pid].threads[trace.zoom_event.tid]
			duration := bound_duration(ev, thread.max_time)

			set_flamegraph_camera(trace, ui_state, ev.timestamp, duration)
			trace.zoom_event = empty_event
		}

		// update animation timers
		greyanim_t = f32((t - multiselect_t) * 5)
		greymotion = ease_in_out(greyanim_t)

		defer {
			trace.stats.released_event = empty_event
		}

		// process key/mouse inputs
		if clicked {
			did_pan = false
			trace.stats.pressed_event = empty_event // so no stale events are tracked
		}
		start_time, end_time, pan_delta := process_inputs(trace, dt, ui_state)

		clicked_on_rect = false
		rect_count = 0
		bucket_count = 0

		draw_flamegraphs(gfx, trace, start_time, end_time, ui_state)
		draw_minimap(gfx, trace, ui_state)
		draw_topbars(gfx, trace, start_time, end_time, ui_state)

		// draw sidelines
		draw_line(gfx, Vec2{ui_state.side_pad, ui_state.header_rect.h + ui_state.global_timebar_rect.h},       Vec2{ui_state.side_pad, ui_state.info_pane_rect.y}, 1, line_color)
		draw_line(gfx, Vec2{ui_state.minimap_rect.x, ui_state.header_rect.h + ui_state.global_timebar_rect.h}, Vec2{ui_state.minimap_rect.x, ui_state.info_pane_rect.y}, 1, line_color)

		process_multiselect(gfx, trace, pan_delta, dt, ui_state)
		process_stats(trace, ui_state)

		draw_stats(gfx, trace, ui_state)
		trace.stats.just_started = false
		if resort_stats {
			sort_stats(trace)
			resort_stats = false
		}

		draw_header(gfx, trace, ui_state)

		if enable_debug {
			draw_debug(gfx, ui_state)
		}

		// if there's a rectangle tooltip to render, now's the time.
		if rendered_rect_tooltip {
			draw_rect_tooltip(gfx, trace, ui_state)
		}

		if trace.error_message != "" {
			draw_errorbox(gfx, trace, ui_state)
		}
}

draw_textbox :: proc(gfx: ^GFX_Context, pos: Rect, hint_text: string, state: ^TextboxState) {
	p_height  := get_text_height(.PSize, .MonoFont)

	if pt_in_rect(mouse_pos, pos) {
		set_cursor(gfx, "text")
		if clicked {
			state.focus = true
		}
	} else if clicked {
		state.focus = false
	}

	draw_rect(gfx, pos, bg_color)

	box_outline_color := outline_color
	if state.focus {
		box_outline_color = toolbar_color
	}
	draw_rect_outline(gfx, pos, 1,  box_outline_color)

	text_x := pos.x + (em / 2)
	text_y := pos.y + (pos.h / 2) - (p_height / 2)

	cur_str := strings.to_string(state.b)
	if strings.builder_len(state.b) == 0 {
		draw_text(gfx, hint_text, Vec2{text_x, text_y}, .PSize, .MonoFont, hint_text_color)
	} else {
		draw_text(gfx, cur_str, Vec2{text_x, text_y}, .PSize, .MonoFont, text_color)
	}

	// Draw cursor
	if state.focus {
		b := strings.builder_make(context.temp_allocator)
		for r, idx in cur_str {
			if idx >= state.cursor {
				break
			} else {
				strings.write_rune(&b, r)
			}
		}
		cursor_pos := measure_text(strings.to_string(b), .PSize, .MonoFont)
		draw_line(gfx, Vec2{text_x + cursor_pos, text_y}, Vec2{text_x + cursor_pos, text_y + p_height}, 1, text_color)
	}
}

draw_main_menu :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState, dt: f64) {
	draw_reduced_header(gfx, trace, ui_state)

	menu_rect := Rect{0, ui_state.header_rect.h, ui_state.width, ui_state.height - ui_state.header_rect.h}
	draw_rect(gfx, menu_rect, bg_color)

	p_height  := get_text_height(.PSize, .DefaultFont)
	h1_height := get_text_height(.H1Size, .DefaultFont)

	line_x := menu_rect.w / 3
	line_y := (menu_rect.h / 3) + menu_rect.y
	draw_text(gfx, "Run", Vec2{line_x, next_line(&line_y, p_height)}, .H1Size, .DefaultFont, text_color)
	draw_text(gfx, "Launch and sample a program", Vec2{line_x, next_line(&line_y, h1_height)}, .PSize, .DefaultFont, subtext_color)

	form_w := 30 * em
	form_h := em + p_height
	program_input_box := &ui_state.textboxes[.ProgramInput]
	draw_textbox(gfx, Rect{line_x, line_y, form_w, form_h}, "Path to Program...", program_input_box)

	edge_pad := 1 * em
	button_height := 2 * em
	button_width  := 2 * em
	program_select_rect := Rect{line_x + form_w + edge_pad, next_line(&line_y, form_h), button_height, button_width}
	if button(gfx, program_select_rect, "\uf15b", "select program", .IconFont, menu_rect.x, menu_rect.w) {
		filename, ok := open_file_dialog()
		if ok {
			strings.builder_reset(&program_input_box.b)
			strings.write_string(&program_input_box.b, filename)
			cur_str := strings.to_string(program_input_box.b)
			r_len := utf8.rune_count_in_string(cur_str)
			program_input_box.cursor = r_len
		}
	}

	path_input_box := &ui_state.textboxes[.PathInput]
	draw_textbox(gfx, Rect{line_x, next_line(&line_y, form_h), form_w, form_h}, "Path to run program...", path_input_box)

	cmdargs_input_box := &ui_state.textboxes[.CmdArgsInput]
	draw_textbox(gfx, Rect{line_x, next_line(&line_y, form_h), form_w, form_h}, "Command line arguments...", cmdargs_input_box)

	sample_button_text := "Start"
	sample_button_width := measure_text(sample_button_text, .PSize, .DefaultFont) + em
	full_form_w := form_w + edge_pad + button_width
	start_sample_rect := Rect{line_x + (full_form_w / 2) - (sample_button_width / 2), line_y, sample_button_width, p_height + (em / 2)}
	if button(gfx, start_sample_rect, sample_button_text, "", .DefaultFont, menu_rect.x, menu_rect.w) {
		program_name := strings.to_string(program_input_box.b)
		program_path := strings.to_string(path_input_box.b)
		program_args := strings.to_string(cmdargs_input_box.b)

		start_sampling(&loader, trace, ui_state, program_name, program_path, program_args)
	}
}

post_load_cleanup :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState) {
	if trace.event_count == 0 { trace.total_min_time = 0; trace.total_max_time = 1000 }
	ui_state.multiselecting = false
	reset_flamegraph_camera(trace, ui_state)

	if trace.file_name != "" {
		name := fmt.ctprintf("%s - spall beta 0.5", trace.base_name)
		set_window_title(gfx, name)
	}
	ui_state.post_loading = false
	ui_state.ui_mode = .TraceView
}

draw_trace_loading :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState, dt: f64) {
	offset := trace.parser.offset
	size := trace.total_size

	pad_size : f64 = 4
	chunk_size : f64 = 10

	load_box := Rect{0, 0, 100, 100}
	load_box = Rect{
		(ui_state.width / 2) - (load_box.w / 2) - pad_size,
		(ui_state.height / 2) - (load_box.h / 2) - pad_size,
		load_box.w + pad_size,
		load_box.h + pad_size,
	}

	draw_rect(gfx, load_box, BVec4{30, 30, 30, 255})
	chunk_count := int(rescale(f64(offset), 0, f64(size), 0, 100))

	chunk := Rect{0, 0, chunk_size, chunk_size}
	start_x := load_box.x + pad_size
	start_y := load_box.y + pad_size
	for i := chunk_count; i >= 0; i -= 1 {
		cur_x := f64(i %% int(chunk_size))
		cur_y := f64(i /  int(chunk_size))
		draw_rect(gfx, Rect{
			start_x + (cur_x * chunk_size),
			start_y + (cur_y * chunk_size),
			chunk_size - pad_size,
			chunk_size - pad_size,
		}, loading_block_color)
	}

	ui_state.render_one_more = true
	
	if ui_state.post_loading {
		post_load_cleanup(gfx, trace, ui_state)
	}
}

draw_sample_running :: proc(gfx: ^GFX_Context, trace: ^Trace, ui_state: ^UIState, dt: f64) {
	p_height  := get_text_height(.PSize, .DefaultFont)
	h1_height := get_text_height(.H1Size, .DefaultFont)

	menu_rect := Rect{0, 0, ui_state.width, ui_state.height}
	draw_rect(gfx, menu_rect, bg_color)

	if !trace.requested_stop {
		edge_pad := 1 * em
		button_height := 2 * em
		sample_button_text := "Stop"
		sample_button_width := measure_text(sample_button_text, .PSize, .DefaultFont) + edge_pad

		total_duration := time.tick_since(trace.load_kickoff)
		time_text := fmt.tprintf("Sampling for %.1f s", time.duration_seconds(total_duration))
		time_width := measure_text(time_text, .PSize, .DefaultFont)
		draw_text(gfx, time_text, Vec2{(ui_state.width / 2) - (time_width / 2), (ui_state.height / 2) - (p_height / 2)}, .PSize, .DefaultFont, text_color)
		line_y := (ui_state.height / 2) + (p_height / 2) + (2 * em)

		stop_sample_rect := Rect{(ui_state.width / 2) - (sample_button_width / 2), line_y - (button_height / 2), sample_button_width, p_height + (edge_pad / 2)}
		if button(gfx, stop_sample_rect, sample_button_text, "", .DefaultFont, menu_rect.x, menu_rect.w) {
			trace.requested_stop = true
		}
	} else {
		stop_text := "Stopping Sampling..."
		stop_width := measure_text(stop_text, .PSize, .DefaultFont)
		draw_text(gfx, stop_text, Vec2{(ui_state.width / 2) - (stop_width / 2), (ui_state.height / 2) - (p_height / 2)}, .PSize, .DefaultFont, text_color)
	}

	ui_state.render_one_more = true
	
	if ui_state.post_loading {
		post_load_cleanup(gfx, trace, ui_state)
	}
}
