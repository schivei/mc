// http.mc — servidor HTTP/1.1 minimo em cima dos sockets da libSystem.
//
// Uma conexao por vez, sem keep-alive: aceita, le a requisicao inteira, responde
// com `Connection: close` e fecha. E o suficiente para uma API de exemplo e evita
// o unico assunto que o nucleo nao resolveria bem hoje (multiplexacao).
//
// Nada de struct: a requisicao e uma estrutura plana na arena de rt.mc, com
// #define de offset e acessoras, como manda docs/core-language.md.
//
//   #include "lib/http.mc"

#include "rt.mc"

// ---- constantes de <sys/socket.h> e <netinet/in.h> no macOS ----

#define AF_INET      2
#define SOCK_STREAM  1
#define SOL_SOCKET   0xFFFF
#define SO_REUSEADDR 4
#define INADDR_ANY   0
#define SA_IN_LEN    16               // sizeof(struct sockaddr_in)

// read/write/close vem de lib/sys.mc, incluido por rt.mc
extern i64 socket(i64 dominio, i64 tipo, i64 proto);
extern i64 setsockopt(i64 fd, i64 nivel, i64 opt, uptr valor, i64 len);
extern i64 bind(i64 fd, uptr sa, i64 len);
extern i64 listen(i64 fd, i64 backlog);
extern i64 accept(i64 fd, uptr sa, uptr plen);

// ---- sockaddr_in montado byte a byte ----
// struct sockaddr_in do macOS:
//   0: u8  sin_len     = 16
//   1: u8  sin_family  = AF_INET
//   2: u16 sin_port    em big-endian (network order)
//   4: u32 sin_addr    em big-endian; INADDR_ANY e 0, entao a ordem nao importa
//   8: u8  sin_zero[8]
// A porta e escrita byte a byte justamente para nao depender da ordem da maquina.
void sockaddr_in_init(uptr sa, i64 port) {
    mem_zero(sa, SA_IN_LEN);
    st8(sa + 0, SA_IN_LEN);
    st8(sa + 1, AF_INET);
    st8(sa + 2, (port >> 8) & 0xFF);
    st8(sa + 3, port & 0xFF);
    st32(sa + 4, INADDR_ANY);
}

// ---- socket de escuta ----

// abre, marca SO_REUSEADDR, liga na porta e escuta; devolve o fd ou -1
i64 http_listen(i64 port) {
    u8 sa[SA_IN_LEN];
    u8 um[4];
    i64 fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0 - 1;
    st32(um, 1);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, um, 4);
    sockaddr_in_init(sa, port);
    if (bind(fd, sa, SA_IN_LEN) < 0) {
        close(fd);
        return 0 - 1;
    }
    if (listen(fd, 16) < 0) {
        close(fd);
        return 0 - 1;
    }
    return fd;
}

// bloqueia ate chegar uma conexao; devolve o fd do cliente ou -1
i64 http_accept(i64 fd) {
    return accept(fd, 0, 0);
}

// ---- requisicao: estrutura plana de 48 bytes ----

#define REQ_METHOD  0                 // uptr: "GET", "POST", ...
#define REQ_PATH    8                 // uptr: "/todos/3"
#define REQ_BODY    16                // uptr: corpo NUL-terminado (aponta para o cru)
#define REQ_CLEN    24                // i64:  bytes de corpo efetivamente lidos
#define REQ_RAW     32                // uptr: buffer cru da conexao
#define REQ_RAWLEN  40                // i64:  bytes no buffer cru
#define REQ_SIZE    48

#define REQ_BUF_CAP 65536             // teto de uma requisicao inteira, cabecalho + corpo

uptr req_method(uptr r)             { return ld64(r + REQ_METHOD); }
void set_req_method(uptr r, uptr v) { st64(r + REQ_METHOD, v); }
uptr req_path(uptr r)               { return ld64(r + REQ_PATH); }
void set_req_path(uptr r, uptr v)   { st64(r + REQ_PATH, v); }
uptr req_body(uptr r)               { return ld64(r + REQ_BODY); }
void set_req_body(uptr r, uptr v)   { st64(r + REQ_BODY, v); }
i64  req_clen(uptr r)               { return ld64(r + REQ_CLEN); }
void set_req_clen(uptr r, i64 v)    { st64(r + REQ_CLEN, v); }
uptr req_raw(uptr r)                { return ld64(r + REQ_RAW); }
void set_req_raw(uptr r, uptr v)    { st64(r + REQ_RAW, v); }
i64  req_rawlen(uptr r)             { return ld64(r + REQ_RAWLEN); }
void set_req_rawlen(uptr r, i64 v)  { st64(r + REQ_RAWLEN, v); }

// aloca a requisicao e seu buffer; da para reusar a mesma em varias conexoes
uptr http_req_new() {
    uptr r = rt_alloc(REQ_SIZE);
    set_req_raw(r, rt_alloc(REQ_BUF_CAP));
    set_req_method(r, "");
    set_req_path(r, "");
    set_req_body(r, "");
    return r;
}

// ---- leitura da requisicao ----

i64 http_lower(i64 c) {
    if (c >= 'A' && c <= 'Z') return c + 32;
    return c;
}

// str_find sem distinguir maiusculas de minusculas: nomes de cabecalho HTTP nao
// as distinguem, e cada cliente escreve o seu de um jeito
i64 http_find_ci(uptr h, uptr n) {
    i64 ln = str_len(n);
    i64 lh = str_len(h);
    if (ln == 0) return 0;
    i64 i = 0;
    while (i + ln <= lh) {
        i64 j = 0;
        while (j < ln) {
            if (http_lower(ld8(h + i + j)) != http_lower(ld8(n + j))) break;
            j++;
        }
        if (j == ln) return i;
        i++;
    }
    return 0 - 1;
}

// valor numerico do cabecalho `nome` (com os dois pontos, ex. "Content-Length:");
// -1 se o cabecalho nao esta presente
i64 http_header_num(uptr raw, uptr nome) {
    i64 i = http_find_ci(raw, nome);
    if (i < 0) return 0 - 1;
    i = i + str_len(nome);
    while (ld8(raw + i) == ' ') {
        i++;
    }
    return atoi(raw + i);
}

// le uma requisicao inteira de `cfd` para `req`; 1 = ok, 0 = fechou ou malformada.
// Preenche metodo, caminho, corpo e Content-Length.
i64 http_read_request(i64 cfd, uptr req) {
    uptr raw = req_raw(req);
    i64 n = 0;
    i64 fimhdr = 0 - 1;

    st8(raw, 0);
    set_req_method(req, "");
    set_req_path(req, "");
    set_req_body(req, "");
    set_req_clen(req, 0);
    set_req_rawlen(req, 0);

    // 1. le ate fechar o cabecalho com a linha em branco
    while (fimhdr < 0) {
        if (n >= REQ_BUF_CAP - 1) return 0;
        i64 k = read(cfd, raw + n, REQ_BUF_CAP - 1 - n);
        if (k <= 0) return 0;
        n = n + k;
        st8(raw + n, 0);
        fimhdr = str_find(raw, "\r\n\r\n");
    }

    i64 corpo = fimhdr + 4;
    i64 clen = http_header_num(raw, "Content-Length:");
    if (clen < 0) clen = 0;

    // 2. le o que faltar do corpo
    while (n - corpo < clen) {
        if (n >= REQ_BUF_CAP - 1) break;
        i64 k = read(cfd, raw + n, REQ_BUF_CAP - 1 - n);
        if (k <= 0) break;
        n = n + k;
        st8(raw + n, 0);
    }
    if (corpo + clen > n) clen = n - corpo;
    set_req_rawlen(req, n);
    set_req_clen(req, clen);

    // 3. primeira linha: "METODO CAMINHO HTTP/1.1"
    i64 e1 = 0;
    while (ld8(raw + e1) != ' ' && ld8(raw + e1) != 0) {
        e1++;
    }
    if (ld8(raw + e1) != ' ') return 0;
    set_req_method(req, str_ndup(raw, e1));

    i64 i2 = e1 + 1;
    i64 e2 = i2;
    while (ld8(raw + e2) != ' ' && ld8(raw + e2) != '\r' && ld8(raw + e2) != 0) {
        e2++;
    }
    if (e2 == i2) return 0;
    set_req_path(req, str_ndup(raw + i2, e2 - i2));

    // 4. corpo NUL-terminado dentro do proprio buffer cru
    st8(raw + corpo + clen, 0);
    set_req_body(req, raw + corpo);
    return 1;
}

// ---- resposta ----

// razao textual dos status que este exemplo usa
uptr http_reason(i64 status) {
    if (status == 200) return "OK";
    if (status == 201) return "Created";
    if (status == 400) return "Bad Request";
    if (status == 404) return "Not Found";
    if (status == 405) return "Method Not Allowed";
    if (status == 500) return "Internal Server Error";
    return "Unknown";
}

// escreve `n` bytes, insistindo enquanto o write parcial nao terminar; 1 = ok
i64 http_write_all(i64 fd, uptr p, i64 n) {
    i64 i = 0;
    while (i < n) {
        i64 k = write(fd, p + i, n - i);
        if (k <= 0) return 0;
        i = i + k;
    }
    return 1;
}

// monta e envia a resposta completa (status, Content-Type, Content-Length,
// Connection: close e o corpo); 1 = ok
i64 http_respond(i64 cfd, i64 status, uptr content_type, uptr body) {
    i64 n = str_len(body);
    uptr b = sb_new(256 + n);
    sb_puts(b, "HTTP/1.1 ");
    sb_putnum(b, status);
    sb_put(b, ' ');
    sb_puts(b, http_reason(status));
    sb_puts(b, "\r\nContent-Type: ");
    sb_puts(b, content_type);
    sb_puts(b, "\r\nContent-Length: ");
    sb_putnum(b, n);
    sb_puts(b, "\r\nConnection: close\r\n\r\n");
    sb_putmem(b, body, n);
    return http_write_all(cfd, sb_str(b), sb_len(b));
}
