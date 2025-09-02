const std = @import("std");

// The 0.15+ std list types don't benefit for this project,
// so we use the old implementation.

pub fn List(comptime Value: type) type {
    return struct {
        // size is 3 words.
        //info: ?struct {
        //    head: *Element,
        //    tail: *Element,
        //} = null,

        // size is 2 words.
        head: ?*Element = null,
        tail: ?*Element = null,

        pub const Element = struct {
            value: Value = undefined,
            prev: ?*Element = null,
            next: ?*Element = null,
        };

        const Self = @This();

        pub fn empty(self: *const Self) bool {
            std.debug.assert((self.head == null) == (self.tail == null));
            return self.head == null;
        }

        // e must not be in any list.
        pub fn pushTail(self: *Self, e: *Element) void {
            if (self.tail) |tail| {
                tail.next = e;
                e.prev = tail;
                self.tail = e;
            } else {
                self.head = e;
                self.tail = e;
                e.prev = null;
            }
            e.next = null;
        }

        pub fn popTail(self: *Self) ?*Element {
            if (self.tail) |tail| {
                if (tail.prev) |prev| {
                    prev.next = null;
                    self.tail = prev;
                } else {
                    self.head = null;
                    self.tail = null;
                }
                return tail;
            }

            return null;
        }

        // e must not be in any list.
        pub fn pushHead(self: *Self, e: *Element) void {
            if (self.head) |head| {
                head.prev = e;
                e.next = head;
                self.head = e;
            } else {
                self.head = e;
                self.tail = e;
                e.next = null;
            }
            e.prev = null;
        }

        pub fn popHead(self: *Self) ?*Element {
            if (self.head) |head| {
                if (head.next) |next| {
                    next.prev = null;
                    self.head = next;
                } else {
                    self.head = null;
                    self.tail = null;
                }
                return head;
            }

            return null;
        }

        pub fn delete(self: *Self, e: *Element) void {
            if (self.head) |head| {
                if (e == head) {
                    _ = self.popHead();
                    return;
                }
                if (e == self.tail) {
                    _ = self.popTail();
                    return;
                }
                e.prev.?.next = e.next;
                e.next.?.prev = e.prev;
            } else unreachable;
        }

        // For lacking of closure support, the pattern of using callback functions
        // is often not very useful. Try to only use this method in tests.
        pub fn iterate(self: Self, comptime f: fn (*Value) void) void {
            if (self.head) |head| {
                var element = head;
                while (true) {
                    const next = element.next;
                    f(&element.value);
                    if (next) |n| element = n else break;
                }
            }
        }

        // For testing purpose.
        pub fn size(self: Self) usize {
            var k: usize = 0;
            if (self.head) |head| {
                var element = head;
                while (true) {
                    k += 1;
                    if (element.next) |n| element = n else break;
                }
            }
            return k;
        }

        // Please make sure all list elements are created by the allocator.
        pub fn destroy(self: *Self, comptime onNodeValue: ?fn (*Value, std.mem.Allocator) void, allocator: std.mem.Allocator) void {
            var element = self.head;
            if (onNodeValue) |f| {
                while (element) |e| {
                    const next = e.next;
                    f(&e.value, allocator);
                    allocator.destroy(e);
                    element = next;
                }
            } else while (element) |e| {
                const next = e.next;
                allocator.destroy(e);
                element = next;
            }
            self.* = .{};
        }

        pub fn createElement(self: *Self, allocator: std.mem.Allocator, comptime push: bool) !*Element {
            const element = try allocator.create(Element);
            if (push) self.pushTail(element);
            return element;
        }

    };
}



test "list" {
    const T = struct {
        var lst: *List(u32) = undefined;
        var sum: u32 = undefined;

        fn f(v: *const u32) void {
            sum += v.*;
        }

        fn sumList() u32 {
            sum = 0;
            lst.iterate(f);
            return sum;
        }
    };

    var l: List(u32) = .{};
    try std.testing.expect(l.empty());
    try std.testing.expect(l.head == null);
    try std.testing.expect(l.tail == null);

    T.lst = &l;
    try std.testing.expect(T.sumList() == 0);

    var elements: [3]List(u32).Element = .{ .{ .value = 0 }, .{ .value = 1 }, .{ .value = 2 } };
    l.pushTail(&elements[0]);
    try std.testing.expect(!l.empty());
    try std.testing.expect(l.head != null);
    try std.testing.expect(l.tail != null);
    try std.testing.expect(T.sumList() == 0);

    l.pushHead(&elements[1]);
    l.pushTail(&elements[2]);
    try std.testing.expect(l.head.?.value == 1);
    try std.testing.expect(l.tail.?.value == 2);
    try std.testing.expect(T.sumList() == 3);

    try std.testing.expect(l.popHead().?.value == 1);
    try std.testing.expect(T.sumList() == 2);
    try std.testing.expect(l.popTail().?.value == 2);
    try std.testing.expect(T.sumList() == 0);
    try std.testing.expect(l.head != null);
    try std.testing.expect(l.tail != null);
    try std.testing.expect(l.head == l.tail);
    try std.testing.expect(l.head.?.value == 0);
    try std.testing.expect(l.tail.?.value == 0);
    try std.testing.expect(l.popTail().?.value == 0);
    try std.testing.expect(l.empty());
    try std.testing.expect(l.head == null);
    try std.testing.expect(l.tail == null);
    try std.testing.expect(T.sumList() == 0);

    l.pushTail(&elements[1]);
    try std.testing.expect(!l.empty());
    try std.testing.expect(T.sumList() == 1);

    l.delete(&elements[1]);
    try std.testing.expect(l.empty());
    try std.testing.expect(T.sumList() == 0);
}
