const std = @import("std");
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

const Method = enum {
    POST,
    GET,
    HEAD,
    OPTIONS,
    PUT,
    DELETE,
    CONNECT,
    TRACE,
    PATCH,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .POST => "POST",
            .GET => "GET",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .CONNECT => "CONNECT",
            .TRACE => "TRACE",
            .PATCH => "PATCH",
        };
    }
};

const Http_version = enum {
    first,
    second,
};

const Http_Response = struct {
    status: i32,
    version: []const u8,
    status_message: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    pub fn decode_http_response(allocator: std.mem.Allocator, response: []u8) !Http_Response {
        var lines = std.mem.split(u8, response, "\r\n");
        var headers = std.StringHashMap([]const u8).init(allocator);

        const status_line = lines.next() orelse return error.InvalidResponse;
        var status_parts = std.mem.split(u8, status_line, " ");

        const http_version = try allocator.dupe(u8, status_parts.next() orelse return error.InvalidResponse);
        const status_code_str = status_parts.next() orelse return error.InvalidResponse;
        const status_code = try std.fmt.parseInt(i32, status_code_str, 10);
        const status_message = try allocator.dupe(u8, status_parts.rest());

        while (lines.next()) |line| {
            if (line.len == 0) {
                break;
            }

            var header_parts = std.mem.split(u8, line, ": ");
            const header_name = try allocator.dupe(u8, header_parts.next() orelse return error.InvalidHeader);
            const header_value = try allocator.dupe(u8, header_parts.rest());

            try headers.put(header_name, header_value);
        }

        var body: []const u8 = "";

        if (lines.rest().len != 0) {
            body = try allocator.dupe(u8, lines.rest());
        }

        return Http_Response{
            .status_message = status_message,
            .status = status_code,
            .version = http_version,
            .headers = headers,
            .body = body,
        };
    }
};

const Http_Request = struct {
    uri: std.Uri,
    method: Method = Method.GET,
    version: Http_version = Http_version.first,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    pub fn request_builder(allocator: std.mem.Allocator, url: []const u8, method: Method, version: Http_version, headers: ?std.StringHashMap([]const u8), body: ?[]const u8) !Http_Request {
        var default_headers = std.StringHashMap([]const u8).init(allocator);
        const uri = try std.Uri.parse(url);

        if (headers != null) {
            const header_values = headers.?;
            var header_iterator = header_values.iterator();
            while (header_iterator.next()) |entry| {
                try default_headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        const host = uri.host orelse return error.MissingHost;

        const host_str = switch (host) {
            .raw => host.raw,
            .percent_encoded => host.percent_encoded,
        };
        if (default_headers.get("Host") == null) {
            try default_headers.put("Host", host_str);
        }

        if (default_headers.get("Connection") == null) {
            try default_headers.put("Connection", "close");
        }

        if (default_headers.get("User-Agent") == null) {
            try default_headers.put("User-Agent", "Zig/0.13.0");
        }

        if (body != null) {
            const len = body.?.len;
            var buf: [20]u8 = undefined;
            const len_str = try std.fmt.bufPrint(&buf, "{}", .{len});
            try default_headers.put("Content-Length", len_str);
        }

        return Http_Request{
            .uri = uri,
            .method = method,
            .version = version,
            .headers = default_headers,
            .body = body,
        };
    }

    pub fn send(self: Http_Request, ssl: ?*c.struct_ssl_st, allocator: std.mem.Allocator) !void {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        const method_string = self.method.toString();
        const path = "/grandmasponge";
        const version_string = switch (self.version) {
            .first => "HTTP/1.1",
            .second => "HTTP/2.0",
        };
        try writer.print("{s} {s} {s}\r\n", .{ method_string, path, version_string });

        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            try writer.print("{s}: {s}\r\n", .{ key, value });
        }
        try writer.writeAll("\r\n");

        if (self.body != null) {
            const value = self.body.?;
            try writer.writeAll(value);
        }

        const slice = buf.items;
        _ = c.SSL_write(ssl, slice.ptr, @intCast(slice.len));
    }

    pub fn response(_: Http_Request, allocator: std.mem.Allocator, ssl: ?*c.struct_ssl_st) !Http_Response {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var chunk: [1024]u8 = undefined;

        while (true) {
            const bytes_read = c.SSL_read(ssl, &chunk, 1024);
            if (bytes_read == 0) {
                break;
            }
            try buffer.appendSlice(&chunk);
        }

        const res = try Http_Response.decode_http_response(allocator, buffer.items);

        return res;
    }
};

const client = struct {};

pub fn init_ssl() void {
    _ = c.OPENSSL_init_ssl(0, null);
}

pub fn create_ssl_ctx() !?*c.struct_ssl_ctx_st {
    const method = c.TLS_client_method();
    const ctx = c.SSL_CTX_new(method);

    if (ctx == null) {
        std.debug.print("failed to initalize ssl context", .{});
        return error.failed_ssl;
    }

    _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);
    _ = c.SSL_CTX_set_max_proto_version(ctx, c.TLS1_3_VERSION);

    return ctx;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const host = "github.com";

    init_ssl();
    const ctx = try create_ssl_ctx();

    var sock = try std.net.tcpConnectToHost(allocator, host, 443);
    defer sock.close();

    const fd = sock.handle;

    const ssl = c.SSL_new(ctx);

    _ = c.SSL_set_fd(ssl, fd);

    _ = c.SSL_set_tlsext_host_name(ssl, host);

    if (c.SSL_connect(ssl) <= 0) {
        std.debug.print("failed to connect with ssl \n", .{});
        return;
    }
    //create our http request

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    const request = try Http_Request.request_builder(allocator, "https://github.com/grandmasponge", Method.GET, Http_version.first, headers, null);
    try request.send(ssl, allocator);

    std.time.sleep(2000000);

    var response = try request.response(allocator, ssl);
    defer response.headers.deinit();

    std.debug.print("{s} {} {s}\n", .{ response.version, response.status, response.status_message });

    var iterator = response.headers.iterator();
    while (iterator.next()) |entry| {
        std.debug.print("{s} {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    std.debug.print("{s}\n", .{response.body});

    c.SSL_CTX_free(ctx);
}
