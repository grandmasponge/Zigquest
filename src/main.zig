const std = @import("std");

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

    pub fn send(self: Http_Request, connection: std.net.Stream) !void {
        var writer = connection.writer();
        const method_string = self.method.toString();
        const path = "/";
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
    }

    pub fn response(_: Http_Request, allocator: std.mem.Allocator, connection: std.net.Stream) !Http_Response {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var reader = connection.reader();
        var chunk: [1024]u8 = undefined;

        while (true) {
            const bytes_read = try reader.read(chunk[0..]);
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("Content-Type", "text/html");

    const stream = try std.net.tcpConnectToHost(allocator, "neal.fun", 80);
    defer stream.close();

    var http_req = try Http_Request.request_builder(allocator, "https://neal.fun", Method.GET, Http_version.first, headers, null);
    try http_req.send(stream);

    var res = try http_req.response(allocator, stream);
    std.debug.print("Http Version {s} status code {} status message {s}\n", .{ res.version, res.status, res.status_message });

    var iterator = res.headers.iterator();
    while (iterator.next()) |entry| {
        std.debug.print("Header {s} : Value {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    std.debug.print("{s}\r\n", .{res.body});

    headers.deinit();
    res.headers.deinit();
}
