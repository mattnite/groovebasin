const std = @import("std");

const browser = @import("browser.zig");
const env = @import("browser_env.zig");
const callback = @import("callback.zig");
const ui = @import("groovebasin_ui.zig");
const g = @import("global.zig");

const protocol = @import("shared").protocol;

var websocket_handle: i32 = undefined;

const LoadingState = enum {
    none,
    connecting,
    connected,
    backoff,
};
var loading_state: LoadingState = .none;

pub fn open() void {
    std.debug.assert(loading_state == .none);
    loading_state = .connecting;

    const allocator_callback = callback.allocator(g.gpa);
    env.openWebSocket(
        allocator_callback.callback,
        allocator_callback.context,
        &onOpenCallback,
        undefined,
        &onCloseCallback,
        undefined,
        &onErrorCallback,
        undefined,
        &onMessageCallback,
        undefined,
    );
}

fn onOpenCallback(context: callback.Context, handle: i32) void {
    _ = context;
    browser.print("zig: websocket opened");

    std.debug.assert(loading_state == .connecting);
    loading_state = .connected;
    websocket_handle = handle;
    ui.setLoadingState(.good);

    periodic_ping_handle = env.setInterval(&periodicPingCallback, undefined, periodic_ping_interval_ms);
    periodicPingAndCatch();
}

var next_seq_id: u32 = 0;
fn generateSeqId() u32 {
    defer {
        next_seq_id += 1;
        next_seq_id &= 0x7fff_ffff;
    }
    return next_seq_id;
}

const ResponseHandler = struct {
    cb: *const fn (context: callback.Context, response: []const u8) void,
    context: callback.Context,
};
var pending_requests: std.AutoHashMapUnmanaged(u32, ResponseHandler) = .{};

pub const Call = struct {
    seq_id: u32,
    request: std.ArrayList(u8),
    pub fn init(opcode: protocol.Opcode) !@This() {
        var self = @This(){
            .seq_id = generateSeqId(),
            .request = std.ArrayList(u8).init(g.gpa),
        };

        // write the request header.
        try self.request.writer().writeStruct(protocol.RequestHeader{
            .seq_id = self.seq_id,
            .op = opcode,
        });

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.request.deinit();
        self.response.deinit();
    }

    pub fn writer(self: *@This()) std.ArrayList(u8).Writer {
        return self.request.writer();
    }

    pub fn reader(self: *@This()) std.io.FixedBufferStream([]u8).Reader {
        return self.response.reader();
    }

    pub fn send(self: *@This(), cb: *const fn (context: callback.Context, response: []const u8) void, context: callback.Context) !void {
        const buffer = self.request.items;
        try pending_requests.put(g.gpa, self.seq_id, .{
            .cb = cb,
            .context = context,
        });
        browser.printHex("request: ", buffer);
        env.sendMessage(websocket_handle, buffer.ptr, buffer.len);
    }
};

pub fn ignoreResponseCallback(context: callback.Context, response: []const u8) void {
    _ = context;
    _ = response;
}

fn onCloseCallback(context: callback.Context, code: i32) void {
    _ = context;
    _ = code;
    browser.print("zig: websocket closed");
    handleNoConnection();
}

fn onErrorCallback(context: callback.Context) void {
    _ = context;
    browser.print("zig: websocket error");
    handleNoConnection();
}

fn onMessageCallback(context: callback.Context, buffer: []u8) void {
    _ = context;

    defer g.gpa.free(buffer);

    browser.printHex("response: ", buffer);

    var stream = std.io.fixedBufferStream(buffer);
    const reader = stream.reader();
    const header = reader.readStruct(protocol.ResponseHeader) catch |err| {
        @panic(@errorName(err));
    };
    const remaining_buffer = buffer[stream.pos..];

    if ((header.seq_id & 0x8000_0000) == 0) {
        // response to a request.

        const handler = (pending_requests.fetchRemove(header.seq_id) orelse {
            @panic("received a response for unrecognized seq_id");
        }).value;

        handler.cb.*(handler.context, remaining_buffer);
    } else {
        // message from the server.
        handlePushMessageAndCatch(remaining_buffer);
    }
}

const retry_timeout_ms = 1000;
fn handleNoConnection() void {
    if (loading_state == .backoff) return;
    loading_state = .backoff;
    ui.setLoadingState(.no_connection);

    env.clearTimer(periodic_ping_handle.?);
    _ = env.setTimeout(&retryOpenCallback, undefined, retry_timeout_ms);
}

fn retryOpenCallback(context: callback.Context) void {
    _ = context;
    if (loading_state != .backoff) return;
    loading_state = .none;
    open();
}

var periodic_ping_handle: ?i64 = null;
const periodic_ping_interval_ms = 10_000;
fn periodicPingCallback(context: callback.Context) void {
    _ = context;
    periodicPingAndCatch();
}
fn periodicPingAndCatch() void {
    periodicPing() catch |err| {
        @panic(@errorName(err));
    };
}
fn periodicPing() !void {
    {
        var ping_call = try Call.init(.ping);
        try ping_call.send(&handlePeriodicPingResponseCallback, undefined);
    }

    // Also by the way, let's query for the data or something.
    try ui.poll();
}

fn handlePeriodicPingResponseCallback(context: callback.Context, response: []const u8) void {
    _ = context;
    handlePeriodicPingResponse(response) catch |err| {
        @panic(@errorName(err));
    };
}
fn handlePeriodicPingResponse(response: []const u8) !void {
    var stream = std.io.fixedBufferStream(response);
    const milliseconds = env.getTime();
    const client_ns = @as(i128, milliseconds) * 1_000_000;
    const server_ns = try stream.reader().readIntLittle(i128);
    const lag_ns = client_ns - server_ns;
    ui.setLag(lag_ns);
}

fn handlePushMessageAndCatch(response: []const u8) void {
    handlePushMessage(response) catch |err| {
        @panic(@errorName(err));
    };
}
fn handlePushMessage(response: []const u8) !void {
    var stream = std.io.fixedBufferStream(response);
    const header = try stream.reader().readStruct(protocol.PushMessageHeader);
    _ = header;

    // it just means do this:
    periodicPingAndCatch();
}
