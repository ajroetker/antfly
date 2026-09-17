// Copyright 2026 Antfly, Inc.
//
// Licensed under the Elastic License 2.0 (ELv2); you may not use this file
// except in compliance with the Elastic License 2.0. You may obtain a copy of
// the Elastic License 2.0 at
//
//     https://www.antfly.io/licensing/ELv2-license
//
// Unless required by applicable law or agreed to in writing, software distributed
// under the Elastic License 2.0 is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// Elastic License 2.0 for the specific language governing permissions and
// limitations.

//! Private execution plans. Public queries contain no navigation policy.
const std = @import("std");
const api = @import("antfly_metadata_openapi");

pub const TreeSearchConfig = struct {
    index: []const u8,
    start_key: ?[]const u8 = null,
    start_nodes: ?[]const u8 = null,
    max_depth: ?i64 = null,
    beam_width: ?i64 = null,
};

pub const Query = blk: {
    const fields = std.meta.fields(api.QueryRequest) ++ std.meta.fields(struct { tree_search: ?TreeSearchConfig = null });
    break :blk planStruct(fields);
};

pub const Request = blk: {
    const original = std.meta.fields(api.RetrievalAgentRequest);
    var fields: [original.len]std.builtin.Type.StructField = undefined;
    @memcpy(&fields, original);
    for (&fields) |*field| {
        if (std.mem.eql(u8, field.name, "queries")) field.type = []const Query;
    }
    break :blk planStruct(&fields);
};

pub fn fromPublic(alloc: std.mem.Allocator, input: api.RetrievalAgentRequest) !Request {
    var result: Request = undefined;
    inline for (std.meta.fields(api.RetrievalAgentRequest)) |field| {
        if (comptime std.mem.eql(u8, field.name, "queries")) {
            const queries = try alloc.alloc(Query, input.queries.len);
            for (input.queries, queries) |source, *dest| {
                dest.* = .{};
                inline for (std.meta.fields(api.QueryRequest)) |qfield| @field(dest, qfield.name) = @field(source, qfield.name);
            }
            result.queries = queries;
        } else @field(result, field.name) = @field(input, field.name);
    }
    return result;
}

fn planStruct(comptime fields: []const std.builtin.Type.StructField) type {
    var names: [fields.len][:0]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |field, index| {
        names[index] = field.name;
        types[index] = field.type;
        attrs[index] = .{ .default_value_ptr = field.default_value_ptr };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}
