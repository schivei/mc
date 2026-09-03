# `examples/api` — uma API de todos escrita numa linguagem que o próprio exemplo ensina

Este diretório é a prova prática do **Tier 3** (M12, `docs/surface.md`): um servidor HTTP com
persistência em SQLite, escrito com `class`, `interface`, `bool` e `str` — quatro coisas que a
linguagem `mc` **não tem**. Elas são ensinadas aqui, num arquivo `.mc` de 458 linhas que roda
*dentro* do compilador, sem uma única linha alterada em `src/` ou `stage0/`.

O binário sai pelo `--exe` (M11): sem `ld`, com assinatura ad-hoc, ligado à `libsqlite3` do sistema
por `#dylib` (M12).

```
examples/api/
  mc-api.mc      o compilador deste diretorio: src/core.mc + oop.mc + user_init()
  oop.mc         ensina `class` e `interface` pela API publica do parser
  lib/rt.mc      arena fixa, strings, strbuf, itoa/atoi
  lib/http.mc    sockets, requisicao e resposta HTTP/1.1
  lib/sqlite.mc  #dylib "/usr/lib/libsqlite3.dylib" + externs + wrappers
  main.mc        a API: rotas, handlers, o banco — 359 linhas
  test.sh        sobe o servidor numa porta livre e bate em cada rota
  tests/         oop_test.mc (a sintaxe isolada) e lib_test.mc/.sh (as libs isoladas)
```

## 1. Ensinar o compilador

Um compilador ensinado é um **arquivo**, não uma edição de `src/`. `src/core.mc` é o compilador
inteiro menos exatamente uma função — `void user_init()` —, e é isso que `mc-api.mc` fornece:

```c
// mc-api.mc
#include "../../src/core.mc"
#include "oop.mc"

void user_init() {
    syntax("class", &oop_class);                 // declaracao de topo
    syntax("interface", &oop_interface);         // declaracao de topo
    type_alias("bool", TY_U8);                   // tipo novo, sem sintaxe nova
    type_alias("str", TY_UPTR);
}
```

`syntax(palavra, &f)` registra a palavra no lexer e diz ao `parse_top` que, ao vê-la, chame `f`.
`f` consome tokens com a API pública do parser (`p_id`, `p_next`, `p_type`, `p_ident`,
`parse_function`, `parse_block`, …) e entrega declarações por `top_add`. É só isso: nenhum modo
especial, nenhum hook mágico, nenhuma tabela de sintaxe embutida.

`oop.mc` usa essa API para transformar cada `class` e cada `interface` em declarações comuns:

| escrito em `main.mc` | gerado por `oop.mc` |
|---|---|
| `interface Handler {` | `type_alias("Handler", TY_UPTR)` |
| `  i64 handle(self, Request req, Response res);` | `#define HANDLER_HANDLE 0` · `i64 handler_handle(uptr self, uptr req, uptr res) { return callp(ld64(ld64(self) + 0), self, req, res); }` |
| `class Todo {` | `type_alias("Todo", TY_UPTR)` |
| `  i64 id;` | `#define TODO_ID 0` · `todo_id(self)` · `set_todo_id(self, v)` |
| `  str title;` | `#define TODO_TITLE 8` + as duas acessoras |
| `  bool done;` | `#define TODO_DONE 16` + acessoras com `ld8`/`st8` |
| `  str json(self) { … }` | `uptr todo_json(uptr self) { … }` — `self` prependido aos parâmetros |
| `}` | `#define TODO_SIZE 24` · `uptr todo_new()`, que chama `rt_alloc(TODO_SIZE)` |
| `class TodoHandler : Handler {` | palavra 0 do objeto reservada para a vtable; campos a partir de 8 |
| `}` (com interface) | `u8 todohandler_vt[8]` · `todohandler_vt_init()` (preenche com `&todohandler_handle`) · `todohandler_new()` (aloca, inicializa a vtable, grava na palavra 0) |

As sete declarações `class`/`interface` de `main.mc` viram **39 declarações** comuns — dá para ver
uma a uma:

```
$ build/mc-api --dump-ast main.mc | grep -E '^(FUNC|GLOBAL)'
...
FUNC type=uptr name=request_raw
FUNC          name=set_request_raw
FUNC type=uptr name=request_method
...
FUNC type=i64  name=handler_handle
FUNC type=uptr name=todohandler_db
FUNC type=i64  name=todohandler_handle
GLOBAL val=8 type=u8 name=todohandler_vt
FUNC          name=todohandler_vt_init
FUNC type=uptr name=todohandler_new
```

Um método da interface que a classe não implementa (ou implementa com outra aridade) é erro de
compilação, com arquivo e linha — este é de nível de classe, então aponta para a linha do `class`:

```
$ build/mc-api --exe falta.mc -o /tmp/x
falta.mc:5: metodo da interface nao implementado: nome
```

Erro de um membro específico aponta para a linha **do membro**, não para a abertura da declaração:

```
$ build/mc-api --exe dupfield.mc -o /tmp/x
dupfield.mc:11: #define repetido               # o terceiro campo repete o nome do primeiro
```

**Limite de parâmetros.** Um método de classe sem interface aceita `self` + 7 (é chamado direto por
`bl`, como qualquer função: `MAXPARAMS` é 8). Um método de **interface** aceita `self` + 6: o
despachante chama `callp(slot, self, ...)` e o ponteiro da vtable ocupa a primeira das 8 vagas do
`callp`. Passar disso é erro na linha do método:

```
$ build/mc-api --exe t.mc -o /tmp/x
t.mc:9: metodo com parametros demais (self conta; na interface, o ponteiro da vtable tambem)
```

**O compilador padrão recusa o mesmo fonte.** A sintaxe pertence a este diretório, não à linguagem:

```
$ ../../build/mc1 main.mc -o /tmp/x.o
main.mc:27: tipo esperado no parametro          # `str s` — `str` nao existe no nucleo
```

## 2. A API

Argumentos: `api PORTA CAMINHO_DO_BANCO`. Uma conexão por vez, sem keep-alive. Corpo sempre JSON.

| rota | resposta |
|---|---|
| `GET /health` | `200 {"ok":true}` |
| `GET /todos` | `200 [{"id":1,"title":"comprar pao","done":false}, …]` |
| `POST /todos` (corpo = título) | `201 {"id":N,"title":"…","done":false}` |
| `DELETE /todos/N` | `200 {"deleted":N}`, ou `404 {"error":"not found"}` |
| qualquer outra | `404 {"error":"not found"}` |

O roteamento é uma tabela linear de `(prefixo, Handler)` percorrida na ordem de registro. O laço
principal guarda `Handler`, nunca a classe concreta:

```c
Handler h = rota_find(p);
if (h != 0) handler_handle(h, rq, rs);           // vtable do objeto decide quem atende
else response_send(rs, 404, json_err("not found"));
```

`TodoHandler` carrega um `Db` (a classe em volta dos wrappers de `lib/sqlite.mc`); `HealthHandler`
não tem campo nenhum — só a palavra da vtable, 8 bytes.

## 3. Rodar

```
make -C examples/api mc-api     # build/mc-api  — o compilador (231907 bytes)
make -C examples/api api        # build/api     — o servidor  (55616 bytes)
make -C examples/api test       # test-oop + tests/lib_test.sh + test.sh
make -C examples/api clean
```

`make check` da raiz inclui tudo isto no alvo `check-examples`. Dependências: `../../build/mc1`
(a raiz o constrói se faltar), `curl` e `sqlite3`.

À mão:

```
$ examples/api/build/api 8080 /tmp/todos.db &
api: porta 8080, banco /tmp/todos.db
$ curl -s -X POST --data-binary 'comprar pao' localhost:8080/todos
{"id":1,"title":"comprar pao","done":false}
$ curl -s localhost:8080/todos
[{"id":1,"title":"comprar pao","done":false}]
$ curl -s -X DELETE localhost:8080/todos/1
{"deleted":1}
$ curl -s localhost:8080/health
{"ok":true}
```

`test.sh` faz exatamente essa sequência numa porta livre com um banco temporário, compara cada corpo
com o esperado, confere o estado final com o `sqlite3` do sistema e mata o servidor.

O binário é assinado e depende das duas dylibs:

```
$ codesign --verify --verbose=2 examples/api/build/api
examples/api/build/api: valid on disk
examples/api/build/api: satisfies its Designated Requirement
$ otool -L examples/api/build/api
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/usr/lib/libsqlite3.dylib (compatibility version 1.0.0, current version 1356.0.0)
```

## 4. Limites conhecidos

- **A arena de `lib/rt.mc` é fixa e não devolve memória.** São 4 MiB em `__bss` e um ponteiro que só
  anda para frente; não existe `rt_free`. Cada requisição gasta um punhado de bytes (o `Request`, o
  `Response`, os `strbuf` da resposta, as strings copiadas do SQLite) e nunca os recupera — um
  servidor de verdade em laço longo acabaria em `rt: rt_alloc: arena cheia`, exit 70. Dimensionar
  essa memória em tempo de compilação é o assunto do próximo marco: **ver `docs/specs/M13.md`**.
- **Uma conexão por vez.** `http_accept` é bloqueante; um cliente que abra a conexão e não fale
  segura o servidor.
- **`REQ_BUF_CAP` são 64 KiB** de cabeçalho mais corpo; uma requisição maior é tratada como
  malformada, não como `413`.
- **`#dylib` só vale no `--exe`.** O caminho `.o` + `ld` compila, mas o `ld` recusa o link dos
  `_sqlite3_*` — é a mesma troca documentada em `docs/bootstrap.md` § M11.
- **Sem herança, sem `super`:** uma classe implementa no máximo uma interface.
