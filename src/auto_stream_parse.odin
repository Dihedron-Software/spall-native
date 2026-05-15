package main

import "base:intrinsics"

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:mem"
import "core:os"
import "core:math"
import "formats:spall_fmt"

as_get_next_buffer :: proc(trace: ^Trace, chunk: []u8, buffer_header: ^spall_fmt.Auto_Buffer_Header) -> BinaryState {
	p := &trace.parser

	if chunk_pos(p) + size_of(spall_fmt.Auto_Buffer_Header) > i64(len(chunk)) {
		return .PartialRead
	}

	data_start := chunk[chunk_pos(p):]
	tmp_header := (^spall_fmt.Auto_Buffer_Header)(raw_data(data_start))^
	buffer_header^ = tmp_header

	p.pos += size_of(spall_fmt.Auto_Buffer_Header)
	return .EventRead
}

pull_uval :: #force_inline proc(buffer: []u8, size: int) -> u64 {
    switch size {
    case 1: return u64(((^u8)(raw_data(buffer)))^)
    case 2: return u64(((^u16)(raw_data(buffer)))^)
    case 4: return u64(((^u32)(raw_data(buffer)))^)
    case 8: return u64(((^u64)(raw_data(buffer)))^)
    }
    return 0
}

as_parse_next_event :: proc(trace: ^Trace, chunk: []u8, process: ^Process, thread: ^Thread, current_time: ^i64, current_addr: ^u64, current_caller: ^u64) -> BinaryState {
	p := &trace.parser

	min_sz := i64(size_of(u16))
	if chunk_pos(p) + min_sz > i64(len(chunk)) {
		return .PartialRead
	}

    data_start := chunk[chunk_pos(p):]
    type_byte := ((^u8)(raw_data(data_start))^)
    type_tag := type_byte >> 6

    i : i64 = 1
    switch type_tag {
	case 0: // MicroBegin
		dt_size     := i64(1 << ((0b00_11_00_00 & type_byte) >> 4))
		addr_size   := i64(1 << ((0b00_00_11_00 & type_byte) >> 2))
		caller_size := i64(1 <<  (0b00_00_00_11 & type_byte))
		event_sz := 1 + dt_size + addr_size + caller_size
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}

		dt       := pull_uval(chunk[chunk_pos(p)+i:], int(dt_size));     i += dt_size
		d_addr   := pull_uval(chunk[chunk_pos(p)+i:], int(addr_size));   i += addr_size
		d_caller := pull_uval(chunk[chunk_pos(p)+i:], int(caller_size)); i += caller_size

		current_time^   = current_time^ + i64(dt)
		current_addr^   = current_addr^ ~ d_addr
		current_caller^ = current_caller^ ~ d_caller

		id        := current_addr^
		caller_id := current_caller^
		timestamp := current_time^
		//fmt.printf("B | ts: %v -- dt: %v || max time: %v\n", timestamp, dt, thread.max_time)

		if thread.max_time > timestamp {
			post_error(trace, 
				"Woah, time-travel? You just had a begin event that started before a previous one; [pid: %d, tid: %d, addr: 0x%x, event_count: %d]", 
				0, thread.id, id, trace.event_count)
			return .Failure
		}

		thread.min_time  = min(thread.min_time, timestamp)
		thread.max_time  = max(thread.max_time, timestamp)

		trace.total_min_time = min(trace.total_min_time, timestamp)
		trace.total_max_time = max(trace.total_max_time, timestamp)

		depth := &thread.depths[thread.current_depth]
		thread.current_depth += 1
		ev := add_event(&depth.events)
		ev^ = Event{
			has_addr = true,
			id = id,
			args = caller_id,
			duration = -1,
			timestamp = timestamp,
		}

		ev_idx := len(depth.events)-1
		stack_push_back(&thread.bande_q, ev_idx)
		trace.event_count += 1

		p.pos += event_sz
	case 1: // MicroEnd
		dt_size := i64(1 << ((0b00_11_00_00 & type_byte) >> 4))
		event_sz := 1 + dt_size
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}

		dt := pull_uval(chunk[chunk_pos(p)+i:], int(dt_size)); i += dt_size

		ts := current_time^ + i64(dt)
		//fmt.printf("E | %v -- dt: %v\n", ts, dt)

		if thread.bande_q.len > 0 {
			jev_idx := stack_pop_back(&thread.bande_q)
			thread.current_depth -= 1

			depth := &thread.depths[thread.current_depth]
			jev := &depth.events[jev_idx]
			jev.duration = ts - jev.timestamp
			jev.self_time = jev.duration - jev.self_time

			thread.max_time      = max(thread.max_time, jev.timestamp + jev.duration)
			trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)

			if thread.bande_q.len > 0 {
				parent_depth := &thread.depths[thread.current_depth - 1]
				parent_ev_idx := stack_peek_back(&thread.bande_q)

				pev := &parent_depth.events[parent_ev_idx]
				pev.self_time += jev.duration
			}
		}
		
		current_time^ = ts
		p.pos += event_sz
	case 2: // Other Events
		type := spall_fmt.Auto_Event_Type((0b00_11_00_00 & type_byte) >> 4)
		#partial switch type {
		case .Begin:
			dt_size   := i64(1 << ((0b00_00_11_00 & type_byte) >> 2))
			name_size := i64(1 << ((0b00_00_00_10 & type_byte) >> 1))
			arg_size  := i64(1 << (0b00_00_00_01 & type_byte))

			min_event_sz := 1 + dt_size + name_size + arg_size
			if chunk_pos(p) + min_event_sz > i64(len(chunk)) {
				return .PartialRead
			}
			
			i : i64 = 1
			dt := pull_uval(chunk[chunk_pos(p)+i:], int(dt_size));    i += dt_size
			name_len := pull_uval(chunk[chunk_pos(p)+i:], int(name_size)); i += name_size
			args_len := pull_uval(chunk[chunk_pos(p)+i:], int(arg_size));  i += arg_size

			event_tail := i64(name_len) + i64(args_len)
			if (chunk_pos(p) + min_event_sz + event_tail) > i64(len(chunk)) {
				return .PartialRead
			}

			name_str := string(data_start[i:i+i64(name_len)]); i += i64(name_len)
			args_str := string(data_start[i:i+i64(args_len)]); i += i64(args_len)
			id   := in_get(&trace.intern, &trace.string_block, name_str)
			args := in_get(&trace.intern, &trace.string_block, args_str)

			current_time^ = current_time^ + i64(dt)
			timestamp := current_time^

			//fmt.printf("MB | %v -- dt: %v\n", timestamp, dt)
			if thread.max_time > timestamp {
				post_error(trace, 
					"Woah, time-travel? You just had a begin event that started before a previous one; [pid: %d, tid: %d, name: %s, event_count: %d]", 
					0, thread.id, name_str, trace.event_count)
				return .Failure
			}

			thread.min_time  = min(thread.min_time, timestamp)
			thread.max_time  = max(thread.max_time, timestamp)

			trace.total_min_time = min(trace.total_min_time, timestamp)
			trace.total_max_time = max(trace.total_max_time, timestamp)

			depth := &thread.depths[thread.current_depth]
			thread.current_depth += 1
			ev := add_event(&depth.events)
			ev^ = Event{
				id = id,
				args = args,
				duration = -1,
				timestamp = timestamp,
			}

			ev_idx := len(depth.events)-1
			stack_push_back(&thread.bande_q, ev_idx)
			trace.event_count += 1

			p.pos += i
		case:
			post_error(trace, "Invalid event type: %d in file!", data_start[0])
			return .Failure
		}
	case:
		post_error(trace, "Invalid event type: %d in file!", data_start[0])
		return .Failure
    }

	return .EventRead
}

as_parse :: proc(trace: ^Trace, fd: ^os.File, header_size: i64) -> bool {
	buffer_header := spall_fmt.Auto_Buffer_Header{}
	p := &trace.parser

	proc_idx := setup_pid(trace, 0)
	process := &trace.processes[proc_idx]

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
		state := as_get_next_buffer(trace, full_chunk, &buffer_header)
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

		thread_idx := setup_tid(trace, proc_idx, buffer_header.tid)
		thread := &process.threads[thread_idx]
		for u32(len(thread.depths)) <= buffer_header.max_depth {
			depth := Depth{
                events = make([dynamic]Event),
			}
			non_zero_append(&thread.depths, depth)
		}

		buffer_end := p.pos + i64(buffer_header.size)

        current_time   := i64(buffer_header.first_ts)
        current_addr   := u64(0)
        current_caller := u64(0)
        //fmt.printf("starting new buffer for tid %d at %d\n", buffer_header.tid, current_time)
		ev_loop: for p.pos < buffer_end {
			state := as_parse_next_event(trace, full_chunk, process, thread, &current_time, &current_addr, &current_caller)

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
			process.min_time = min(process.min_time, thread.min_time)

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
