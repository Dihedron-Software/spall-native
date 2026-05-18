package main

import "base:runtime"

import "core:os"
import "core:io"
import "core:fmt"
import "core:slice"
import "core:bytes"
import "core:time"
import "core:path/filepath"
import "core:mem"
import "core:strings"
import "core:container/lru"

import "formats:spall_fmt"

FileType :: enum {
	Invalid,
	Json,
	ManualStreamV1,
	ManualStreamV2,
	AutoStream,
}

Parser :: struct {
	pos: i64,
	offset: i64,
}

ThreadFileLoadState :: struct {
	filename: string,
	trace: ^Trace,
	ui_state: ^UIState,
}

threaded_trace_load :: proc(loader: ^Loader, data: rawptr) {
	state := cast(^ThreadFileLoadState)(data)

	trace := state.trace
	filename := state.filename
	ui_state := state.ui_state
	free(state)

	trace.load_kickoff = time.tick_now()
	parse_start    := time.tick_now()
	load_spall_file(loader, trace, filename)
	parse_duration := time.tick_since(parse_start)

	fmt.printf("trace load took: %f ms, got %s events\n", time.duration_milliseconds(parse_duration), tens_fmt(u64(trace.event_count)))
	fmt.printf("trace length: %s\n", time_fmt(disp_time(trace, f64(trace.total_max_time - trace.total_min_time))))

	pool_wait(&loader.pool)
	free_trace_temps(trace)

	total_duration := time.tick_since(trace.load_kickoff)
	fmt.printf("full load took: %f ms\n", time.duration_milliseconds(total_duration))

	ui_state.loading_config = false
	ui_state.post_loading = true
}

load_trace :: proc(loader: ^Loader, trace: ^Trace, ui_state: ^UIState, trace_name: string) -> (ok: bool) {
	if ui_state.loading_config || trace_name == "" {
		return false
	}

	free_trace(trace)
	init_trace(trace)
	ui_state.loading_config = true
	ui_state.post_loading = false
	ui_state.ui_mode = .TraceLoading

	state := new(ThreadFileLoadState)
	state^ = ThreadFileLoadState{
		filename = trace_name,
		trace = trace,
		ui_state = ui_state,
	}

	loader_set_task(loader, Loader_Task{threaded_trace_load, state})
	return true
}

real_pos :: proc(p: ^Parser) -> i64 { return p.pos }
chunk_pos :: proc(p: ^Parser) -> i64 { return p.pos - p.offset }

read_at_partial :: proc(fd: ^os.File, buf: []u8, offset: i64) -> (int, bool) {
	rd_sz, err := os.read_at(fd, buf, offset)
	if err != nil {
		if v, is_io := err.(io.Error); is_io && (v == .EOF || v == .Unexpected_EOF) {
			return rd_sz, true
		}
		return rd_sz, false
	}
	return rd_sz, true
}

get_chunk :: proc(p: ^Parser, fd: ^os.File, chunk_buffer: []u8) -> (int, bool) {
	return read_at_partial(fd, chunk_buffer, p.pos)
}

setup_pid :: proc(trace: ^Trace, process_id: u32) -> int {
	p_idx, ok := vh_find(&trace.process_map, process_id)
	if !ok {
		non_zero_append(&trace.processes, init_process(process_id))

		p_idx = len(trace.processes) - 1
		vh_insert(&trace.process_map, process_id, p_idx)
	}

	return p_idx
}

setup_tid :: proc(trace: ^Trace, p_idx: int, thread_id: u32) -> int {
	t_idx, ok := vh_find(&trace.processes[p_idx].thread_map, thread_id)
	if !ok {
		threads := &trace.processes[p_idx].threads
		thread_map := &trace.processes[p_idx].thread_map
		non_zero_append(threads, init_thread(thread_id))

		t_idx = len(threads) - 1
		vh_insert(thread_map, thread_id, t_idx)
	}

	return t_idx
}

free_trace_temps :: proc(trace: ^Trace) {
	for &process in trace.processes {
		for &thread in process.threads {
			stack_free(&thread.bande_q)
		}
		vh_free(&process.thread_map)
	}
	vh_free(&trace.process_map)
}

free_trace :: proc(trace: ^Trace) {
	for &process in trace.processes {
		for &thread in process.threads {
			free_thread(&thread)
		}
		free_process(&process)
	}
	delete(trace.processes)
	delete(trace.string_block)
	delete(trace.file_name)
	strings.intern_destroy(&trace.filename_map)

	delete(trace.stats.selected_ranges)
	sm_free(&trace.stats.stat_map)
	in_free(&trace.intern)

	for &bucket in trace.func_buckets {
		delete(bucket.functions)
		delete(bucket.line_info)
	}
	delete(trace.func_buckets)

	lru.destroy(&trace.func_lookup_cache, false)
}

bound_duration :: proc(ev: ^Event, max_ts: i64) -> i64 {
	return ev.duration < 0 ? (max_ts - ev.timestamp) : ev.duration
}

find_idx :: proc(trace: ^Trace, events: []Event, val: i64) -> int {
	low := 0
	max := len(events)
	high := max - 1

	for low < high {
		mid := (low + high) / 2

		ev := events[mid]
		ev_start := ev.timestamp - trace.total_min_time
		ev_end := ev_start + ev.duration

		if (val >= ev_start && val <= ev_end) {
			return mid
		} else if ev_start < val && ev_end < val { 
			low = mid + 1
		} else { 
			high = mid - 1
		}
	}

	return low
}

add_event :: proc(events: ^[dynamic]Event, loc := #caller_location) -> ^Event {
	if cap(events) < len(events)+1 {
		cap := 3 * cap(events) + max(8, 1)
		_ = non_zero_reserve(events, cap, loc)
	}

	a := (^runtime.Raw_Dynamic_Array)(events)
	data := ([^]Event)(a.data)
	ev := &data[a.len]
	a.len += 1

	return ev
}

append_event :: proc(events: ^[dynamic]Event, ev: ^Event, loc := #caller_location) {
	if cap(events) < len(events)+1 {
		cap := 2 * cap(events) + max(8, 1)
		_ = non_zero_reserve(events, cap, loc)
	}

	a := (^runtime.Raw_Dynamic_Array)(events)
	data := ([^]Event)(a.data)
	data[a.len] = ev^
	a.len += 1

	return
}

get_top_two :: proc(weights: []i64) -> (WeightIdx, WeightIdx) {
	largest := WeightIdx{}
	second_largest := WeightIdx{}
	for weight, idx in weights {
		if weight > largest.weight {
			second_largest = largest
			largest = WeightIdx{idx = u8(idx), weight = weight}
		} else if weight < largest.weight && weight > second_largest.weight {
			second_largest = WeightIdx{idx = u8(idx), weight = weight}
		}
	}

	return largest, second_largest
}

gen_event_color :: proc(trace: ^Trace, _events: []Event, thread_max: i64, node: ^ChunkNode) {
	total_weight : i64 = 0

	events := _events

	if len(events) == 1 {
		ev := &events[0]
		duration := bound_duration(ev, thread_max)
		name := ev_name(trace, ev)

		// if the event was started with no end, *right* as the trace quit, we'll get a duration of 0
		// make this 1 so it has *some* LOD contribution
		node.total_weight = max(duration, 1)
		node.p[0] = WeightIdx{idx = u8(name_color_idx(name)), weight = node.total_weight}
		return
	}

	color_weights := [COLOR_CHOICES]i64{}
	for &ev in events {
		name := ev_name(trace, &ev)
		idx := name_color_idx(name)
		duration := bound_duration(&ev, thread_max)

		color_weights[idx] += duration
		total_weight += duration
	}

	w1, w2 := get_top_two(color_weights[:])

	node.p[0] = w1
	node.p[1] = w2
	node.total_weight = total_weight
}

print_tree :: proc(depth: ^Depth) {
	fmt.printf("mah tree!\n")
	// If we blow this, we're in space
	tree_stack := [128]int{}
	stack_len := 0
	pad_buf := [?]u8{0..<64 = '\t',}

	tree_stack[0] = 0; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := &depth.tree[tree_idx]

		fmt.printf("%d | start: %v, end: %v, weight: %v\n", tree_idx, cur_node.start_time, cur_node.end_time, cur_node.total_weight)

		if tree_idx > (len(depth.tree) - depth.leaf_count - 1) {
			continue
		}

		start_idx := (CHUNK_NARY_WIDTH * tree_idx) + 1
		end_idx := min(start_idx + CHUNK_NARY_WIDTH - 1, len(depth.tree) - 1)
		child_count := end_idx - start_idx
		for i := child_count; i >= 0; i -= 1 {
			tree_stack[stack_len] = start_idx + i; stack_len += 1
		}
	}
	fmt.printf("ded!\n")
}

chunk_events :: proc(trace: ^Trace) {
	lod_mem_usage := 0
	ev_mem_usage := 0

	// using an eytzinger LOD tree for each depth array
	for &proc_v, p_idx in trace.processes {
		for &tm, t_idx in proc_v.threads {
			//fmt.printf("stepped thread\n")
			for &depth, d_idx in tm.depths {
				//fmt.printf("stepped depth\n")
				leaf_count := i_round_up(len(depth.events), BUCKET_SIZE) / BUCKET_SIZE
				depth.leaf_count = leaf_count

				width := CHUNK_NARY_WIDTH - 1
				internal_node_count := i_round_up((leaf_count - 1), width) / width
				total_node_count := internal_node_count + leaf_count

				tm.depths[d_idx].tree = make([]ChunkNode, total_node_count)

				lod_mem_usage += size_of(ChunkNode) * total_node_count
				ev_mem_usage += size_of(Event) * len(depth.events)

				tree := tm.depths[d_idx].tree
				tree_start_idx := len(tree) - leaf_count

				cur_node := 0
				overhang_idx := 0
				prehang_rank := 0
				for ; cur_node < total_node_count; {
					overhang_idx = cur_node
					cur_node = (CHUNK_NARY_WIDTH * cur_node) + 1

					prehang_rank += 1
				}

				posthang_rank := 1
				tmp_idx := len(tree) - leaf_count
				for ; tmp_idx > 0; {
					tmp_idx = (tmp_idx - 1) / CHUNK_NARY_WIDTH
					posthang_rank += 1
				}

				_tmp := 1
				for _tmp < leaf_count {
					_tmp = _tmp * CHUNK_NARY_WIDTH
				}
				depth.full_leaves = _tmp

				overhang_len := len(tree) - overhang_idx
				if prehang_rank == posthang_rank {
					overhang_len = 0
				}
				depth.overhang_len = overhang_len

				//fmt.printf("walking %v overhang events\n", overhang_len)
				for i := 0; i < overhang_len; i += 1 {
					start_idx := i * BUCKET_SIZE
					end_idx := start_idx + min(len(depth.events) - start_idx, BUCKET_SIZE)
					scan_arr := depth.events[start_idx:end_idx]

					start_ev := &scan_arr[0]
					end_ev := &scan_arr[len(scan_arr)-1]
					tree_idx := overhang_idx + i

					node := &tree[tree_idx]
					node.start_time = start_ev.timestamp - trace.total_min_time
					node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - trace.total_min_time
					gen_event_color(trace, scan_arr, tm.max_time, node)

				}

				previous_len := leaf_count - overhang_len
				ev_offset := overhang_len * BUCKET_SIZE
				//fmt.printf("walking %v previous events\n", previous_len)
				for i := 0; i < previous_len; i += 1 {
					start_idx := (i * BUCKET_SIZE) + ev_offset
					end_idx := start_idx + min(len(depth.events) - start_idx, BUCKET_SIZE)
					scan_arr := depth.events[start_idx:end_idx]

					start_ev := &scan_arr[0]
					end_ev := &scan_arr[len(scan_arr)-1]
					tree_idx := tree_start_idx + i

					node := &tree[tree_idx]
					node.start_time = start_ev.timestamp - trace.total_min_time
					node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - trace.total_min_time
					gen_event_color(trace, scan_arr, tm.max_time, node)
				}

				//fmt.printf("blending colors for %v nodes\n", tree_start_idx - 1)
				for i := tree_start_idx - 1; i >= 0; i -= 1 {
					node := &tree[i]

					start_idx := (CHUNK_NARY_WIDTH * i) + 1
					end_idx := min(start_idx + (CHUNK_NARY_WIDTH - 1), len(tree) - 1)

					node.start_time = tree[start_idx].start_time
					node.end_time   = tree[end_idx].end_time

					color_weights := [COLOR_CHOICES]i64{}
					children := tree[start_idx:end_idx]
					for child in children {
						node.total_weight += child.total_weight
						for wi in child.p {
							color_weights[wi.idx] += wi.weight
						}
					}
					w1, w2 := get_top_two(color_weights[:])
					node.p[0] = w1
					node.p[1] = w2
				}
			}
		}
	}

	fmt.printf("LOD memory: %M | Event memory: %M\n", lod_mem_usage, ev_mem_usage)
}

get_left_child :: #force_inline proc(idx: int) -> int {
	return (CHUNK_NARY_WIDTH * idx) + 1
}
get_child_count :: proc(depth: ^Depth, idx: int) -> int {
	start_idx := get_left_child(idx)
	end_idx := min(start_idx + CHUNK_NARY_WIDTH - 1, len(depth.tree) - 1)
	child_count := end_idx - start_idx + 1

	return child_count
}

linearize_leaf :: proc(depth: ^Depth, idx: int, loc := #caller_location) -> int {
	overhang_start := len(depth.tree) - depth.overhang_len
	leaf_start := len(depth.tree) - depth.leaf_count

	ret := 0
	if depth.overhang_len == 0 {
		ret = idx - leaf_start
	} else if idx >= overhang_start {
		ret = idx - overhang_start
	} else {
		ret = (idx - leaf_start) + depth.overhang_len
	}
	return ret
}

// This *must* take a leaf idx
get_event_count :: proc(depth: ^Depth, idx: int) -> int {
	linear_idx := linearize_leaf(depth, idx)

	ret := BUCKET_SIZE
	// if we're the last index in the tree, determine the leftover
	if linear_idx == (depth.leaf_count - 1) {
		ret = len(depth.events) % BUCKET_SIZE


		// If we fall exactly in the bucket?
		if ret == 0 {
			ret = BUCKET_SIZE
		}
	}

	return ret
}
// This *must* take a leaf idx
get_event_start_idx :: proc(depth: ^Depth, idx: int) -> int {
	linear_idx := linearize_leaf(depth, idx)
	return linear_idx * BUCKET_SIZE
}

is_leaf :: proc(depth: ^Depth, idx: int) -> bool {
	ret := idx >= (len(depth.tree) - depth.leaf_count)
	return ret
}

get_left_leaf :: proc(depth: ^Depth, idx: int) -> int {
	tmp_idx := idx
	last_tmp := idx
	for tmp_idx < len(depth.tree) {
		last_tmp = tmp_idx
		tmp_idx = (CHUNK_NARY_WIDTH * tmp_idx) + 1
	}
	return last_tmp
}
get_right_leaf :: proc(depth: ^Depth, idx: int) -> int {
	if is_leaf(depth, idx) {
		return idx
	}

	full_internal_nodes := depth.full_leaves / (CHUNK_NARY_WIDTH - 1)
	full_tree_count := full_internal_nodes + depth.full_leaves

	internal_nodes := depth.leaf_count / (CHUNK_NARY_WIDTH - 1)
	total_tree_count := internal_nodes + depth.leaf_count

	prev_leaves := depth.full_leaves / CHUNK_NARY_WIDTH

	tmp_idx := idx
	last_tmp := idx
	for tmp_idx < len(depth.tree) {
		last_tmp = tmp_idx
		tmp_idx = (CHUNK_NARY_WIDTH * tmp_idx) + CHUNK_NARY_WIDTH
	}

	ret := last_tmp
	edge_case_count := total_tree_count + CHUNK_NARY_WIDTH - 1
	if edge_case_count >= full_tree_count {
		ret = len(depth.tree) - 1
	}
	return ret
}

get_event_range :: proc(depth: ^Depth, idx: int) -> (int, int) {
	left_idx := get_left_leaf(depth, idx)
	right_idx := get_right_leaf(depth, idx)
	event_start_idx := get_event_start_idx(depth, left_idx)
	event_count := get_event_count(depth, right_idx)

	linear_right_leaf := linearize_leaf(depth, right_idx)
	linear_left_leaf := linearize_leaf(depth, left_idx)
	leaf_count := linear_right_leaf - linear_left_leaf
	ev_count := (leaf_count * BUCKET_SIZE) + event_count

	start := event_start_idx
	end := event_start_idx + ev_count
	return start, end
}

pid_sort_proc :: proc(a, b: Process) -> bool { return a.min_time < b.min_time }
tid_sort_proc :: proc(a, b: Thread) -> bool  { return a.min_time < b.min_time }

new_func_bucket :: proc(buckets: ^[dynamic]Func_Bucket, path: string, base_addr: u64) -> ^Func_Bucket {
	append(buckets,
		Func_Bucket{
			source_path = path,
			base_address = base_addr,
			functions = make([dynamic]Function),
			scopes = Scope{
				func_idx = max(u64),
				low_pc = max(u64),
				high_pc = min(u64),
				children = make([dynamic]Scope),
			},
		},
	)

	return &buckets[len(buckets)-1]
}

Load_Symbols_Args :: struct {
	trace: ^Trace,
	base_addr: u64,
	path:  string,
}
load_symbols_task :: proc(pool: ^Pool, raw_args: rawptr) {
	args := cast(^Load_Symbols_Args)(raw_args)
	load_executable(args.trace, args.path, args.base_addr)
}

load_executable :: proc(trace: ^Trace, file_name: string, base_addr: u64) -> bool {
	fmt.printf("Loading symbols from %s\n", file_name)

	exec_buffer, read_err := os.read_entire_file(file_name, context.allocator)
	if read_err != nil {
		post_error(trace, "Failed to load symbols from %s!", file_name)
		return false
	}
	defer delete(exec_buffer)

	if len(exec_buffer) < 4 {
		post_error(trace, "Invalid executable file!")
		return false
	}
	
	bucket := new_func_bucket(&trace.func_buckets, file_name, base_addr)

	magic_chunk := (^u32)(raw_data(exec_buffer[:4]))^
	if bytes.equal(exec_buffer[:4], ELF_MAGIC) {
		ok := load_elf(trace, exec_buffer, bucket)
		if !ok {
			post_error(trace, "Failed to parse ELF!")
			return false
		}
	} else if magic_chunk == MACH_MAGIC_64 {

		ok := load_macho_symbols(trace, exec_buffer, bucket)
		if !ok {
			post_error(trace, "Failed to parse Mach-O!")
			return false
		}

		debug_file_name := guess_debug_path(file_name)
		debug_buffer, read_err2 := os.read_entire_file(debug_file_name, context.allocator)
		if read_err2 != nil {
			post_error(trace, "No debug info found!")
			return false
		}
		defer delete(debug_buffer)

		fmt.printf("loading debug info from %s\n", debug_file_name)
		load_macho_debug(trace, debug_buffer, bucket)
	} else if bytes.equal(exec_buffer[:2], DOS_MAGIC) {
		ok := load_pe32(trace, exec_buffer, bucket)
		if !ok {
			post_error(trace, "Failed to parse PE32!")
			return false
		}
	} else {
		post_error(trace, "Unsupported executable type! %x", exec_buffer[:4])
		return false
	}

	fmt.printf("Loaded %s function entries!\n", tens_fmt(u64(len(bucket.functions))))

	return true
}

init_trace_allocs :: proc(trace: ^Trace, file_name: string) {
	trace.processes    = make([dynamic]Process)
	trace.process_map  = vh_init()
	trace.string_block = make([dynamic]string)
	trace.intern       = in_init()
	trace.func_buckets = make([dynamic]Func_Bucket)

	trace.stats.selected_ranges = make([dynamic]Range)
	trace.stats.stat_map        = sm_init()

	trace.base_name = filepath.base(file_name)
	trace.file_name = file_name

	strings.intern_init(&trace.filename_map)
	non_zero_append(&trace.string_block, "")

	lru.init(&trace.func_lookup_cache, 4096)
}

init_trace :: proc(trace: ^Trace) {
	trace^ = Trace{
		total_max_time = min(i64),
		total_min_time = max(i64),

		event_count = 0,
		stamp_scale = 1,

		zoom_event = empty_event,
		stats = Stats{
			state           = .NoStats,
			just_started    = false,

			selected_func   = {},
			selected_event  = empty_event,
			pressed_event   = empty_event,
			released_event  = empty_event,
		},

		parser = Parser{},
		error_message = "",
	}
}

load_spall_file :: proc(loader: ^Loader, trace: ^Trace, file_name: string) {
	start_time := time.tick_now()

	init_trace_allocs(trace, file_name)

	trace_fd, err := os.open(file_name)
	if err != nil {
		post_error(trace, "%s not found!", file_name)
		return
	}
	defer os.close(trace_fd)

	total_size, err2 := os.file_size(trace_fd)
	if err2 != nil {
		post_error(trace, "unable to get file size!")
		return
	}
	if total_size == 0 {
		post_error(trace, "%s is empty!", file_name)
		return
	}
	trace.total_size = total_size
	fmt.printf("Loading %s, %M\n", trace.base_name, trace.total_size)

	header_buffer := [0x4000]u8{}
	_, read_ok := read_at_partial(trace_fd, header_buffer[:], 0)
	if !read_ok {
		post_error(trace, "Unable to read %s!", file_name)
		return
	}

	magic, ok := slice_to_type(header_buffer[:], u64)
	if !ok {
		post_error(trace, "File %s too small to be valid!", file_name)
		return
	}

	header_size : i64 = 0
	file_type: FileType
	if magic == spall_fmt.MANUAL_MAGIC {
		hdr, ok := slice_to_type(header_buffer[:], spall_fmt.Manual_Header)
		if !ok {
			post_error(trace, "%s is invalid!", file_name)
			return
		}

		if hdr.version != 1 && hdr.version != 3 {
			post_error(trace, "Spall version %d for %s is invalid!", hdr.version, file_name)
			return
		}
		
		trace.stamp_scale = hdr.timestamp_unit
		header_size = size_of(spall_fmt.Manual_Header)

		if hdr.version == 1 { 
			file_type = .ManualStreamV1 
			trace.stamp_scale *= 1000
		} else if hdr.version == 3 {
			file_type = .ManualStreamV2
		}

	} else if magic == spall_fmt.AUTO_MAGIC {
		hdr, ok := slice_to_type(header_buffer[:], spall_fmt.Auto_Header)
		if !ok {
			post_error(trace, "%s is invalid!", file_name)
			return
		}

        if hdr.version < 3 {
			post_error(trace, "Support for auto-tracing v%d has been dropped in this version, please grab the new header!", hdr.version)
			return
        }
		if hdr.version != 3 {
			post_error(trace, "Spall version %d for %s is invalid!", hdr.version, file_name)
			return
		}
		if total_size < i64(size_of(spall_fmt.Auto_Header)) + i64(hdr.program_path_len) {
			post_error(trace, "%s is invalid!", file_name)
			return
		}
		
		trace.stamp_scale = hdr.timestamp_unit
		fmt.printf("Base address of executable: 0x%08x\n", hdr.base_address)

		path_buffer := header_buffer[size_of(spall_fmt.Auto_Header):][:hdr.program_path_len]
		symbol_path := string(path_buffer)
		if (opt.exe_path != "") {
			symbol_path = opt.exe_path
		}
		header_size = size_of(spall_fmt.Auto_Header) + i64(hdr.program_path_len)

		sym_args := new(Load_Symbols_Args)
		sym_args.trace = trace
		sym_args.base_addr = hdr.base_address
		sym_args.path = symbol_path

		pool_add_task(&loader.pool, Pool_Task{load_symbols_task, sym_args})

		file_type = .AutoStream
	} else {
		leading_char := header_buffer[0]
		if leading_char == ' '  || leading_char == '\n' ||
		   leading_char == '\r' || leading_char == '\t' ||
		   leading_char == '{'  || leading_char == '[' {
			file_type = .Json
		} else {
			file_type = .Invalid
			post_error(trace, "%s is an unsupported file type!", file_name)
		}
	}

	fmt.printf("Loading trace with %v format!\n", file_type)

	p := &trace.parser
	p.pos += i64(header_size)

	parsed_properly := false
	#partial switch file_type {
	case .ManualStreamV1:
		parsed_properly = ms_v1_parse(trace, trace_fd, header_size)
	case .ManualStreamV2:
		parsed_properly = ms_v2_parse(trace, trace_fd, header_size)
	case .AutoStream:
		parsed_properly = as_parse(trace, trace_fd, header_size)
	case .Json:
		parsed_properly = json_parse(trace, trace_fd)
	}

	if parsed_properly && (p.pos == i64(header_size) || trace.event_count == 0) {
		parsed_properly = false
		post_error(trace, "Trace is empty, did you remember to quit your threads and enable -finstrument-functions?")
	}

	if !parsed_properly {
		pool_wait(&loader.pool)

		free_trace_temps(trace)
		error_temp := trace.error_storage
		error_str_len := len(trace.error_message)

		free_trace(trace)

		init_trace(trace)
		trace.error_storage = error_temp
		trace.error_message = string(trace.error_storage[:error_str_len])
		return
	}

	#partial switch file_type {
	case .ManualStreamV1: fallthrough
	case .ManualStreamV2: fallthrough
	case .AutoStream:
		for process in &trace.processes {
			slice.sort_by(process.threads[:], tid_sort_proc)
		}
		slice.sort_by(trace.processes[:], pid_sort_proc)
		slice.sort_by(trace.global_instants[:], instant_rendersort_proc)
	case .Json:
		json_process_events(trace)
	}
	fmt.printf("parse config -- %f ms\n", time.duration_milliseconds(time.tick_since(start_time)))
	
	generate_color_choices(trace, false)

	start_time = time.tick_now()
	chunk_events(trace)
	fmt.printf("generate spatial partitions -- %f ms\n", time.duration_milliseconds(time.tick_since(start_time)))

	if file_type == .Json {
		start_time = time.tick_now()

		json_generate_selftimes(trace)
		trace.stamp_scale = 1

		fmt.printf("generate selftimes -- %f ms\n", time.duration_milliseconds(time.tick_since(start_time)))
	}
}

ev_name :: proc(trace: ^Trace, ev: ^Event) -> string {
	if !ev.has_addr {
		return in_getstr(&trace.string_block, ev.id)
	}
	name_idx, ok := get_function(trace, ev.id)
	if !ok {
		tmp_buf := make([]byte, 18, context.temp_allocator)
		return u64_to_hexstr(tmp_buf, ev.id)
	}
	return in_getstr(&trace.string_block, name_idx)
}

get_bucket :: proc(trace: ^Trace, addr: u64) -> (^Func_Bucket, bool) {
	if len(trace.func_buckets) == 0 {
		return nil, false
	}

	cur_bucket: ^Func_Bucket = nil
	for &bucket in trace.func_buckets {
		if len(bucket.functions) == 0 {
			continue
		}

		first_func := bucket.functions[0]
		last_func := bucket.functions[len(bucket.functions)-1]
		if addr >= first_func.low_pc && addr <= last_func.high_pc {
			//fmt.printf("0x%08x | [0x%08x - 0x%08x]\n", _addr, first_func.low_pc, last_func.high_pc)
			cur_bucket = &bucket
			break
		}
	}
	if cur_bucket == nil {
		return nil, false
	}

	return cur_bucket, true
}

find_next_scope :: proc(scopes: ^[dynamic]Scope, addr: u64) -> (^Scope, bool) {
	low := 0
	max := len(scopes)
	high := max - 1

	scope: ^Scope
	for low <= high {
		mid := low + (high - low) / 2

		scope = &scopes[mid]

		if addr >= scope.low_pc && addr <= scope.high_pc {
			return scope, true
		} else if addr >= scope.high_pc { 
			low = mid + 1
		} else { 
			high = mid - 1
		}
	}

	return nil, false
}

get_function :: proc(trace: ^Trace, addr: u64) -> (u64, bool) {
	name_idx, ok := lru.get(&trace.func_lookup_cache, addr)
	if ok {
		return name_idx, true
	}

	cur_bucket, ok2 := get_bucket(trace, addr)
	if !ok2 {
		return 0, false
	}

	if len(cur_bucket.functions) == 0 {
		return 0, false
	}

	low_pc := cur_bucket.scopes.low_pc
	high_pc := cur_bucket.scopes.high_pc

	// make sure address is within function bounds
	if low_pc > addr || high_pc < addr {
		return 0, false
	}

	cur_scope := &cur_bucket.scopes
	scopes_walk: for addr_in_scope(addr, cur_scope) {
		child_scope, ok := find_next_scope(&cur_scope.children, addr)
		if !ok {
			break scopes_walk
		}

		cur_scope = child_scope
	}

	if cur_scope.func_idx == max(u64) {
		return 0, false
	}

	name_idx = cur_bucket.functions[cur_scope.func_idx].name
	lru.set(&trace.func_lookup_cache, addr, name_idx)
	return name_idx, true
}

get_line_info :: proc(trace: ^Trace, addr: u64) -> (string, u64, bool) {
	cur_bucket, ok := get_bucket(trace, addr)
	if !ok {
		return "", 0, false
	}
	if len(cur_bucket.line_info) == 0 {
		return "", 0, false
	}

	line_info_start := cur_bucket.line_info[0].address
	line_info_end := cur_bucket.line_info[len(cur_bucket.line_info)-1].address

	// make sure address is within line-info bounds
	if line_info_start > addr || line_info_end < addr {
		return "", 0, false
	}

	low := 0
	max := len(cur_bucket.line_info)
	high := max - 1

	for low < high {
		mid := (low + high) / 2

		line_info := cur_bucket.line_info[mid]
		if addr == line_info.address {
			return line_info.filename, line_info.line_num, true
		} else if addr > line_info.address { 
			low = mid + 1
		} else { 
			high = mid - 1
		}
	}

	line_info := cur_bucket.line_info[low]

	if addr == line_info.address {
		return line_info.filename, line_info.line_num, true
	}

	//fmt.printf("Failed to match: 0x08%x\n", addr)
	return "", 0, false
}

add_line_info :: proc(bucket: ^Func_Bucket, addr: u64, line_num: u64, name: string) {
	line := Line_Info{address = addr, filename = name, line_num = line_num}
	non_zero_append(&bucket.line_info, line)
}

add_func :: proc(bucket: ^Func_Bucket, sym_idx: u64, in_low_pc: u64, in_high_pc: u64, text_skew: u64) {
	low_pc := (bucket.base_address + in_low_pc) - text_skew
	high_pc := (bucket.base_address + in_high_pc) - text_skew

	high_pc = max(low_pc, high_pc - 1)

	bucket.scopes.low_pc = min(bucket.scopes.low_pc, low_pc)
	bucket.scopes.high_pc = max(bucket.scopes.high_pc, high_pc)

	func := Function{name = sym_idx, low_pc = low_pc, high_pc = high_pc}
	non_zero_append(&bucket.functions, func)
}

func_order :: proc(a, b: Function) -> bool {
	if a.low_pc < b.low_pc {
		return true
	}
	if a.low_pc > b.low_pc {
		return false
	}
	if a.high_pc > b.high_pc {
		return true
	}

	return false
}

func_in_scope :: proc(f: Function, s: ^Scope) -> bool {
	return f.low_pc >= s.low_pc && f.high_pc <= s.high_pc
}

addr_in_scope :: proc(addr: u64, s: ^Scope) -> bool {
	return addr >= s.low_pc && addr <= s.high_pc
}

scope_name :: proc(trace: ^Trace, bucket: ^Func_Bucket, s: ^Scope) -> string {
	if s.func_idx == max(u64) {
		return "(scope - root)"
	}

	func := bucket.functions[s.func_idx]
	return in_getstr(&trace.string_block, func.name)
}

print_scope :: proc(trace: ^Trace, bucket: ^Func_Bucket, s: ^Scope, depth: int = 0) {
	for i := 0; i < depth; i += 1 {
		fmt.printf("    ")
	}

	fmt.printf("scope: [0x%08X -> 0x%08X] %s\n", s.low_pc, s.high_pc, scope_name(trace, bucket, s))
}

print_scope_tree :: proc(trace: ^Trace, bucket: ^Func_Bucket, s: ^Scope, depth: int = 0) {
	print_scope(trace, bucket, s, depth)

	for &child in s.children {
		print_scope_tree(trace, bucket, &child, depth + 1)
	}
}

build_scopes :: proc(trace: ^Trace, bucket: ^Func_Bucket) {
	fmt.printf("Building scopes!\n")
	if len(bucket.functions) == 0 {
		return
	}

	for func, idx in bucket.functions {
		cur_scope := &bucket.scopes

		scopes_walk: for func_in_scope(func, cur_scope) {
			child_scope: ^Scope
			child_walk: for &child, _ in cur_scope.children {
				if func_in_scope(func, &child) {
					child_scope = &child
					break child_walk
				}
			}

			if child_scope == nil {
				new_scope := Scope{func_idx = u64(idx), low_pc = func.low_pc, high_pc = func.high_pc}
				append(&cur_scope.children, new_scope)
				break scopes_walk
			} else {
				cur_scope = child_scope
			}
		}
	}

	fmt.printf("scopes built\n")
	//print_scope_tree(trace, bucket, &bucket.scopes)
}
