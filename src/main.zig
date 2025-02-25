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

    const statusData = struct {
        version: []const u8,
        status_code: i32,
        status_message: []const u8,
    };

    pub fn decode_status_line(string: []const u8) !statusData {
        var iterator = std.mem.splitSequence(u8, string, " ");
        const version = iterator.next().?;
        const status_code = try std.fmt.parseInt(i32, iterator.next().?, 10);
        const status_message = iterator.next().?;

        return statusData{
            .version = version,
            .status_code = status_code,
            .status_message = status_message,
        };
    }

    pub fn decode_http_response(response: std.ArrayList(u8)) !Http_Response {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        var headers = std.StringHashMap([]const u8).init(allocator);
        const slice = response.items;
        var iterator = std.mem.splitSequence(u8, slice, "\r\n");
        const status_line = iterator.next().?;
        const status_data = try decode_status_line(status_line);

        while (iterator.next()) |line| {
            if (line.len == 0) {
                break;
            }
            var header_split = std.mem.splitSequence(u8, line, ":");
            const key = header_split.next().?;
            const value = header_split.next().?;
            try headers.put(key, value);
        }

        const body = iterator.rest(); // Capture the entire remaining content as the body

        return Http_Response{
            .status = status_data.status_code,
            .version = status_data.version,
            .status_message = status_data.status_message,
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
        var reader = connection.reader();
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try reader.readAllArrayList(&buffer, 8192);
        const http_response = try Http_Response.decode_http_response(buffer);

        return http_response;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Content-Type", "text/html");

    const stream = try std.net.tcpConnectToHost(allocator, "httpforever.com", 80);
    defer stream.close();

    var http_req = try Http_Request.request_builder(allocator, "http://httpforever.com", Method.GET, Http_version.first, headers, null);
    try http_req.send(stream);
    std.time.sleep(5000);

    var response = try http_req.response(allocator, stream);
    defer response.headers.deinit();

    const body = response.body;
    std.debug.print("{s}\n", .{body});
}
