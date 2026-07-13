use std::collections::VecDeque;

pub const TAIL_CAPACITY: usize = 8 * 1024;
pub const DETECTION_INTERVAL: std::time::Duration = std::time::Duration::from_millis(400);

pub struct TailBuffer {
    bytes: VecDeque<u8>,
}

impl Default for TailBuffer {
    fn default() -> Self {
        Self {
            bytes: VecDeque::with_capacity(TAIL_CAPACITY),
        }
    }
}

impl TailBuffer {
    pub fn push(&mut self, input: &[u8]) {
        let overflow = self
            .bytes
            .len()
            .saturating_add(input.len())
            .saturating_sub(TAIL_CAPACITY);
        self.bytes.drain(..overflow.min(self.bytes.len()));
        if input.len() > TAIL_CAPACITY {
            self.bytes.extend(&input[input.len() - TAIL_CAPACITY..]);
        } else {
            self.bytes.extend(input);
        }
    }

    pub fn detection_tail(&self) -> String {
        let raw: Vec<u8> = self.bytes.iter().copied().collect();
        let text = strip_ansi(&String::from_utf8_lossy(&raw));
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(20)..].join("\n")
    }
}

fn strip_ansi(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            output.push(ch);
            continue;
        }

        match chars.peek().copied() {
            Some('[') => {
                chars.next();
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                chars.next();
                let mut escaped = false;
                for c in chars.by_ref() {
                    if c == '\u{7}' || (escaped && c == '\\') {
                        break;
                    }
                    escaped = c == '\u{1b}';
                }
            }
            _ => {}
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::{TailBuffer, TAIL_CAPACITY};

    #[test]
    fn tail_is_bounded_to_capacity() {
        let mut tail = TailBuffer::default();
        tail.push(&vec![b'a'; TAIL_CAPACITY + 10]);
        assert_eq!(tail.bytes.len(), TAIL_CAPACITY);
    }

    #[test]
    fn detection_tail_strips_ansi_and_keeps_last_twenty_lines() {
        let mut tail = TailBuffer::default();
        let content = (0..25)
            .map(|line| format!("\u{1b}[31mline-{line}\u{1b}[0m"))
            .collect::<Vec<_>>()
            .join("\n");
        tail.push(content.as_bytes());
        let snapshot = tail.detection_tail();
        assert!(!snapshot.contains('\u{1b}'));
        assert!(snapshot.starts_with("line-5"));
        assert!(snapshot.ends_with("line-24"));
    }
}
