// embed.mc -- the same boundary, reached with #embed instead of #include.
#embed bad_bytes "../../outside.mc"

i64 bad_embed() { return bad_bytes_size; }
