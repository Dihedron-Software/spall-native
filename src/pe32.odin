package main

import "core:fmt"
import "core:os"
import "core:bytes"
import "core:slice"
import "core:mem"
import "core:math"

/*
Handy References:
- https://llvm.org/docs/PDB/MsfFile.html
- https://github.com/dotnet/runtime/blob/main/docs/design/specs/PE-COFF.md
- https://pierrelib.pagesperso-orange.fr/exec_formats/MS_Symbol_Type_v1.0.pdf
*/

DOS_MAGIC  := []u8{ 0x4d, 0x5a }
PE32_MAGIC := []u8{ 'P', 'E', 0, 0 }

DEBUG_TYPE_CODEVIEW :: 2
DLL_FLAGS_DYNAMIC_BASE :: 0x40

COFF_Header :: struct #packed {
	machine:              u16,
	section_count:        u16,
	timestamp:            u32,
	symbol_table_offset:  u32,
	symbol_count:         u32,
	optional_header_size: u16,
	flags:                u16,
}

Data_Directory :: struct #packed {
	virtual_addr: u32,
	size:         u32,
}

COFF_Optional_Header :: struct #packed {
	magic:                u16,
	linker_major_version:  u8,
	linker_minor_version:  u8,
	code_size:            u32,
	init_data_size:       u32,
	uninit_data_size:     u32,
	entrypoint_addr:      u32,
	code_base:            u32,
	image_base:           u64,
	section_align:        u32,
	file_align:           u32,
	os_major_version:     u16,
	os_minor_version:     u16,
	image_major_version:  u16,
	image_minor_version:  u16,
	subsystem_major_version: u16,
	subsystem_minor_version: u16,
	win32_version:        u32,
	image_size:           u32,
	headers_size:         u32,
	checksum:             u32,
	subsystem:            u16,
	dll_flags:            u16,
	reserve_stack_size:   u64,
	commit_stack_size:    u64,
	reserve_heap_size:    u64,
	commit_heap_size:     u64,
	loader_flags:         u32,
	rva_and_sizes_count:  u32,
	data_directories:     [16]Data_Directory,
}

COFF_Section_Header :: struct #packed {
	name:             [8]u8,
	virtual_size:       u32,
	virtual_addr:       u32,
	raw_data_size:      u32,
	raw_data_offset:    u32,
	reloc_offset:       u32,
	line_number_offset: u32,
	relocation_count:   u16,
	line_number_count:  u16,
	flags:              u32,
}

PE32_Header :: struct #packed {
	magic: [4]u8,
	coff_header: COFF_Header,
	optional_header: COFF_Optional_Header,
}

COFF_Debug_Directory :: struct #packed {
	flags:           u32,
	timestamp:       u32,
	major_version:   u16,
	minor_version:   u16,
	type:            u32,
	data_size:       u32,
	raw_data_addr:   u32,
	raw_data_offset: u32,
}

COFF_Debug_Entry :: struct #packed {
	signature: [4]u8,
	guid:     [16]u8,
	age:         u32,
}

COFF_Symbol :: struct #packed {
	name:          [8]u8,
	value:           u32,
	section_num:     u16,
	type:            u16,
	storage_class:    u8,
	aux_symbol_count: u8,
}

// 6 is always debug
DEBUG_DIR :: 6

get_pdb_path :: proc(rdr: ^Stream_Context, section_hdr: COFF_Section_Header, debug_rva: u32) -> (name: string, ok: bool) {
	start := section_hdr.virtual_addr
	end   := start + section_hdr.virtual_size

	if debug_rva < start || (debug_rva + size_of(COFF_Debug_Directory)) > end {
		return
	}

	section_relative_offset := debug_rva - start
	dir_offset := section_hdr.raw_data_offset + section_relative_offset

	stream_set(rdr, int(dir_offset))
	debug_dir := stream_val(rdr, COFF_Debug_Directory) or_return
	if debug_dir.type != DEBUG_TYPE_CODEVIEW {
		return
	}

	if debug_dir.data_size <= size_of(COFF_Debug_Entry) {
		return
	}

	stream_set(rdr, int(debug_dir.raw_data_offset + size_of(COFF_Debug_Entry)))
	pdb_cstr := stream_cstring(rdr) or_return
	return string(pdb_cstr), true
}

load_pe32 :: proc(trace: ^Trace, exec_buffer: []u8, bucket: ^Func_Bucket) -> bool {
	pdb_path := ""
	dos_end_offset := 0x3c

	rdr := stream_init(exec_buffer, dos_end_offset)
	pe_hdr_offset := stream_val(&rdr, u32) or_return

	stream_set(&rdr, int(pe_hdr_offset))
	pe_hdr := stream_val(&rdr, PE32_Header) or_return
	if !bytes.equal(pe_hdr.magic[:], PE32_MAGIC) {
		return false
	}

	
	use_aslr := false
	if (pe_hdr.optional_header.dll_flags & DLL_FLAGS_DYNAMIC_BASE) != 0 {
		use_aslr = true
	}

	string_table_offset := pe_hdr.coff_header.symbol_table_offset + (pe_hdr.coff_header.symbol_count * size_of(COFF_Symbol))
	string_table := exec_buffer[string_table_offset:]
	strtab_size := slice_to_type(string_table, u32) or_return

	section_buffer := rdr.buffer[rdr.idx:]
	section_bytes := (size_of(COFF_Section_Header) * int(pe_hdr.coff_header.section_count))

	might_have_pdb := true
	debug_rva := pe_hdr.optional_header.data_directories[DEBUG_DIR].virtual_addr
	debug_size := pe_hdr.optional_header.data_directories[DEBUG_DIR].size
	if debug_rva == 0 {
		might_have_pdb = false
	}

	sections := Sections{}
	for i := 0; i < int(pe_hdr.coff_header.section_count); i += 1 {

		sect_rdr := stream_init(section_buffer[:section_bytes], i * size_of(COFF_Section_Header))
		section_hdr := stream_val(&sect_rdr, COFF_Section_Header) or_return

		if might_have_pdb {
			path, ok := get_pdb_path(&rdr, section_hdr, debug_rva)
			if !ok { continue }
			if path == "" { might_have_pdb = false; continue }
			pdb_path = path
			break
		}

		section_name := string(section_hdr.name[:])
		if section_name[0] == '/' {
			idx_str := string(cstring(raw_data(section_name[1:])))
			idx := parse_u32(idx_str) or_return
			section_name = string(cstring(raw_data(string_table[idx:])))
		}

		start := u64(section_hdr.raw_data_offset)
		size  := u64(section_hdr.raw_data_size)
		switch section_name {
		case ".debug_line":
			sections.line        = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_str":
			sections.debug_str   = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_str_offsets":
			sections.str_offsets = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_line_str":
			sections.line_str    = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_info":
			sections.info        = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_abbrev":
			sections.abbrev      = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_addr":
			sections.addr        = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_ranges":
			sections.ranges      = create_subbuffer(exec_buffer, start, size) or_return
		case ".debug_rnglists":
			sections.rnglists    = create_subbuffer(exec_buffer, start, size) or_return
		}
	}
	if !use_aslr {
		fmt.printf("PE32: Your binary is not relocatable, disabling ASLR correction\n")
		bucket.base_address = 0
	}

	// I think we've got a PDB file
	if might_have_pdb && pdb_path != "" {
		if opt.pdb_path != "" {
			pdb_path = opt.pdb_path
		}
		fmt.printf("PDB is at %s\n", pdb_path)
		pdb_buffer, pdb_err := os.read_entire_file(pdb_path, context.allocator)
		if pdb_err != nil { return false }
		defer delete(pdb_buffer)

		return load_pdb(trace, section_buffer, pdb_buffer, bucket)

	// Do we have DWARF?
	} else {
		return load_dwarf(trace, &sections, bucket, 0)
	}
}
