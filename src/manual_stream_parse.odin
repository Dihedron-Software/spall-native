package main

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:mem"
import "core:os"
import "formats:spall_fmt"

ms_v1_get_next_event :: proc(trace: ^Trace, chunk: []u8, temp_ev: ^TempEvent) -> BinaryState {
	p := &trace.parser

	header_sz := i64(size_of(u64))
	if chunk_pos(p) + header_sz > i64(len(chunk)) {
		return .PartialRead
	}

	data_start := chunk[chunk_pos(p):]
	type := (^spall_fmt.Manual_Event_Type)(raw_data(data_start))^
	#partial switch type {
	case .Begin:
		event_sz := i64(size_of(spall_fmt.Begin_Event_V1))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.Begin_Event_V1)(raw_data(data_start))

		event_tail := i64(event.name_len) + i64(event.args_len)
		if (chunk_pos(p) + event_sz + event_tail) > i64(len(chunk)) {
			return .PartialRead
		}

		name := string(data_start[event_sz:event_sz+i64(event.name_len)])
		args := string(data_start[event_sz+i64(event.name_len):event_sz+i64(event.name_len)+i64(event.args_len)])

		temp_ev.type = .Begin
		temp_ev.timestamp = i64(event.time)
		temp_ev.thread_id = event.tid
		temp_ev.process_id = event.pid
		temp_ev.id = in_get(&trace.intern, &trace.string_block, name)
		temp_ev.args = in_get(&trace.intern, &trace.string_block, args)

		p.pos += event_sz + event_tail
		return .EventRead
	case .End:
		event_sz := i64(size_of(spall_fmt.End_Event_V1))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.End_Event_V1)(raw_data(data_start))

		temp_ev.type = .End
		temp_ev.timestamp = i64(event.time)
		temp_ev.thread_id = event.tid
		temp_ev.process_id = event.pid
		
		p.pos += event_sz
		return .EventRead
	case .Pad_Skip:
		event_sz := i64(size_of(spall_fmt.Pad_Skip))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.Pad_Skip)(raw_data(data_start))

		temp_ev.type = .Pad_Skip
		p.pos += event_sz + i64(event.size)
		return .EventRead
	case:
		post_error(trace, "Invalid event type: 0x%x in file, offset: 0x%x", data_start[0], p.pos)
		return .Failure
	}

	return .PartialRead
}

ms_v1_push_event :: proc(trace: ^Trace, process_id, thread_id: u32, event: ^Event) -> (int, int, int, bool) {
	p_idx := setup_pid(trace, process_id)
	t_idx := setup_tid(trace, p_idx, thread_id)

	p := &trace.processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)
	if t.max_time > event.timestamp {
		post_error(trace, 
			"Woah, time-travel? You just had a begin event that started before a previous one; [pid: %d, tid: %d, name: %s, event: %v, event_count: %d]", 
			process_id, thread_id, in_getstr(&trace.string_block, event.id), event, trace.event_count)
		return 0, 0, 0, false
	}
	t.max_time = event.timestamp + event.duration

	trace.total_min_time = min(trace.total_min_time, event.timestamp)
	trace.total_max_time = max(trace.total_max_time, event.timestamp + event.duration)

	if int(t.current_depth) >= len(t.depths) {
		depth := Depth{
			events = make([dynamic]Event),
		}
		non_zero_append(&t.depths, depth)
	}

	depth := &t.depths[t.current_depth]
	t.current_depth += 1
	append_event(&depth.events, event)

	return p_idx, t_idx, len(depth.events)-1, true
}

ms_v1_parse :: proc(trace: ^Trace, fd: ^os.File, header_size: i64) -> bool {
	temp_ev := TempEvent{}
	ev := Event{}
	p := &trace.parser

	chunk_buffer := make([]u8, 4 * 1024 * 1024)
	defer delete(chunk_buffer)

	read_size, err := os.read_at(fd, chunk_buffer, 0)
	if err != nil {
		post_error(trace, "Unable to read file!")
		return false
	}

	last_read: i64 = 0
	full_chunk := chunk_buffer[:read_size]
	load_loop: for p.pos < trace.total_size {
		mem.zero(&temp_ev, size_of(TempEvent))
		state := ms_v1_get_next_event(trace, full_chunk, &temp_ev)
		#partial switch state {
		case .PartialRead:
			if p.pos == last_read {
				fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", p.pos, trace.total_size, trace.total_size - p.pos)
				break load_loop
			} else {
				last_read = p.pos
			}

			p.offset = p.pos

			rd_sz, ok := get_chunk(p, fd, chunk_buffer)
			if !ok {
				post_error(trace, "Failed to read file!")
				return false
			}

			full_chunk = chunk_buffer[:rd_sz]
			continue
		case .Failure:
			return false
		}

		#partial switch temp_ev.type {
		case .Begin:
			ev.id = temp_ev.id
			ev.args = temp_ev.args
			ev.duration = -1
			ev.self_time = 0
			ev.timestamp = temp_ev.timestamp

			p_idx, t_idx, e_idx, ok := ms_v1_push_event(trace, temp_ev.process_id, temp_ev.thread_id, &ev)
			if !ok {
				return false
			}

			thread := &trace.processes[p_idx].threads[t_idx]
			stack_push_back(&thread.bande_q, e_idx)
			trace.event_count += 1
		case .End:
			p_idx, ok1 := vh_find(&trace.process_map, temp_ev.process_id)
			if !ok1 {
				continue
			}

			t_idx, ok2 := vh_find(&trace.processes[p_idx].thread_map, temp_ev.thread_id)
			if !ok2 {
				continue
			}

			thread := &trace.processes[p_idx].threads[t_idx]
			if thread.bande_q.len > 0 {
				jev_idx := stack_pop_back(&thread.bande_q)
				thread.current_depth -= 1

				depth := &thread.depths[thread.current_depth]
				jev := &depth.events[jev_idx]
				jev.duration = temp_ev.timestamp - jev.timestamp
				jev.self_time = jev.duration - jev.self_time
				thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[thread.current_depth - 1]
					parent_ev_idx := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev_idx]

					pev.self_time += jev.duration
				}
			}
		}
	}

	// cleanup unfinished events
	for &process in trace.processes {
		for &thread in process.threads {
			assert(thread.bande_q.len == thread.current_depth)
			for thread.current_depth > 0 {
				jev_idx := stack_pop_back(&thread.bande_q)
				thread.current_depth -= 1
				ev_depth := thread.current_depth

				depth := &thread.depths[ev_depth]
				jev := &depth.events[jev_idx]

				thread.max_time = max(thread.max_time, jev.timestamp)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp)

				duration := bound_duration(jev, thread.max_time)
				jev.self_time = duration - jev.self_time
				jev.self_time = max(jev.self_time, 0)

				if thread.current_depth > 0 {
					parent_depth := &thread.depths[ev_depth - 1]
					parent_ev_idx := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev_idx]
					pev.self_time += duration
					pev.self_time = max(pev.self_time, 0)
				}
			}
		}
	}

	return true
}

ms_v2_parse_next_event :: proc(trace: ^Trace, chunk: []u8, process: ^Process, thread: ^Thread) -> BinaryState {
	p := &trace.parser

	header_sz := i64(size_of(u64))
	if chunk_pos(p) + header_sz > i64(len(chunk)) {
		return .PartialRead
	}

	data_start := chunk[chunk_pos(p):]
	type := (^spall_fmt.Manual_Event_Type)(raw_data(data_start))^
	#partial switch type {
	case .Begin:
		event_sz := i64(size_of(spall_fmt.Begin_Event_V2))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.Begin_Event_V2)(raw_data(data_start))

		event_tail := i64(event.name_len) + i64(event.args_len)
		if (chunk_pos(p) + event_sz + event_tail) > i64(len(chunk)) {
			return .PartialRead
		}

		name := string(data_start[event_sz:event_sz+i64(event.name_len)])
		args := string(data_start[event_sz+i64(event.name_len):event_sz+i64(event.name_len)+i64(event.args_len)])

		ev := Event{
			id = in_get(&trace.intern, &trace.string_block, name),
			args = in_get(&trace.intern, &trace.string_block, args),
			duration = -1,
			self_time = 0,
			timestamp = max(i64(event.time), thread.zero_patchup),
		}

		if thread.max_time > ev.timestamp {
			post_error(trace, 
				"Woah, time-travel? You just had a begin event that started before a previous one; [pid: %d, tid: %d, name: %s, event: %v, event_count: %d]", 
				0, thread.id, in_getstr(&trace.string_block, ev.id), ev, trace.event_count)
			return .Failure
		}

		process.min_time = min(process.min_time, ev.timestamp)
		thread.min_time = min(thread.min_time, ev.timestamp)
		thread.max_time = ev.timestamp

		trace.total_min_time = min(trace.total_min_time, ev.timestamp)
		trace.total_max_time = max(trace.total_max_time, ev.timestamp)

		if thread.current_depth >= len(thread.depths) {
			depth := Depth{
				events = make([dynamic]Event),
			}
			non_zero_append(&thread.depths, depth)
		}

		depth := &thread.depths[thread.current_depth]
		thread.current_depth += 1
		append_event(&depth.events, &ev)

		ev_idx := len(depth.events)-1
		stack_push_back(&thread.bande_q, ev_idx)
		trace.event_count += 1

		p.pos += event_sz + event_tail
		return .EventRead
	case .End:
		event_sz := i64(size_of(spall_fmt.End_Event_V2))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.End_Event_V2)(raw_data(data_start))
		event.time = u64(max(i64(event.time), thread.zero_patchup))

		if thread.bande_q.len > 0 {
			jev_idx := stack_pop_back(&thread.bande_q)
			thread.current_depth -= 1

			depth := &thread.depths[thread.current_depth]
			jev := &depth.events[jev_idx]
			jev.duration = i64(event.time) - jev.timestamp
			if jev.duration == 0 {
				thread.zero_patchup = i64(event.time)
				thread.zero_patchup += 1
				jev.duration = 1
			}
			jev.self_time = jev.duration - jev.self_time
			thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
			trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)

			if thread.bande_q.len > 0 {
				parent_depth := &thread.depths[thread.current_depth - 1]
				parent_ev_idx := stack_peek_back(&thread.bande_q)

				pev := &parent_depth.events[parent_ev_idx]
				pev.self_time += jev.duration
			}
		}
		
		p.pos += event_sz
		return .EventRead
	case .Pad_Skip:
		event_sz := i64(size_of(spall_fmt.Pad_Skip))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.Pad_Skip)(raw_data(data_start))

		p.pos += event_sz + i64(event.size)
		return .EventRead
	case .Name_Thread: fallthrough
	case .Name_Process:
		event_sz := i64(size_of(spall_fmt.Name_Container))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall_fmt.Name_Container)(raw_data(data_start))
		event_tail := i64(event.name_len)
		if (chunk_pos(p) + event_sz + event_tail) > i64(len(chunk)) {
			return .PartialRead
		}

		raw_name := string(data_start[event_sz:event_sz+i64(event.name_len)])
		name := in_get(&trace.intern, &trace.string_block, raw_name)

		#partial switch type {
		case .Name_Thread:
			thread.name = name
		case .Name_Process:
			process.name = name
		}

		p.pos += event_sz + event_tail
		return .EventRead
	case:
		post_error(trace, "Invalid event type: 0x%x in file, offset: 0x%x", data_start[0], p.pos)
		return .Failure
	}

	return .PartialRead
}

ms_v2_get_next_buffer :: proc(trace: ^Trace, chunk: []u8, buffer_header: ^spall_fmt.Manual_Buffer_Header) -> BinaryState {
	p := &trace.parser

	if chunk_pos(p) + size_of(spall_fmt.Manual_Buffer_Header) > i64(len(chunk)) {
		return .PartialRead
	}

	data_start := chunk[chunk_pos(p):]
	tmp_header := (^spall_fmt.Manual_Buffer_Header)(raw_data(data_start))^
	buffer_header^ = tmp_header

	p.pos += size_of(spall_fmt.Manual_Buffer_Header)
	return .EventRead
}

ms_v2_parse :: proc(trace: ^Trace, fd: ^os.File, header_size: i64) -> bool {
	buffer_header := spall_fmt.Manual_Buffer_Header{}
	p := &trace.parser

	chunk_buffer := make([]u8, 4 * 1024 * 1024)
	defer delete(chunk_buffer)

	read_size, err := os.read_at(fd, chunk_buffer, 0)
	if err != nil {
		post_error(trace, "Unable to read file!")
		return false
	}

	last_read: i64 = 0
	full_chunk := chunk_buffer[:read_size]
	buffer_loop: for p.pos < trace.total_size {
		state := ms_v2_get_next_buffer(trace, full_chunk, &buffer_header)

		#partial switch state {
		case .PartialRead:
			if p.pos == last_read {
				fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", p.pos, trace.total_size, trace.total_size - p.pos)
				break buffer_loop
			} else {
				last_read = p.pos
			}

			p.offset = p.pos

			rd_sz, ok := get_chunk(p, fd, chunk_buffer)
			if !ok {
				post_error(trace, "Failed to read file!")
				return false
			}

			full_chunk = chunk_buffer[:rd_sz]
			continue buffer_loop
		case .Failure:
			return false
		}

		proc_idx := setup_pid(trace, buffer_header.pid)
		process := &trace.processes[proc_idx]

		thread_idx := setup_tid(trace, proc_idx, buffer_header.tid)
		thread := &process.threads[thread_idx]

		buffer_end := p.pos + i64(buffer_header.size)
		ev_loop: for p.pos < buffer_end {
			state := ms_v2_parse_next_event(trace, full_chunk, process, thread)
			#partial switch state {
			case .PartialRead:
				if p.pos == last_read {
					fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", p.pos, trace.total_size, trace.total_size - p.pos)
					break buffer_loop
				} else {
					last_read = p.pos
				}

				p.offset = p.pos

				rd_sz, ok := get_chunk(p, fd, chunk_buffer)
				if !ok {
					post_error(trace, "Failed to read file!")
					return false
				}

				full_chunk = chunk_buffer[:rd_sz]
				continue ev_loop
			case .Failure:
				return false
			}
		}
	}

	// cleanup unfinished events
	for &process in trace.processes {
		for &thread in process.threads {
			assert(thread.bande_q.len == thread.current_depth)
			for thread.current_depth > 0 {
				jev_idx := stack_pop_back(&thread.bande_q)
				thread.current_depth -= 1
				ev_depth := thread.current_depth

				depth := &thread.depths[ev_depth]
				jev := &depth.events[jev_idx]

				thread.max_time = max(thread.max_time, jev.timestamp)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp)

				duration := bound_duration(jev, thread.max_time)
				jev.self_time = duration - jev.self_time
				jev.self_time = max(jev.self_time, 0)

				if thread.current_depth > 0 {
					parent_depth := &thread.depths[ev_depth - 1]
					parent_ev_idx := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev_idx]
					pev.self_time += duration
					pev.self_time = max(pev.self_time, 0)
				}
			}
		}
	}

	return true
}
