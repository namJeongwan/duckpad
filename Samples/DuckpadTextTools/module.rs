use std::slice;
use std::sync::Mutex;

static OUTPUT: Mutex<Vec<u8>> = Mutex::new(Vec::new());

#[no_mangle]
pub unsafe extern "C" fn duckpad_invoke(operation: u32, pointer: *const u8, length: u32) -> u32 {
    let input: &[u8] = if length == 0 {
        &[]
    } else {
        if pointer.is_null() { return 2; }
        slice::from_raw_parts(pointer, length as usize)
    };
    let transformed = match operation {
        1 => sort_lines(input),
        2 => trim_trailing_whitespace(input),
        _ => return 3,
    };
    let mut output = match OUTPUT.lock() { Ok(value) => value, Err(_) => return 4 };
    *output = transformed;
    0
}

#[no_mangle]
pub extern "C" fn duckpad_output_pointer() -> u32 {
    OUTPUT.lock().map(|value| value.as_ptr() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn duckpad_output_length() -> u32 {
    OUTPUT.lock().map(|value| value.len() as u32).unwrap_or(0)
}

fn sort_lines(input: &[u8]) -> Vec<u8> {
    if input.is_empty() { return Vec::new(); }
    let mut contents: Vec<&[u8]> = Vec::new();
    let mut separators: Vec<&[u8]> = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < input.len() {
        let separator_length = if input[index] == b'\r' {
            if index + 1 < input.len() && input[index + 1] == b'\n' { 2 } else { 1 }
        } else if input[index] == b'\n' { 1 } else { 0 };
        if separator_length == 0 { index += 1; continue; }
        contents.push(&input[start..index]);
        separators.push(&input[index..index + separator_length]);
        index += separator_length;
        start = index;
    }
    if start < input.len() { contents.push(&input[start..]); }
    contents.sort();
    let mut output = Vec::with_capacity(input.len());
    for (index, content) in contents.into_iter().enumerate() {
        output.extend_from_slice(content);
        if let Some(separator) = separators.get(index) { output.extend_from_slice(separator); }
    }
    output
}

fn trim_trailing_whitespace(input: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(input.len());
    let mut line_start = 0;
    for (index, byte) in input.iter().enumerate() {
        if *byte != b'\n' { continue; }
        let mut content_end = index;
        let has_cr = content_end > line_start && input[content_end - 1] == b'\r';
        if has_cr { content_end -= 1; }
        while content_end > line_start && matches!(input[content_end - 1], b' ' | b'\t') { content_end -= 1; }
        output.extend_from_slice(&input[line_start..content_end]);
        if has_cr { output.push(b'\r'); }
        output.push(b'\n');
        line_start = index + 1;
    }
    let mut content_end = input.len();
    while content_end > line_start && matches!(input[content_end - 1], b' ' | b'\t') { content_end -= 1; }
    output.extend_from_slice(&input[line_start..content_end]);
    output
}
