// oop_test.mc — the program that only this example's compiler compiles.
// Uses everything examples/api/oop.mc teaches: an interface with two methods,
// two classes that implement it, dispatch via an interface pointer, a class
// with no interface with i64/str/bool fields and set/get accessors.
//
//   make -C examples/api test-oop
//
// With the default compiler (build/mc1) it fails at the first declaration:
// `interface` there is just an identifier.
// expect-exit: 42
// expect-stdout: [x] buy bread #10
// expect-stdout: rect area=20
// expect-stdout: circ area=12
// expect-stdout: total=42

#include "../../../lib/sys.mc"
#include "../../../lib/prelude.mc"

// ---- the program's minimal runtime ----
// `name_new()` calls rt_alloc(n) and counts on ZEROED memory. Here that comes
// for free: `heap` is a global with no initializer (goes to the __bss,
// zeroed) and the pointer only moves forward, never reusing space. The real
// version is examples/api/lib/rt.mc.
#define HEAPSZ 65536

u8  heap[HEAPSZ];
i64 heap_used = 0;

uptr rt_alloc(i64 n) {
    n = (n + 7) & ~7;                            // objects always aligned to 8
    if (heap_used + n > HEAPSZ) {
        puts("rt_alloc: heap full\n");
        exit(1);
    }
    uptr p = heap + heap_used;
    heap_used = heap_used + n;
    return p;
}

// ---- an interface with two methods ----
interface Shape {
    i64 area(self);
    str name(self);
}

// ---- two classes that implement it ----
class Rect : Shape {
    i64 w;
    i64 h;

    i64 area(self) { return rect_w(self) * rect_h(self); }
    str name(self) { return "rect"; }
}

class Circle : Shape {
    i64 r;

    // 3 in place of pi: the core only has integers
    i64 area(self) { return 3 * circle_r(self) * circle_r(self); }
    str name(self) { return "circ"; }
}

// ---- a class with no interface, with i64 / str / bool fields ----
class Todo {
    i64  id;
    str  title;
    bool done;

    // method with implicit `self`: reads its own field via the generated accessor
    str label(self) {
        if (todo_done(self)) return "[x] ";
        return "[ ] ";
    }
}

i64 main() {
    // class with no interface: constructor, set_* and *_
    Todo t = todo_new();
    set_todo_id(t, 10);
    set_todo_title(t, "buy bread");
    set_todo_done(t, 1);

    puts(todo_label(t));
    puts(todo_title(t));
    puts(" #");
    putnum(todo_id(t));
    puts("\n");

    Rect r = rect_new();
    set_rect_w(r, 4);
    set_rect_h(r, 5);

    Circle c = circle_new();
    set_circle_r(c, 2);

    // dispatch via interface pointer: the same pair of calls reaches
    // rect_area/rect_name and circle_area/circle_name, through each object's vtable
    Shape list[2];
    st64(list, r);
    st64(list + 8, c);

    i64 sum = 0;
    i64 i = 0;
    while (i < 2) {
        Shape s = ld64(list + i * 8);
        puts(shape_name(s));
        puts(" area=");
        putnum(shape_area(s));
        puts("\n");
        sum += shape_area(s);
        i += 1;
    }

    if (todo_done(t)) sum += todo_id(t);        // 20 + 12 + 10

    puts("total=");
    putnum(sum);
    puts("\n");
    return sum;
}
