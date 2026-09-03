// oop_test.mc — o programa que so o compilador deste exemplo compila.
// Usa tudo o que examples/api/oop.mc ensina: uma interface com dois metodos,
// duas classes que a implementam, despacho por ponteiro de interface, uma
// classe sem interface com campos i64/str/bool e acessoras set/get.
//
//   make -C examples/api test-oop
//
// Com o compilador padrao (build/mc1) ele falha na primeira declaracao:
// `interface` la e so um identificador.
// expect-exit: 42
// expect-stdout: [x] comprar pao #10
// expect-stdout: rect area=20
// expect-stdout: circ area=12
// expect-stdout: total=42

#include "../../../lib/sys.mc"
#include "../../../lib/prelude.mc"

// ---- runtime minimo do programa ----
// `nome_new()` chama rt_alloc(n) e conta com memoria ZERADA. Aqui isso sai de
// graca: `heap` e uma global sem inicializador (vai zerada para o __bss) e o
// ponteiro so anda para a frente, nunca reaproveita. A versao de verdade e
// examples/api/lib/rt.mc.
#define HEAPSZ 65536

u8  heap[HEAPSZ];
i64 heap_used = 0;

uptr rt_alloc(i64 n) {
    n = (n + 7) & ~7;                            // objetos sempre alinhados a 8
    if (heap_used + n > HEAPSZ) {
        puts("rt_alloc: heap cheio\n");
        exit(1);
    }
    uptr p = heap + heap_used;
    heap_used = heap_used + n;
    return p;
}

// ---- uma interface com dois metodos ----
interface Shape {
    i64 area(self);
    str nome(self);
}

// ---- duas classes que a implementam ----
class Rect : Shape {
    i64 w;
    i64 h;

    i64 area(self) { return rect_w(self) * rect_h(self); }
    str nome(self) { return "rect"; }
}

class Circle : Shape {
    i64 r;

    // 3 no lugar de pi: o nucleo so tem inteiro
    i64 area(self) { return 3 * circle_r(self) * circle_r(self); }
    str nome(self) { return "circ"; }
}

// ---- uma classe sem interface, com campos i64 / str / bool ----
class Todo {
    i64  id;
    str  title;
    bool done;

    // metodo com `self` implicito: le o proprio campo pela acessora gerada
    str label(self) {
        if (todo_done(self)) return "[x] ";
        return "[ ] ";
    }
}

i64 main() {
    // classe sem interface: construtor, set_* e *_
    Todo t = todo_new();
    set_todo_id(t, 10);
    set_todo_title(t, "comprar pao");
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

    // despacho por ponteiro de interface: o mesmo par de chamadas atinge
    // rect_area/rect_nome e circle_area/circle_nome, pela vtable de cada objeto
    Shape lista[2];
    st64(lista, r);
    st64(lista + 8, c);

    i64 soma = 0;
    i64 i = 0;
    while (i < 2) {
        Shape s = ld64(lista + i * 8);
        puts(shape_nome(s));
        puts(" area=");
        putnum(shape_area(s));
        puts("\n");
        soma += shape_area(s);
        i += 1;
    }

    if (todo_done(t)) soma += todo_id(t);        // 20 + 12 + 10

    puts("total=");
    putnum(soma);
    puts("\n");
    return soma;
}
