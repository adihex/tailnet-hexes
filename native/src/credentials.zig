//! Only macOS persists credentials in this milestone. Other targets are session-only.
//! There is deliberately no plaintext-file fallback.
const std = @import("std");
const mac = @import("builtin").os.tag == .macos;
const objc = if (mac) @import("nanoui").objc else struct {};

extern "Security" fn SecItemCopyMatching(query: *anyopaque, result: *?*anyopaque) i32;
extern "Security" fn SecItemAdd(attributes: *anyopaque, result: ?*?*anyopaque) i32;
extern "Security" fn SecItemUpdate(query: *anyopaque, attributes: *anyopaque) i32;
extern "Security" fn SecItemDelete(query: *anyopaque) i32;
extern "Security" var kSecClass: *anyopaque;
extern "Security" var kSecClassGenericPassword: *anyopaque;
extern "Security" var kSecAttrService: *anyopaque;
extern "Security" var kSecAttrAccount: *anyopaque;
extern "Security" var kSecValueData: *anyopaque;
extern "Security" var kSecReturnData: *anyopaque;
extern "Security" var kSecUseAuthenticationUI: *anyopaque;
extern "Security" var kSecUseAuthenticationUIFail: *anyopaque;

pub const persistent = mac;

pub fn erase(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

fn query(profile: []const u8) objc.Object {
    const q = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    objc.msg(void, q, "setObject:forKey:", .{ kSecClassGenericPassword, kSecClass });
    objc.msg(void, q, "setObject:forKey:", .{ objc.nsString("net.adihex.hexes.owner-token"), kSecAttrService });
    objc.msg(void, q, "setObject:forKey:", .{ objc.nsString(profile), kSecAttrAccount });
    return q;
}

pub fn load(gpa: std.mem.Allocator, profile: []const u8) !?[]u8 {
    if (comptime !mac) return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const q = query(profile);
    objc.msg(void, q, "setObject:forKey:", .{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{true}), kSecReturnData });
    // Never trigger a Keychain prompt just because a headless process started.
    objc.msg(void, q, "setObject:forKey:", .{ kSecUseAuthenticationUIFail, kSecUseAuthenticationUI });
    var value: ?*anyopaque = null;
    const status = SecItemCopyMatching(q, &value);
    if (status == -25300) return null;
    if (status != 0) return error.KeychainUnavailable;
    const data: objc.Object = @ptrCast(value orelse return null);
    defer objc.release(data);
    const len = objc.msg(usize, data, "length", .{});
    const bytes = objc.msg([*]const u8, data, "bytes", .{});
    return try gpa.dupe(u8, bytes[0..len]);
}

pub fn save(profile: []const u8, token: []const u8) !void {
    if (comptime !mac) return error.PersistenceUnavailable;
    const pool = objc.Pool.push();
    defer pool.pop();
    const q = query(profile);
    const attrs = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ token.ptr, token.len });
    objc.msg(void, attrs, "setObject:forKey:", .{ data, kSecValueData });
    const status = SecItemUpdate(q, attrs);
    if (status == -25300) {
        objc.msg(void, q, "setObject:forKey:", .{ data, kSecValueData });
        if (SecItemAdd(q, null) != 0) return error.KeychainUnavailable;
    } else if (status != 0) return error.KeychainUnavailable;
}

pub fn forget(profile: []const u8) !void {
    if (comptime !mac) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const status = SecItemDelete(query(profile));
    if (status != 0 and status != -25300) return error.KeychainUnavailable;
}
