extern fn ziggurat_header_value() c_int;
pub fn value() c_int {
    return ziggurat_header_value();
}
