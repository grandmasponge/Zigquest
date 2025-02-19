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

const Http_Request = struct {
    uri: std.Uri,
    method: Method = Method.GET,
    version: Http_version = Http_version.first,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    pub fn request_builder(allocator: std.mem.Allocator, url: []const u8, method: Method, version: Http_version, headers: ?std.StringHashMap([]const u8), body: ?[]const u8) Http_Request {
        var default_headers = std.StringHashMap([]const u8).init(allocator);
        const uri = try std.Uri.parse(url);
        if (headers != null) {
            const header_values = headers.?;
            var header_iterator = header_values.iterator();
            while (header_iterator.next()) |entry| {
                try default_headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        const host = default_headers.get("Host");
        if (host != null) {
            const host_value = host.?;
            try default_headers.put("Host", host_value);
        } else {
            try default_headers.put("Host", uri.host);
        }

        if (default_headers.get("Connection") == null) {
            try default_headers.put("Connection", "close");
        }

        if (default_headers.get("User-Agent") == null) {
            try default_headers.put("User-Agent", "Zig/0.13.0");
        }

        if (body != null) {
            const len = body.?.len;
            var buf = try allocator.alloc(u8, 10);
            try std.fmt.bufPrint(&buf, "{s}", .{len});
            default_headers.put("Content-Length", buf);
        }

        return Http_Request{
            .uri = uri,
            .method = method,
            .version = version,
            .headers = default_headers,
            .body = body,
        };
    }

    pub fn send(self: Http_Request, connection: std.net.Stream) void {
        var writer = connection.writer();
        //write all of the request to the Stream
        const method_string = self.method.toString();
        const path = self.uri.path.raw;
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method_string, path });
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

    pub fn response(allocator: std.mem.Allocator, connection: std.net.Stream) void {
        var reader = connection.reader();
        var buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);
        const bytes_read = try reader.read(buffer);
        std.debug.print("{s}", .{buffer[0..bytes_read]});
    }
};

pub fn main() !void {
    var gal = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gal.deinit();

    const allocator = gal.allocator();

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("Content-Type", "text/html");

    const stream = try std.net.tcpConnectToHost(allocator, "httpforever.com", 80);

    var http_req = Http_Request.request_builder(allocator, "http://httpforever.com", Method.GET, Http_version.first, headers, null);
    http_req.send(stream);
    std.time.sleep(1000);
    http_req.response(allocator, stream);
}
