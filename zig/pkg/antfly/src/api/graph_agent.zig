// Copyright 2026 Antfly, Inc.
//
// Licensed under the Elastic License 2.0 (the "License"); you may not use this file
// except in compliance with the License. You may obtain a copy of the License at
//
//     https://www.antfly.io/licensing/ELv2-license

const std = @import("std");
const generating = @import("antfly_generating");

pub const default_max_steps: u32 = 8;
pub const default_neighbor_limit: u32 = 8;

/// A document participating in one graph-agent decision. The callback that
/// returns a Node transfers ownership of `key` and `document_json` to the
/// caller of `run`.
pub const Node = struct {
    key: []const u8,
    document_json: []const u8 = &.{},

    pub fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        if (self.document_json.len > 0) alloc.free(self.document_json);
        self.* = undefined;
    }
};

pub const TraceStep = struct {
    from_key: []const u8,
    selected_key: ?[]const u8,
    model_output: []const u8,

    fn deinit(self: *TraceStep, alloc: std.mem.Allocator) void {
        alloc.free(self.from_key);
        if (self.selected_key) |key| alloc.free(key);
        alloc.free(self.model_output);
        self.* = undefined;
    }
};

pub const Result = struct {
    final_key: []const u8,
    answer: ?[]const u8,
    steps: []TraceStep,

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.final_key);
        if (self.answer) |answer| alloc.free(answer);
        for (self.steps) |*step| step.deinit(alloc);
        if (self.steps.len > 0) alloc.free(self.steps);
        self.* = undefined;
    }

    /// Encode the agent result as the value that the existing query response
    /// builder can place under a named `graph_results` entry.
    pub fn jsonAlloc(self: Result, alloc: std.mem.Allocator, include_trace: bool) ![]u8 {
        const JsonTraceStep = struct {
            from_key: []const u8,
            selected_key: ?[]const u8,
            model_output: []const u8,
        };
        var trace = std.ArrayListUnmanaged(JsonTraceStep).empty;
        defer trace.deinit(alloc);
        if (include_trace) {
            try trace.ensureTotalCapacity(alloc, self.steps.len);
            for (self.steps) |step| try trace.append(alloc, .{
                .from_key = step.from_key,
                .selected_key = step.selected_key,
                .model_output = step.model_output,
            });
        }
        return try std.json.Stringify.valueAlloc(alloc, .{
            .kind = "agent",
            .final_key = self.final_key,
            .answer = self.answer,
            .steps = trace.items,
        }, .{});
    }
};

pub const Config = struct {
    user_query: []const u8,
    instruction: []const u8 = "Choose the next graph node or finish the task.",
    max_steps: u32 = default_max_steps,
    neighbor_limit: u32 = default_neighbor_limit,
};

/// Convert the public graph-agent configuration into the runtime chain used by
/// the existing generation backend. The caller owns the returned links.
pub fn chainsFromOpenApi(alloc: std.mem.Allocator, config: anytype) ![]generating.ChainLink {
    if (config.generator != null and config.chain != null) return error.InvalidGraphAgentRequest;
    var links = std.ArrayListUnmanaged(generating.ChainLink).empty;
    errdefer {
        for (links.items) |*link| link.deinit(alloc);
        links.deinit(alloc);
    }
    if (config.chain) |chain| {
        if (chain.len == 0 or chain.len > 8) return error.InvalidGraphAgentRequest;
        for (chain) |link| try links.append(alloc, generating.chainLinkFromOpenApi(alloc, link) catch return error.InvalidGraphAgentRequest);
    } else if (config.generator) |generator| {
        try links.append(alloc, .{ .generator = generating.configFromOpenApi(alloc, generator) catch return error.InvalidGraphAgentRequest });
    } else return error.MissingGenerationConfig;
    return try links.toOwnedSlice(alloc);
}

pub fn freeChains(alloc: std.mem.Allocator, chains: []generating.ChainLink) void {
    for (chains) |*link| link.deinit(alloc);
    if (chains.len > 0) alloc.free(chains);
}

pub fn startKeyFromOpenApi(config: anytype, alloc: std.mem.Allocator) ![]const u8 {
    return switch (config.start) {
        .graph_key_node_selector => |selector| if (selector.keys.len == 1)
            try alloc.dupe(u8, selector.keys[0])
        else
            error.UnsupportedGraphAgentStart,
        else => error.UnsupportedGraphAgentStart,
    };
}

/// Convert a public graph-agent request into the runtime configuration used by
/// the bounded executor.
pub fn runOpenApi(alloc: std.mem.Allocator, config: anytype, runner: Runner) !Result {
    const start_key = try startKeyFromOpenApi(config, alloc);
    defer alloc.free(start_key);
    const chains = try chainsFromOpenApi(alloc, config);
    defer freeChains(alloc, chains);
    return try runWithChain(alloc, .{
        .user_query = config.query,
        .instruction = config.instruction orelse "Choose the next graph node or finish the task.",
        .max_steps = @intCast(config.max_steps orelse default_max_steps),
        .neighbor_limit = @intCast(config.neighbor_limit orelse default_neighbor_limit),
    }, start_key, chains, runner);
}

pub const Runner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load_node: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, key: []const u8) anyerror!Node,
        list_neighbors: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, key: []const u8, limit: u32) anyerror![]Node,
        generate: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, chain: []const generating.ChainLink, messages: []const generating.ChatMessage) anyerror!generating.GenerateResult,
    };
};

const Decision = struct {
    done: bool = false,
    next_key: ?[]const u8 = null,
    answer: ?[]const u8 = null,
};

/// Execute one bounded, single-branch graph walk. The model is only allowed
/// to select a key returned by `list_neighbors`; it cannot invent edges.
pub fn run(alloc: std.mem.Allocator, config: Config, start_key: []const u8, runner: Runner) !Result {
    return runWithChain(alloc, config, start_key, &.{}, runner);
}

pub fn runWithChain(alloc: std.mem.Allocator, config: Config, start_key: []const u8, chains: []const generating.ChainLink, runner: Runner) !Result {
    if (config.max_steps == 0 or config.max_steps > 64 or config.neighbor_limit == 0 or config.neighbor_limit > 256)
        return error.InvalidGraphAgentRequest;

    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();
    try visited.put(start_key, {});

    var steps = std.ArrayListUnmanaged(TraceStep).empty;
    errdefer {
        for (steps.items) |*step| step.deinit(alloc);
        steps.deinit(alloc);
    }

    var current_key = try alloc.dupe(u8, start_key);
    errdefer alloc.free(current_key);
    var final_answer: ?[]const u8 = null;
    var completed = false;

    var step_index: u32 = 0;
    while (step_index < config.max_steps) : (step_index += 1) {
        var current = try runner.vtable.load_node(runner.ptr, alloc, current_key);
        defer current.deinit(alloc);
        const neighbors = try runner.vtable.list_neighbors(runner.ptr, alloc, current_key, config.neighbor_limit);
        defer {
            for (neighbors) |*node| node.deinit(alloc);
            if (neighbors.len > 0) alloc.free(neighbors);
        }

        const prompt = try buildPrompt(alloc, config, current, neighbors);
        defer alloc.free(prompt);
        const messages = [_]generating.ChatMessage{
            .{ .role = .system, .content = .{ .text = config.instruction } },
            .{ .role = .user, .content = .{ .text = prompt } },
        };
        var final_generation = try runner.vtable.generate(runner.ptr, alloc, chains, &messages);
        defer final_generation.deinit();
        if (final_generation.tool_calls.len > 0) return error.GraphAgentToolsUnsupported;

        var parsed = std.json.parseFromSlice(Decision, alloc, final_generation.content, .{}) catch
            return error.InvalidGraphAgentDecision;
        defer parsed.deinit();
        const decision = parsed.value;

        const selected_key = if (decision.next_key) |key| try alloc.dupe(u8, key) else null;
        try steps.append(alloc, .{
            .from_key = try alloc.dupe(u8, current_key),
            .selected_key = selected_key,
            .model_output = try alloc.dupe(u8, final_generation.content),
        });

        if (decision.done) {
            if (decision.answer) |answer| final_answer = try alloc.dupe(u8, answer);
            completed = true;
            break;
        }

        const next_key = decision.next_key orelse return error.GraphAgentDecisionMissingNext;
        var is_neighbor = false;
        for (neighbors) |neighbor| {
            if (std.mem.eql(u8, neighbor.key, next_key)) {
                is_neighbor = true;
                break;
            }
        }
        if (!is_neighbor) return error.GraphAgentDecisionNotNeighbor;
        if (visited.contains(next_key)) return error.GraphAgentCycle;
        try visited.put(next_key, {});
        alloc.free(current_key);
        current_key = try alloc.dupe(u8, next_key);
    }

    if (!completed) return error.GraphAgentStepLimitExceeded;
    return .{
        .final_key = current_key,
        .answer = final_answer,
        .steps = try steps.toOwnedSlice(alloc),
    };
}

fn buildPrompt(alloc: std.mem.Allocator, config: Config, current: Node, neighbors: []const Node) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    const header = try std.fmt.allocPrint(alloc,
        "User request:\n{s}\n\nCurrent node ({s}):\n{s}\n\nNeighbors:\n",
        .{ config.user_query, current.key, current.document_json },
    );
    defer alloc.free(header);
    try out.appendSlice(alloc, header);
    for (neighbors) |neighbor| {
        const line = try std.fmt.allocPrint(alloc, "- key: {s}\ndocument: {s}\n", .{ neighbor.key, neighbor.document_json });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    try out.appendSlice(alloc, "\nReturn JSON only with this shape: {\"done\":true|false,\"next_key\":string|null,\"answer\":string|null}. If done is false, next_key must be one of the listed neighbor keys.");
    return try out.toOwnedSlice(alloc);
}

test "graph agent follows a model-selected neighbor" {
    const Fake = struct {
        fn load(_: *anyopaque, alloc: std.mem.Allocator, key: []const u8) !Node {
            return .{ .key = try alloc.dupe(u8, key), .document_json = try alloc.dupe(u8, "{}") };
        }
        fn neighbors(_: *anyopaque, alloc: std.mem.Allocator, key: []const u8, _: u32) ![]Node {
            if (std.mem.eql(u8, key, "a")) return try alloc.dupe(Node, &.{.{ .key = try alloc.dupe(u8, "b"), .document_json = try alloc.dupe(u8, "{}") }});
            return try alloc.dupe(Node, &.{});
        }
        fn generate(_: *anyopaque, alloc: std.mem.Allocator, _: []const generating.ChainLink, messages: []const generating.ChatMessage) !generating.GenerateResult {
            const prompt = messages[1].content.?.text;
            const body = if (std.mem.indexOf(u8, prompt, "Current node (a)") != null)
                "{\"done\":false,\"next_key\":\"b\"}"
            else
                "{\"done\":true,\"answer\":\"finished\"}";
            return .{ .content = try alloc.dupe(u8, body), .allocator = alloc };
        }
    };
    var fake: u8 = 0;
    var result = try run(std.testing.allocator, .{ .user_query = "go" }, "a", .{ .ptr = &fake, .vtable = &.{ .load_node = Fake.load, .list_neighbors = Fake.neighbors, .generate = Fake.generate } });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("b", result.final_key);
    try std.testing.expectEqualStrings("finished", result.answer.?);
    try std.testing.expectEqual(@as(usize, 2), result.steps.len);
}

test "graph agent rejects a model-selected non-neighbor" {
    const Fake = struct {
        fn load(_: *anyopaque, alloc: std.mem.Allocator, key: []const u8) !Node {
            return .{ .key = try alloc.dupe(u8, key) };
        }
        fn neighbors(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: u32) ![]Node {
            return try alloc.dupe(Node, &.{});
        }
        fn generate(_: *anyopaque, alloc: std.mem.Allocator, _: []const generating.ChainLink, _: []const generating.ChatMessage) !generating.GenerateResult {
            return .{ .content = try alloc.dupe(u8, "{\"next_key\":\"invented\"}"), .allocator = alloc };
        }
    };
    var fake: u8 = 0;
    try std.testing.expectError(error.GraphAgentDecisionNotNeighbor, run(std.testing.allocator, .{ .user_query = "go" }, "a", .{ .ptr = &fake, .vtable = &.{ .load_node = Fake.load, .list_neighbors = Fake.neighbors, .generate = Fake.generate } }));
}

test "graph agent enforces the step limit" {
    const Fake = struct {
        fn load(_: *anyopaque, alloc: std.mem.Allocator, key: []const u8) !Node {
            return .{ .key = try alloc.dupe(u8, key) };
        }
        fn neighbors(_: *anyopaque, alloc: std.mem.Allocator, key: []const u8, _: u32) ![]Node {
            const next = if (std.mem.eql(u8, key, "a")) "b" else "a";
            return try alloc.dupe(Node, &.{.{ .key = try alloc.dupe(u8, next) }});
        }
        fn generate(_: *anyopaque, alloc: std.mem.Allocator, _: []const generating.ChainLink, _: []const generating.ChatMessage) !generating.GenerateResult {
            return .{ .content = try alloc.dupe(u8, "{\"done\":false,\"next_key\":\"b\"}"), .allocator = alloc };
        }
    };
    var fake: u8 = 0;
    try std.testing.expectError(error.GraphAgentStepLimitExceeded, run(std.testing.allocator, .{ .user_query = "go", .max_steps = 1 }, "a", .{ .ptr = &fake, .vtable = &.{ .load_node = Fake.load, .list_neighbors = Fake.neighbors, .generate = Fake.generate } }));
}

test "graph agent result serializes as a graph result value" {
    var result = Result{
        .final_key = try std.testing.allocator.dupe(u8, "doc:b"),
        .answer = try std.testing.allocator.dupe(u8, "done"),
        .steps = try std.testing.allocator.alloc(TraceStep, 1),
    };
    result.steps[0] = .{
        .from_key = try std.testing.allocator.dupe(u8, "doc:a"),
        .selected_key = try std.testing.allocator.dupe(u8, "doc:b"),
        .model_output = try std.testing.allocator.dupe(u8, "{\"done\":false}"),
    };
    defer result.deinit(std.testing.allocator);
    const encoded = try result.jsonAlloc(std.testing.allocator, true);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"agent\",\"final_key\":\"doc:b\",\"answer\":\"done\",\"steps\":[{\"from_key\":\"doc:a\",\"selected_key\":\"doc:b\",\"model_output\":\"{\\\"done\\\":false}\"}]}",
        encoded,
    );
}
