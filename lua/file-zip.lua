--
-- Zip Archive dissector
-- Author: Peter Wu <peter@lekensteyn.nl>
--
-- Spec: https://en.wikipedia.org/wiki/Zip_(file_format)#File_headers
--

--
-- Dissection of Zip file contents
--

-- takes a table where keys are the field names and values are descriptions of
-- fields. If a value is a table without numeric indicdes, assume that it is a
-- nested tree.
local function make_fields(field_abbr_prefix, field_defs, hfs_out, hfs_list_out)
    for name, params in pairs(field_defs) do
        if #params == 0 then
            -- Assume nested table, flatten it
            hfs_out[name] = {}
            make_fields(field_abbr_prefix .. name .. ".", params,
                hfs_out[name], hfs_list_out)
        else
            local proto_field_constructor = params[1]
            local field_abbr = field_abbr_prefix .. name
            local field
            if type(params[2]) == "string" then
                -- Name was given, use it
                field = proto_field_constructor(field_abbr, unpack(params, 2))
            else
                -- Name was not given, use field name (the suffix)
                field = proto_field_constructor(field_abbr, name, unpack(params, 2))
            end
            hfs_out[name] = field
            table.insert(hfs_list_out, field)
        end
    end
end

local proto_zip = Proto.new("zip_archive", "Zip Archive")
local hf = {}
make_fields("zip_archive", {
    signature = {ProtoField.uint32, base.HEX},
    entry = {
        _ = {ProtoField.none, "File entry"},
        version         = {ProtoField.uint16, base.DEC},
        flag = {
            _ = {ProtoField.uint16, "General purpose bit flag", base.HEX},
            -- TODO fi wslua documentation, it is wrong.
            has_data_desc   = {ProtoField.bool, 16, nil, 0x0008, "Whether data descriptor is present"},
        },
        comp_method     = {ProtoField.uint16, base.HEX},
        lastmod_time    = {ProtoField.uint16, base.HEX},
        lastmod_date    = {ProtoField.uint16, base.HEX},
        crc32           = {ProtoField.uint32, base.HEX},
        size_comp       = {ProtoField.uint32, base.DEC},
        size_uncomp     = {ProtoField.uint32, base.DEC},
        filename_len    = {ProtoField.uint16, base.DEC},
        extra_len       = {ProtoField.uint16, base.DEC},
        filename        = {ProtoField.string},
        extra           = {ProtoField.bytes},
        data            = {ProtoField.bytes},
        data_desc = {
            _ = {ProtoField.none, "Data descriptor"},
            crc32           = {ProtoField.uint32, base.HEX},
            size_comp       = {ProtoField.uint32, base.DEC},
            size_uncomp     = {ProtoField.uint32, base.DEC},
        },
    },
    cd = {
        _ = {ProtoField.none, "Central Directory Record"},
        version_made    = {ProtoField.uint16, base.HEX_DEC},
        version_extract = {ProtoField.uint16, base.HEX_DEC},
        flag            = {ProtoField.uint16, base.HEX},
        comp_method     = {ProtoField.uint16, base.HEX},
        lastmod_time    = {ProtoField.uint16, base.HEX},
        lastmod_date    = {ProtoField.uint16, base.HEX},
        crc32           = {ProtoField.uint32, base.HEX},
        size_comp       = {ProtoField.uint32, base.DEC},
        size_uncomp     = {ProtoField.uint32, base.DEC},
        filename_len    = {ProtoField.uint16, base.DEC},
        extra_len       = {ProtoField.uint16, base.DEC},
        comment_len     = {ProtoField.uint16, base.DEC},
        disk_number     = {ProtoField.uint16, base.DEC},
        attr_intern     = {ProtoField.uint16, base.HEX},
        attr_extern     = {ProtoField.uint32, base.HEX},
        relative_offset = {ProtoField.uint32, base.DEC},
        filename        = {ProtoField.string},
        extra           = {ProtoField.bytes},
        comment         = {ProtoField.string},
    },
    eocd = {
        _ = {ProtoField.none, "End of Central Directory Record"},
        disk_number     = {ProtoField.uint16, base.DEC},
        disk_start      = {ProtoField.uint16, base.DEC},
        num_entries     = {ProtoField.uint16, base.DEC},
        num_entries_total = {ProtoField.uint16, base.DEC},
        size            = {ProtoField.uint32, base.DEC},
        relative_offset = {ProtoField.uint32, base.DEC},
        comment_len     = {ProtoField.uint16, base.DEC},
    },
}, hf, proto_zip.fields)

local function dissect_one(tvb, offset, pinfo, tree)
    local orig_offset = offset
    local magic = tvb(offset, 4):le_int()
    if magic == 0x04034b50 then -- File entry
        local subtree = tree:add_le(hf.entry._, tvb(offset, 30))
        -- header
        subtree:add_le(hf.signature,            tvb(offset, 4))
        subtree:add_le(hf.entry.version,        tvb(offset + 4, 2))
        local flgtree = subtree:add_le(hf.entry.flag._, tvb(offset + 6, 2))
        -- TODO why does flag.has_data_desc segfault if tvb is not given?
        flgtree:add_le(hf.entry.flag.has_data_desc, tvb(offset + 6, 2))
        subtree:add_le(hf.entry.comp_method,    tvb(offset + 8, 2))
        subtree:add_le(hf.entry.lastmod_time,   tvb(offset + 10, 2))
        subtree:add_le(hf.entry.lastmod_date,   tvb(offset + 12, 2))
        subtree:add_le(hf.entry.crc32,          tvb(offset + 14, 4))
        subtree:add_le(hf.entry.size_comp,      tvb(offset + 18, 4))
        subtree:add_le(hf.entry.size_uncomp,    tvb(offset + 22, 4))
        subtree:add_le(hf.entry.filename_len,   tvb(offset + 26, 2))
        subtree:add_le(hf.entry.extra_len,      tvb(offset + 28, 2))
        local flag = tvb(offset + 6, 2):le_uint()
        local data_len = tvb(offset + 18, 2):le_uint()
        local filename_len = tvb(offset + 26, 2):le_uint()
        local extra_len = tvb(offset + 28, 2):le_uint()

        -- Optional data descriptor follows data if GP flag bit 3 (0x8) is set
        --[[ This is wrong, cannot know the location of dd, have to query CD first
        local ddlen
        if bit.band(flag, 8) ~= 0 then
            local dd_offset = offset + 30 + filename_len + extra_len + data_len
            if tvb(dd_offset, 4):le_uint() == 0x08074b50 then
                -- Optional data descriptor signature... WTF, why?!
                dd_offset = dd_offset + 4
                ddlen = 16
            else
                ddlen = 12
            end
            subtree:add_le(hf.entry.data_desc.size_comp,     tvb(dd_offset + 4, 4))
            --data_len = tvb(dd_offset + 4, 4):le_uint()
        end
        --]]

        -- skip header
        offset = offset + 30
        subtree:add(hf.entry.filename,          tvb(offset, filename_len))
        subtree:append_text(": " .. tvb(offset, filename_len):string())
        offset = offset + filename_len
        if extra_len > 0 then
            subtree:add(hf.entry.extra,         tvb(offset, extra_len))
            offset = offset + extra_len
        end
        if data_len > 0 then
            subtree:add(hf.entry.data,          tvb(offset, data_len))
            offset = offset + data_len
        end
        --[[ This does need really work..
        -- Optional data descriptor header
        if ddlen then
            local dd_offset = offset
            local ddtree = subtree:add_le(hf.entry.data_desc._, tvb(dd_offset, ddlen))
            if ddlen == 16 then
                ddtree:add_le(hf.signature,                 tvb(dd_offset, 4))
                dd_offset = dd_offset + 4
            end
            ddtree:add_le(hf.entry.data_desc.crc32,         tvb(dd_offset, 4))
            ddtree:add_le(hf.entry.data_desc.size_comp,     tvb(dd_offset + 4, 4))
            ddtree:add_le(hf.entry.data_desc.size_uncomp,   tvb(dd_offset + 8, 4))
            offset = offset + ddlen
        end
        --]]

        subtree:set_len(offset - orig_offset)
        return offset
    elseif magic == 0x02014b50 then -- Central Directory
        local subtree = tree:add_le(hf.cd._,    tvb(offset, 46))
        subtree:add_le(hf.signature,            tvb(offset, 2))
        subtree:add_le(hf.cd.version_made,      tvb(offset + 4, 2))
        subtree:add_le(hf.cd.version_extract,   tvb(offset + 6, 2))
        subtree:add_le(hf.cd.flag,              tvb(offset + 8, 2))
        subtree:add_le(hf.cd.comp_method,       tvb(offset + 10, 2))
        subtree:add_le(hf.cd.lastmod_time,      tvb(offset + 12, 2))
        subtree:add_le(hf.cd.lastmod_date,      tvb(offset + 14, 2))
        subtree:add_le(hf.cd.crc32,             tvb(offset + 16, 4))
        subtree:add_le(hf.cd.size_comp,         tvb(offset + 20, 4))
        subtree:add_le(hf.cd.size_uncomp,       tvb(offset + 24, 4))
        subtree:add_le(hf.cd.filename_len,      tvb(offset + 28, 2))
        subtree:add_le(hf.cd.extra_len,         tvb(offset + 30, 2))
        subtree:add_le(hf.cd.comment_len,       tvb(offset + 32, 2))
        subtree:add_le(hf.cd.disk_number,       tvb(offset + 34, 2))
        subtree:add_le(hf.cd.attr_intern,       tvb(offset + 36, 2))
        subtree:add_le(hf.cd.attr_extern,       tvb(offset + 38, 4))
        subtree:add_le(hf.cd.relative_offset,   tvb(offset + 42, 4))

        local filename_len = tvb(offset + 28, 2):le_uint()
        local extra_len = tvb(offset + 30, 2):le_uint()
        local comment_len = tvb(offset + 32, 2):le_uint()
        -- skip header
        offset = offset + 46
        subtree:add(hf.cd.filename,             tvb(offset, filename_len))
        subtree:append_text(": " .. tvb(offset, filename_len):string())
        offset = offset + filename_len
        if extra_len > 0 then
            subtree:add(hf.cd.extra,            tvb(offset, extra_len))
            offset = offset + extra_len
        end
        if comment_len > 0 then
            subtree:add(hf.cd.comment,          tvb(offset, comment_len))
            offset = offset + comment_len
        end
        subtree:set_len(offset - orig_offset)
        return offset
    elseif magic == 0x06054b50 then -- End of Central Directory
        local subtree = tree:add_le(hf.cd._,    tvb(offset, 22))
        subtree:add_le(hf.signature,            tvb(offset, 4))
        subtree:add_le(hf.eocd.disk_number,     tvb(offset + 4, 2))
        subtree:add_le(hf.eocd.disk_start,      tvb(offset + 6, 2))
        subtree:add_le(hf.eocd.num_entries,     tvb(offset + 8, 2))
        subtree:add_le(hf.eocd.num_entries_total, tvb(offset + 10, 2))
        subtree:add_le(hf.eocd.size,            tvb(offset + 12, 4))
        subtree:add_le(hf.eocd.relative_offset, tvb(offset + 16, 4))
        subtree:add_le(hf.eocd.comment_len,     tvb(offset + 20, 2))

        local comment_len = tvb(offset + 20, 2):le_uint()
        offset = offset + 22
        if comment_len > 0 then
            subtree:add(hf.eocd.comment,        tvb(offset, comment_len))
            offset = offset + comment_len
        end
        subtree:set_len(offset - orig_offset)
        return offset
    elseif tvb:raw(offset, 2) == "PK" then
        -- Unknown signature
        tree:add_le(hf.signature, tvb(offset, 4))
    end
end

function proto_zip.dissector(tvb, pinfo, tree)
    pinfo.cols.protocol = "zip"
    --pinfo.cols.info = ""

    local next_offset = 0
    while next_offset and next_offset < tvb:len() do
        next_offset = dissect_one(tvb, next_offset, pinfo, tree)
    end
    return next_offset
end

local function zip_heur(tvb, pinfo, tree)
    if tvb:raw(0, 2) ~= "PK" then
        return false
    end

    proto_zip.dissector(tvb, pinfo, tree)
    return true
end

-- Register MIME types in case a Zip file appears over HTTP.
DissectorTable.get("media_type"):add("application/zip", proto_zip)
DissectorTable.get("media_type"):add("application/java-archive", proto_zip)

-- Ensure that files can directly be opened (after any FileHandler has accepted
-- it, see below).
proto_zip:register_heuristic("wtap_file", zip_heur)


--
-- File handler (for directly interpreting opening a Zip file in Wireshark)
-- Actually, all it does is recognizing a Zip file and passing one packet to the
-- MIME dissector.
--

local zip_fh = FileHandler.new("Zip", "zip", "Zip archive file reader", "rms")

-- Check if file is really a zip file (return true if it is)
function zip_fh.read_open(file, cinfo)
    -- XXX improve heuristics?
    if file:read(2) ~= "PK" then
        return false
    end

    -- Find end of file and rewind.
    local endpos, err = file:seek("end")
    if not endpos then error("Error while finding end! " .. err) end
    local ok, err = file:seek("set", 0)
    if not ok then error("Non-seekable file! " .. err) end

    cinfo.encap = wtap_encaps.MIME
    cinfo.private_table = {
        endpos = endpos,
    }

    return true
end

-- Read next packet (returns begin offset or false on error)
local function zip_fh_read(file, cinfo, finfo)
    local p = cinfo.private_table
    local curpos = file:seek("cur")

    -- Fal on EOF
    if curpos >= p.endpos then return false end

    finfo.original_length = p.endpos - curpos
    finfo.captured_length = p.endpos - curpos

    if not finfo:read_data(file, finfo.captured_length) then
        -- Partial read?
        print("Hmm, partial read, curpos=" .. curpos .. ", len: " .. finfo.captured_length)
        return false
    end

    return curpos
end
zip_fh.read = zip_fh_read

-- Reads packet at offset (returns true on success and false on failure)
function zip_fh.seek_read(file, cinfo, finfo, offset)
    file:seek("set", offset)
    -- Return a boolean since WS < 2.4 has an undocumented "feature" where
    -- strings (including numbers) are treated as data.
    return zip_fh_read(file, cinfo, finfo) ~= false
end

-- Hints for when to invoke this dissector.
zip_fh.extensions = "zip;jar"

register_filehandler(zip_fh)