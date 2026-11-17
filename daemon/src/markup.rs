//! Plain text from notification bodies, which may hold a small subset of HTML-like markup.

/// Drops tags and decodes entities. Only removes what looks like a tag, since many
/// senders don't escape a literal "<".
pub fn strip(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut rest = body;
    while let Some(start) = rest.find(['<', '&']) {
        out.push_str(&rest[..start]);
        rest = &rest[start..];
        if rest.starts_with('<') {
            if let Some(len) = tag_len(rest) {
                let tag = &rest[1..len - 1];
                let name = tag.trim_start_matches('/').split([' ', '/']).next().unwrap_or("");
                if name.eq_ignore_ascii_case("br") || (name.eq_ignore_ascii_case("p") && !out.is_empty()) {
                    out.push('\n');
                }
                rest = &rest[len..];
                continue;
            }
        } else if let Some((decoded, len)) = entity(rest) {
            out.push(decoded);
            rest = &rest[len..];
            continue;
        }
        out.push(rest.chars().next().unwrap());
        rest = &rest[1..];
    }
    out.push_str(rest);
    out.trim().to_string()
}

/// Length of the tag at the start of @s, e.g. "<b>", "</a>" or "<img src='x'/>"
fn tag_len(s: &str) -> Option<usize> {
    let after = s[1..].trim_start_matches('/');
    if !after.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    s.find('>').map(|end| end + 1)
}

fn entity(s: &str) -> Option<(char, usize)> {
    let end = s.char_indices().take(12).find(|&(_, c)| c == ';')?.0;
    let name = &s[1..end];
    let c = match name {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => '\u{a0}',
        _ => {
            let code = if let Some(hex) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                u32::from_str_radix(hex, 16).ok()?
            } else {
                name.strip_prefix('#')?.parse().ok()?
            };
            char::from_u32(code)?
        }
    };
    Some((c, end + 1))
}

#[cfg(test)]
mod tests {
    use super::strip;

    #[test]
    fn strips_tags_and_entities() {
        assert_eq!(strip("<b>Bold</b> and <i>it</i>"), "Bold and it");
        assert_eq!(strip("<a href=\"https://x\">link</a>"), "link");
        assert_eq!(strip("a &lt; b &amp;&amp; c &#33; &#x41;"), "a < b && c ! A");
        assert_eq!(strip("line<br/>next"), "line\nnext");
    }

    #[test]
    fn keeps_literal_brackets() {
        assert_eq!(strip("1 < 2 > 0"), "1 < 2 > 0");
        assert_eq!(strip("AT&T rocks"), "AT&T rocks");
        assert_eq!(strip("<3 you"), "<3 you");
    }
}
